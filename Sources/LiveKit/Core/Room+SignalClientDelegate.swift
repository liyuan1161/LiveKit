/*
 * Copyright 2025 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Room实现SignalClientDelegate协议，处理从服务器接收的信令消息
extension Room: SignalClientDelegate {
    // 处理信令客户端连接状态变化
    func signalClient(_: SignalClient, didUpdateConnectionState connectionState: ConnectionState,
                      oldState: ConnectionState,
                      disconnectError: LiveKitError?) async
    {
        // 只有在以下条件都满足时才尝试重连：
        // 1. 连接状态确实发生了变化
        // 2. 新状态是断开连接
        // 3. 断开原因不是主动取消
        // 4. Room当前处于已连接状态
        if connectionState != oldState,
           // did disconnect
           case .disconnected = connectionState,
           // Only attempt re-connect if not cancelled
           let errorType = disconnectError?.type, errorType != .cancelled,
           // engine is currently connected state
           case .connected = _state.connectionState
        {
            do {
                // 启动WebSocket重连过程
                try await startReconnect(reason: .websocket)
            } catch {
                log("Failed calling startReconnect, error: \(error)", .error)
            }
        }
    }

    // 处理服务器发送的离开消息
    func signalClient(_: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) async {
        log("canReconnect: \(canReconnect), reason: \(reason)")

        if canReconnect {
            // 如果服务器允许重连，则设置下次重连模式为完全重连
            _state.mutate { $0.nextReconnectMode = .full }
        } else {
            // 服务器表示无法恢复连接，清理资源并断开
            await cleanUp(withError: LiveKitError.from(reason: reason))
        }
    }

    // 处理订阅编解码器和质量更新（用于动态调整视频质量）
    func signalClient(_: SignalClient, didUpdateSubscribedCodecs codecs: [Livekit_SubscribedCodec],
                      qualities: [Livekit_SubscribedQuality],
                      forTrackSid trackSid: String) async
    {
        // 检查动态调整是否启用
        guard _state.roomOptions.dynacast else { return }

        log("[Publish/Backup] Qualities: \(qualities.map { String(describing: $0) }.joined(separator: ", ")), Codecs: \(codecs.map { String(describing: $0) }.joined(separator: ", "))")

        let trackSid = Track.Sid(from: trackSid)
        // 查找本地轨道发布对象
        guard let publication = localParticipant.trackPublications[trackSid] as? LocalTrackPublication else {
            log("Received subscribed quality update for an unknown track", .warning)
            return
        }

        if !codecs.isEmpty {
            // 如果有编解码器更新，需处理视频轨道
            guard let videoTrack = publication.track as? LocalVideoTrack else { return }
            // 设置已订阅的编解码器，获取缺失的编解码器列表
            let missingSubscribedCodecs = (try? videoTrack._set(subscribedCodecs: codecs)) ?? []

            // 发布缺失的编解码器
            if !missingSubscribedCodecs.isEmpty {
                log("Missing codecs: \(missingSubscribedCodecs)")
                for missingSubscribedCodec in missingSubscribedCodecs {
                    do {
                        log("Publishing additional codec: \(missingSubscribedCodec)")
                        try await localParticipant.publish(additionalVideoCodec: missingSubscribedCodec, for: publication)
                    } catch {
                        log("Failed publishing additional codec: \(missingSubscribedCodec), error: \(error)", .error)
                    }
                }
            }

        } else {
            // 如果没有编解码器更新，只更新质量参数
            localParticipant._set(subscribedQualities: qualities, forTrackSid: trackSid)
        }
    }

    // 处理连接响应消息（加入房间或重连）
    func signalClient(_: SignalClient, didReceiveConnectResponse connectResponse: SignalClient.ConnectResponse) async {
        if case let .join(joinResponse) = connectResponse {
            log("\(joinResponse.serverInfo)", .info)

            // 处理端到端加密
            if e2eeManager != nil, !joinResponse.sifTrailer.isEmpty {
                e2eeManager?.keyProvider.setSifTrailer(trailer: joinResponse.sifTrailer)
            }

            // 更新Room状态
            _state.mutate {
                $0.sid = Room.Sid(from: joinResponse.room.sid)
                $0.name = joinResponse.room.name
                $0.serverInfo = joinResponse.serverInfo
                $0.creationTime = Date(timeIntervalSince1970: TimeInterval(joinResponse.room.creationTime))
                $0.maxParticipants = Int(joinResponse.room.maxParticipants)

                $0.metadata = joinResponse.room.metadata
                $0.isRecording = joinResponse.room.activeRecording
                $0.numParticipants = Int(joinResponse.room.numParticipants)
                $0.numPublishers = Int(joinResponse.room.numPublishers)

                // 设置本地参与者信息
                localParticipant.set(info: joinResponse.participant, connectionState: $0.connectionState)

                // 处理其他参与者信息
                if !joinResponse.otherParticipants.isEmpty {
                    for otherParticipant in joinResponse.otherParticipants {
                        $0.updateRemoteParticipant(info: otherParticipant, room: self)
                    }
                }
            }
        }
    }

    // 处理房间信息更新
    func signalClient(_: SignalClient, didUpdateRoom room: Livekit_Room) async {
        _state.mutate {
            $0.metadata = room.metadata
            $0.isRecording = room.activeRecording
            $0.numParticipants = Int(room.numParticipants)
            $0.numPublishers = Int(room.numPublishers)
        }
    }

    // 处理发言者更新（音频活动）
    func signalClient(_: SignalClient, didUpdateSpeakers speakers: [Livekit_SpeakerInfo]) async {
        log("speakers: \(speakers)", .trace)

        // 更新活跃发言者列表
        let activeSpeakers = _state.mutate { state -> [Participant] in

            var lastSpeakers = state.activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
            for speaker in speakers {
                let participantSid = Participant.Sid(from: speaker.sid)
                // 查找对应的参与者（本地或远程）
                guard let participant = participantSid == localParticipant.sid ? localParticipant : state.remoteParticipant(forSid: participantSid) else {
                    continue
                }

                // 更新参与者的音频级别和发言状态
                participant._state.mutate {
                    $0.audioLevel = speaker.level
                    $0.isSpeaking = speaker.active
                }

                // 维护活跃发言者列表
                if speaker.active {
                    lastSpeakers[participantSid] = participant
                } else {
                    lastSpeakers.removeValue(forKey: participantSid)
                }
            }

            // 按音频级别排序
            state.activeSpeakers = lastSpeakers.values.sorted(by: { $1.audioLevel > $0.audioLevel })

            return state.activeSpeakers
        }

        // 如果房间已连接，通知委托发言者变化
        if case .connected = _state.connectionState {
            delegates.notify(label: { "room.didUpdate speakers: \(speakers)" }) {
                $0.room?(self, didUpdateSpeakingParticipants: activeSpeakers)
            }
        }
    }

    // 处理连接质量更新
    func signalClient(_: SignalClient, didUpdateConnectionQuality connectionQuality: [Livekit_ConnectionQualityInfo]) async {
        log("connectionQuality: \(connectionQuality)", .trace)

        // 遍历每个参与者的连接质量信息
        for entry in connectionQuality {
            let participantSid = Participant.Sid(from: entry.participantSid)
            if participantSid == localParticipant.sid {
                // 更新本地参与者连接质量
                localParticipant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            } else if let participant = _state.read({ $0.remoteParticipant(forSid: participantSid) }) {
                // 更新远程参与者连接质量
                participant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            }
        }
    }

    // 处理本地轨道的静音状态变更请求
    func signalClient(_: SignalClient, didUpdateMuteTrack trackSid: Track.Sid, muted: Bool) async {
        guard let publication = localParticipant._state.trackPublications[trackSid] as? LocalTrackPublication else {
            // 找不到对应发布对象
            return
        }

        do {
            if muted {
                try await publication.mute()
            } else {
                try await publication.unmute()
            }
        } catch {
            log("Failed to update mute for publication, error: \(error)", .error)
        }
    }

    // 处理订阅权限更新
    func signalClient(_: SignalClient, didUpdateSubscriptionPermission subscriptionPermission: Livekit_SubscriptionPermissionUpdate) async {
        log("did update subscriptionPermission: \(subscriptionPermission)")

        let participantSid = Participant.Sid(from: subscriptionPermission.participantSid)
        let trackSid = Track.Sid(from: subscriptionPermission.trackSid)

        // 查找对应的参与者和轨道发布
        guard let participant = _state.read({ $0.remoteParticipant(forSid: participantSid) }),
              let publication = participant.trackPublications[trackSid] as? RemoteTrackPublication
        else {
            return
        }

        // 更新订阅权限
        publication.set(subscriptionAllowed: subscriptionPermission.allowed)
    }

    // 处理轨道流状态更新
    func signalClient(_: SignalClient, didUpdateTrackStreamStates trackStates: [Livekit_StreamStateInfo]) async {
        log("did update trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

        // 遍历每个轨道的状态更新
        for update in trackStates {
            let participantSid = Participant.Sid(from: update.participantSid)
            let trackSid = Track.Sid(from: update.trackSid)

            // 查找对应的远程参与者
            guard let participant = _state.read({ $0.remoteParticipant(forSid: participantSid) }) else { continue }
            // 查找对应的轨道发布
            guard let trackPublication = participant._state.trackPublications[trackSid] as? RemoteTrackPublication else { continue }
            // 更新流状态
            trackPublication._state.mutate { $0.streamState = update.state.toLKType() }
        }
    }

    // 处理参与者信息更新
    func signalClient(_: SignalClient, didUpdateParticipants participants: [Livekit_ParticipantInfo]) async {
        log("participants: \(participants)")

        var disconnectedParticipantIdentities = [Participant.Identity]()
        var newParticipants = [RemoteParticipant]()

        // 更新参与者状态
        _state.mutate {
            for info in participants {
                let infoIdentity = Participant.Identity(from: info.identity)

                // 如果是本地参与者，更新本地信息
                if infoIdentity == localParticipant.identity {
                    localParticipant.set(info: info, connectionState: $0.connectionState)
                    continue
                }

                // 处理断开连接的参与者
                if info.state == .disconnected {
                    disconnectedParticipantIdentities.append(infoIdentity)
                } else {
                    // 处理连接中的参与者
                    let isNewParticipant = $0.remoteParticipants[infoIdentity] == nil
                    let participant = $0.updateRemoteParticipant(info: info, room: self)

                    if isNewParticipant {
                        newParticipants.append(participant)
                    } else {
                        participant.set(info: info, connectionState: $0.connectionState)
                    }
                }
            }
        }

        // 并行处理断开连接的参与者
        await withTaskGroup(of: Void.self) { group in
            for identity in disconnectedParticipantIdentities {
                group.addTask {
                    do {
                        try await self._onParticipantDidDisconnect(identity: identity)
                    } catch {
                        self.log("Failed to process participant disconnection, error: \(error)", .error)
                    }
                }
            }

            await group.waitForAll()
        }

        // 通知新参与者连接
        if case .connected = _state.connectionState {
            for participant in newParticipants {
                delegates.notify(label: { "room.remoteParticipantDidConnect: \(participant)" }) {
                    $0.room?(self, participantDidConnect: participant)
                }
            }
        }
    }

    // 处理本地轨道取消发布的响应
    func signalClient(_: SignalClient, didUnpublishLocalTrack localTrack: Livekit_TrackUnpublishedResponse) async {
        log()

        let trackSid = Track.Sid(from: localTrack.trackSid)

        // 查找对应的本地轨道发布
        guard let publication = localParticipant._state.trackPublications[trackSid] as? LocalTrackPublication else {
            log("track publication not found", .warning)
            return
        }

        do {
            // 取消发布轨道
            try await localParticipant.unpublish(publication: publication)
            log("Unpublished track(\(localTrack.trackSid)")
        } catch {
            log("Failed to unpublish track(\(localTrack.trackSid), error: \(error)", .warning)
        }
    }

    // 处理接收到的ICE候选
    func signalClient(_: SignalClient, didReceiveIceCandidate iceCandidate: IceCandidate, target: Livekit_SignalTarget) async {
        // 根据目标获取对应的传输对象
        guard let transport = target == .subscriber ? _state.subscriber : _state.publisher else {
            log("Failed to add ice candidate, transport is nil for target: \(target)", .error)
            return
        }

        do {
            // 将ICE候选添加到对应的传输对象
            try await transport.add(iceCandidate: iceCandidate)
        } catch {
            log("Failed to add ice candidate for transport: \(transport), error: \(error)", .error)
        }
    }

    // 处理接收到的SDP应答
    func signalClient(_: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription) async {
        do {
            // 获取发布者传输
            let publisher = try requirePublisher()
            // 设置远程描述（应答）
            try await publisher.set(remoteDescription: answer)
        } catch {
            log("Failed to set remote description, error: \(error)", .error)
        }
    }

    // 处理接收到的SDP提议，创建应答
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: LKRTCSessionDescription) async {
        log("Received offer, creating & sending answer...")

        // 确保订阅者传输存在
        guard let subscriber = _state.subscriber else {
            log("Failed to send answer, subscriber is nil", .error)
            return
        }

        do {
            // 设置远程描述（提议）
            try await subscriber.set(remoteDescription: offer)
            // 创建应答
            let answer = try await subscriber.createAnswer()
            // 设置本地描述（应答）
            try await subscriber.set(localDescription: answer)
            // 发送应答到服务器
            try await signalClient.send(answer: answer)
        } catch {
            log("Failed to send answer with error: \(error)", .error)
        }
    }

    // 处理令牌更新
    func signalClient(_: SignalClient, didUpdateToken token: String) async {
        // 更新令牌
        _state.mutate { $0.token = token }
    }

    // 处理远程订阅了本地轨道的通知
    func signalClient(_: SignalClient, didSubscribeTrack trackSid: Track.Sid) async {
        // 查找本地轨道发布
        guard let track = localParticipant.trackPublications[trackSid] as? LocalTrackPublication else {
            log("Could not find local track publication for subscribed event")
            return
        }

        // 通知Room委托
        delegates.notify {
            $0.room?(self, participant: self.localParticipant, remoteDidSubscribeTrack: track)
        }

        // 通知LocalParticipant委托
        localParticipant.delegates.notify {
            $0.participant?(self.localParticipant, remoteDidSubscribeTrack: track)
        }
    }
}
