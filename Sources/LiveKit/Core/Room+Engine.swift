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

#if canImport(Network)
import Network
#endif

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Room+Engine 扩展，包含Room类的核心连接管理功能
extension Room {
    // MARK: - 公共类型定义

    // 条件评估函数类型，用于条件执行逻辑
    typealias ConditionEvalFunc = (_ newState: State, _ oldState: State?) -> Bool

    // MARK: - 私有类型定义

    // 条件执行条目结构，用于管理状态相关的条件执行
    struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc    // 执行条件
        let removeCondition: ConditionEvalFunc     // 移除条件
        let block: () -> Void                      // 执行块
    }

    // 重置RTC传输层状态
    func cleanUpRTC() async {
        // 关闭数据通道
        publisherDataChannel.reset()
        subscriberDataChannel.reset()

        // 获取当前的发布者和订阅者传输对象
        let (subscriber, publisher) = _state.read { ($0.subscriber, $0.publisher) }

        // 关闭传输对象
        await publisher?.close()
        await subscriber?.close()

        // 重置发布状态
        _state.mutate {
            $0.subscriber = nil
            $0.publisher = nil
            $0.hasPublished = false
        }
    }

    // 触发发布者传输协商过程
    func publisherShouldNegotiate() async throws {
        log()

        // 获取发布者传输对象
        let publisher = try requirePublisher()
        // 启动协商过程
        await publisher.negotiate()
        // 更新已发布状态
        _state.mutate { $0.hasPublished = true }
    }

    // 发送用户数据包
    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        try await send(dataPacket: .with {
            $0.user = userPacket
            $0.kind = kind
        })
    }

    // 发送数据包的核心方法
    func send(dataPacket packet: Livekit_DataPacket) async throws {
        // 确保发布者传输已连接
        func ensurePublisherConnected() async throws {
            // 如果订阅者是主传输，则无需特殊处理
            guard _state.isSubscriberPrimary else { return }

            // 获取发布者传输对象
            let publisher = try requirePublisher()

            // 检查连接状态，如果未连接则触发协商
            let connectionState = await publisher.connectionState
            if connectionState != .connected, connectionState != .connecting {
                try await publisherShouldNegotiate()
            }

            // 等待发布者传输连接完成
            try await publisherTransportConnectedCompleter.wait(timeout: _state.connectOptions.publisherTransportConnectTimeout)
            // 等待数据通道打开
            try await publisherDataChannel.openCompleter.wait()
        }

        // 确保发布者已连接
        try await ensurePublisherConnected()

        // 再次检查发布者连接状态
        if await !(_state.publisher?.isConnected ?? false) {
            log("publisher is not .connected", .error)
        }

        // 检查数据通道状态
        let dataChannelIsOpen = publisherDataChannel.isOpen
        if !dataChannelIsOpen {
            log("publisher data channel is not .open", .error)
        }

        // 设置数据包的参与者标识
        var packet = packet
        if let identity = localParticipant.identity?.stringValue {
            packet.participantIdentity = identity
        }

        // 通过发布者数据通道发送数据包
        try await publisherDataChannel.send(dataPacket: packet)
    }
}

// MARK: - 内部方法

extension Room {
    // 配置传输对象 - 多PeerConnection管理的核心方法
    func configureTransports(connectResponse: SignalClient.ConnectResponse) async throws {
        // 创建WebRTC配置的辅助函数
        func makeConfiguration() -> LKRTCConfiguration {
            let connectOptions = _state.connectOptions

            // 创建默认的WebRTC配置
            let rtcConfiguration = LKRTCConfiguration.liveKitDefault()

            // 设置服务器提供的ICE服务器
            rtcConfiguration.iceServers = connectResponse.rtcIceServers

            // 如果用户提供了ICE服务器，则覆盖服务器提供的
            if !connectOptions.iceServers.isEmpty {
                rtcConfiguration.iceServers = connectOptions.iceServers.map { $0.toRTCType() }
            }

            // 根据服务器配置或用户选项设置ICE传输策略
            if connectResponse.clientConfiguration.forceRelay == .enabled {
                rtcConfiguration.iceTransportPolicy = .relay
            } else {
                rtcConfiguration.iceTransportPolicy = connectOptions.iceTransportPolicy.toRTCType()
            }

            return rtcConfiguration
        }

        // 创建RTCConfiguration对象
        let rtcConfiguration = makeConfiguration()

        // 处理初始加入响应
        if case let .join(joinResponse) = connectResponse {
            log("Configuring transports with JOIN response...")

            // 确保传输对象尚未配置
            guard _state.subscriber == nil, _state.publisher == nil else {
                log("Transports are already configured")
                return
            }

            // 判断订阅者是否为主传输通道(protocol v3特性)
            let isSubscriberPrimary = joinResponse.subscriberPrimary
            log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

            // 创建订阅者传输对象
            let subscriber = try Transport(config: rtcConfiguration,
                                           target: .subscriber,
                                           primary: isSubscriberPrimary,
                                           delegate: self)

            // 创建发布者传输对象
            let publisher = try Transport(config: rtcConfiguration,
                                          target: .publisher,
                                          primary: !isSubscriberPrimary,
                                          delegate: self)

            // 设置发布者提议回调
            await publisher.set { [weak self] offer in
                guard let self else { return }
                self.log("Publisher onOffer \(offer.sdp)")
                try await self.signalClient.send(offer: offer)
            }

            // 在发布者通道上创建数据通道(用于向后兼容)
            // 创建可靠的数据通道
            let reliableDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.labels.reliable,
                                                                  configuration: RTC.createDataChannelConfiguration())

            // 创建非可靠(有损)的数据通道
            let lossyDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.labels.lossy,
                                                               configuration: RTC.createDataChannelConfiguration(maxRetransmits: 0))

            // 设置发布者数据通道
            publisherDataChannel.set(reliable: reliableDataChannel)
            publisherDataChannel.set(lossy: lossyDataChannel)

            // 记录数据通道信息
            log("dataChannel.\(String(describing: reliableDataChannel?.label)) : \(String(describing: reliableDataChannel?.channelId))")
            log("dataChannel.\(String(describing: lossyDataChannel?.label)) : \(String(describing: lossyDataChannel?.channelId))")

            // 更新Room状态中的传输对象
            _state.mutate {
                $0.subscriber = subscriber
                $0.publisher = publisher
                $0.isSubscriberPrimary = isSubscriberPrimary
            }

            // 如果订阅者不是主传输，则立即触发发布者协商
            if !isSubscriberPrimary {
                // 协议v3+的延迟协商
                try await publisherShouldNegotiate()
            }

        } else if case .reconnect = connectResponse {
            // 重连情况下更新现有传输配置
            log("[Connect] Configuring transports with RECONNECT response...")
            let (subscriber, publisher) = _state.read { ($0.subscriber, $0.publisher) }
            try await subscriber?.set(configuration: rtcConfiguration)
            try await publisher?.set(configuration: rtcConfiguration)
        }
    }
}

// MARK: - 执行控制（内部）

extension Room {
    func execute(when condition: @escaping ConditionEvalFunc,
                 removeWhen removeCondition: @escaping ConditionEvalFunc,
                 _ block: @escaping () -> Void)
    {
        // already matches condition, execute immediately
        if _state.read({ condition($0, nil) }) {
            log("[execution control] executing immediately...")
            block()
        } else {
            _blockProcessQueue.async { [weak self] in
                guard let self else { return }

                // create an entry and enqueue block
                self.log("[execution control] enqueuing entry...")

                let entry = ConditionalExecutionEntry(executeCondition: condition,
                                                      removeCondition: removeCondition,
                                                      block: block)

                self._queuedBlocks.append(entry)
            }
        }
    }
}

// MARK: - Connection / Reconnection logic

public enum StartReconnectReason: Sendable {
    case websocket
    case transport
    case networkSwitch
    case debug
}

// Room+ConnectSequences
extension Room {
    // full connect sequence, doesn't update connection state
    func fullConnectSequence(_ url: URL, _ token: String) async throws {
        let connectResponse = try await signalClient.connect(url,
                                                             token,
                                                             connectOptions: _state.connectOptions,
                                                             reconnectMode: _state.isReconnectingWithMode,
                                                             adaptiveStream: _state.roomOptions.adaptiveStream)
        // Check cancellation after WebSocket connected
        try Task.checkCancellation()

        _state.mutate { $0.connectStopwatch.split(label: "signal") }
        try await configureTransports(connectResponse: connectResponse)
        // Check cancellation after configuring transports
        try Task.checkCancellation()

        // Resume after configuring transports...
        await signalClient.resumeQueues()

        // Wait for transport...
        try await primaryTransportConnectedCompleter.wait(timeout: _state.connectOptions.primaryTransportConnectTimeout)
        try Task.checkCancellation()

        _state.mutate { $0.connectStopwatch.split(label: "engine") }
        log("\(_state.connectStopwatch)")
    }

    func startReconnect(reason: StartReconnectReason, nextReconnectMode: ReconnectMode? = nil) async throws {
        log("[Connect] Starting, reason: \(reason)")

        guard case .connected = _state.connectionState else {
            log("[Connect] Must be called with connected state", .error)
            throw LiveKitError(.invalidState)
        }

        guard let url = _state.url, let token = _state.token else {
            log("[Connect] Url or token is nil", .error)
            throw LiveKitError(.invalidState)
        }

        guard _state.subscriber != nil, _state.publisher != nil else {
            log("[Connect] Publisher or subscriber is nil", .error)
            throw LiveKitError(.invalidState)
        }

        guard _state.isReconnectingWithMode == nil else {
            log("[Connect] Reconnect already in progress...", .warning)
            throw LiveKitError(.invalidState)
        }

        _state.mutate {
            // Mark as Re-connecting internally
            $0.isReconnectingWithMode = .quick
            $0.nextReconnectMode = nextReconnectMode
        }

        // quick connect sequence, does not update connection state
        @Sendable func quickReconnectSequence() async throws {
            log("[Connect] Starting .quick reconnect sequence...")

            let connectResponse = try await signalClient.connect(url,
                                                                 token,
                                                                 connectOptions: _state.connectOptions,
                                                                 reconnectMode: _state.isReconnectingWithMode,
                                                                 participantSid: localParticipant.sid,
                                                                 adaptiveStream: _state.roomOptions.adaptiveStream)
            try Task.checkCancellation()

            // Update configuration
            try await configureTransports(connectResponse: connectResponse)
            try Task.checkCancellation()

            // Resume after configuring transports...
            await signalClient.resumeQueues()

            log("[Connect] Waiting for subscriber to connect...")
            // Wait for primary transport to connect (if not already)
            try await primaryTransportConnectedCompleter.wait(timeout: _state.connectOptions.primaryTransportConnectTimeout)
            try Task.checkCancellation()

            // send SyncState before offer
            try await sendSyncState()

            await _state.subscriber?.setIsRestartingIce()

            if let publisher = _state.publisher, _state.hasPublished {
                // Only if published, wait for publisher to connect...
                log("[Connect] Waiting for publisher to connect...")
                try await publisher.createAndSendOffer(iceRestart: true)
                try await publisherTransportConnectedCompleter.wait(timeout: _state.connectOptions.publisherTransportConnectTimeout)
            }
        }

        // "full" re-connection sequence
        // as a last resort, try to do a clean re-connection and re-publish existing tracks
        @Sendable func fullReconnectSequence() async throws {
            log("[Connect] starting .full reconnect sequence...")

            _state.mutate {
                // Mark as Re-connecting
                $0.connectionState = .reconnecting
            }

            await cleanUp(isFullReconnect: true)

            guard let url = _state.url,
                  let token = _state.token
            else {
                log("[Connect] Url or token is nil")
                throw LiveKitError(.invalidState)
            }

            try await fullConnectSequence(url, token)
        }

        do {
            try await Task.retrying(totalAttempts: _state.connectOptions.reconnectAttempts,
                                    retryDelay: _state.connectOptions.reconnectAttemptDelay)
            { currentAttempt, totalAttempts in

                // Not reconnecting state anymore
                guard let currentMode = self._state.isReconnectingWithMode else {
                    self.log("[Connect] Not in reconnect state anymore, exiting retry cycle.")
                    return
                }

                // Full reconnect failed, give up
                guard currentMode != .full else { return }

                self.log("[Connect] Retry in \(self._state.connectOptions.reconnectAttemptDelay) seconds, \(currentAttempt)/\(totalAttempts) tries left.")

                // Try full reconnect for the final attempt
                if totalAttempts == currentAttempt, self._state.nextReconnectMode == nil {
                    self._state.mutate { $0.nextReconnectMode = .full }
                }

                let mode: ReconnectMode = self._state.mutate {
                    let mode: ReconnectMode = ($0.nextReconnectMode == .full || $0.isReconnectingWithMode == .full) ? .full : .quick
                    $0.isReconnectingWithMode = mode
                    $0.nextReconnectMode = nil
                    return mode
                }

                do {
                    if case .quick = mode {
                        try await quickReconnectSequence()
                    } else if case .full = mode {
                        try await fullReconnectSequence()
                    }
                } catch {
                    self.log("[Connect] Reconnect mode: \(mode) failed with error: \(error)", .error)
                    // Re-throw
                    throw error
                }
            }.value

            // Re-connect sequence successful
            log("[Connect] Sequence completed")
            _state.mutate {
                $0.connectionState = .connected
                $0.isReconnectingWithMode = nil
                $0.nextReconnectMode = nil
            }
        } catch {
            log("[Connect] Sequence failed with error: \(error)")

            if !Task.isCancelled {
                // Finally disconnect if all attempts fail
                await cleanUp(withError: error)
            }
        }
    }
}

// MARK: - Session Migration

extension Room {
    func sendSyncState() async throws {
        guard let subscriber = _state.subscriber else {
            log("Subscriber is nil", .error)
            return
        }

        let previousAnswer = await subscriber.localDescription
        let previousOffer = await subscriber.remoteDescription

        // 1. autosubscribe on, so subscribed tracks = all tracks - unsub tracks,
        //    in this case, we send unsub tracks, so server add all tracks to this
        //    subscribe pc and unsub special tracks from it.
        // 2. autosubscribe off, we send subscribed tracks.

        let autoSubscribe = _state.connectOptions.autoSubscribe
        let trackSids = _state.remoteParticipants.values.flatMap { participant in
            participant._state.trackPublications.values
                .filter { $0.isSubscribed != autoSubscribe }
                .map(\.sid)
        }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids.map(\.stringValue)
            $0.participantTracks = []
            $0.subscribe = !autoSubscribe
        }

        try await signalClient.sendSyncState(answer: previousAnswer?.toPBType(),
                                             offer: previousOffer?.toPBType(),
                                             subscription: subscription,
                                             publishTracks: localParticipant.publishedTracksInfo(),
                                             dataChannels: publisherDataChannel.infos())
    }
}

// MARK: - 辅助方法

extension Room {
    // 获取发布者传输对象，确保其存在
    func requirePublisher() throws -> Transport {
        guard let publisher = _state.publisher else {
            log("Publisher is nil", .error)
            throw LiveKitError(.invalidState, message: "Publisher is nil")
        }

        return publisher
    }
}
