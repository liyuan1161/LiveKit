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

// 信号客户端Actor，用于处理与LiveKit服务器的WebSocket通信
actor SignalClient: Loggable {
    // MARK: - 类型定义

    // 添加音频轨道请求填充器类型定义
    typealias AddTrackRequestPopulator<R> = (inout Livekit_AddTrackRequest) throws -> R
    typealias AddTrackResult<R> = (result: R, trackInfo: Livekit_TrackInfo)

    // 连接响应枚举，区分加入和重连两种响应类型
    public enum ConnectResponse: Sendable {
        case join(Livekit_JoinResponse)
        case reconnect(Livekit_ReconnectResponse)

        // 从响应中获取ICE服务器配置
        public var rtcIceServers: [LKRTCIceServer] {
            switch self {
            case let .join(response): return response.iceServers.map { $0.toRTCType() }
            case let .reconnect(response): return response.iceServers.map { $0.toRTCType() }
            }
        }

        // 从响应中获取客户端配置
        public var clientConfiguration: Livekit_ClientConfiguration {
            switch self {
            case let .join(response): return response.clientConfiguration
            case let .reconnect(response): return response.clientConfiguration
            }
        }
    }

    // MARK: - 公共属性

    // 连接状态管理
    public private(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            guard connectionState != oldValue else { return }
            // 连接状态更新时记录日志并通知委托
            log("\(oldValue) -> \(connectionState)")

            _delegate.notifyDetached { await $0.signalClient(self, didUpdateConnectionState: self.connectionState, oldState: oldValue, disconnectError: self.disconnectError) }
        }
    }

    // 断开连接错误
    public private(set) var disconnectError: LiveKitError?

    // MARK: - 私有属性

    // 异步串行委托处理器
    let _delegate = AsyncSerialDelegate<SignalClientDelegate>()
    private let _queue = DispatchQueue(label: "LiveKitSDK.signalClient", qos: .default)

    // 重连期间存储请求的队列
    private lazy var _requestQueue = QueueActor<Livekit_SignalRequest>(onProcess: { [weak self] request in
        guard let self else { return }

        do {
            // 准备请求数据
            guard let data = try? request.serializedData() else {
                self.log("Could not serialize request data", .error)
                throw LiveKitError(.failedToConvertData, message: "Failed to convert data")
            }

            let webSocket = try await self.requireWebSocket()
            try await webSocket.send(data: data)

        } catch {
            self.log("Failed to send queued request \(request) with error: \(error)", .warning)
        }
    })

    // 响应处理队列
    private lazy var _responseQueue = QueueActor<Livekit_SignalResponse>(onProcess: { [weak self] response in
        guard let self else { return }

        await self._process(signalResponse: response)
    })

    // WebSocket相关变量
    private var _webSocket: WebSocket?
    private var _messageLoopTask: Task<Void, Never>?
    private var _lastJoinResponse: Livekit_JoinResponse?

    // 异步完成器，用于处理连接响应
    private let _connectResponseCompleter = AsyncCompleter<ConnectResponse>(label: "Join response", defaultTimeout: .defaultJoinResponse)
    private let _addTrackCompleters = CompleterMapActor<Livekit_TrackInfo>(label: "Completers for add track", defaultTimeout: .defaultPublish)

    // 心跳定时器
    private var _pingIntervalTimer = AsyncTimer(interval: 1)
    private var _pingTimeoutTimer = AsyncTimer(interval: 1)

    init() {
        log()
    }

    deinit {
        log(nil, .trace)
    }

    // 连接到LiveKit服务器
    @discardableResult
    func connect(_ url: URL,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 reconnectMode: ReconnectMode? = nil,
                 participantSid: Participant.Sid? = nil,
                 adaptiveStream: Bool) async throws -> ConnectResponse
    {
        await cleanUp()

        if let reconnectMode {
            log("[Connect] mode: \(String(describing: reconnectMode))")
        }

        // 构建带有参数的连接URL
        let url = try Utils.buildUrl(url,
                                     token,
                                     connectOptions: connectOptions,
                                     reconnectMode: reconnectMode,
                                     participantSid: participantSid,
                                     adaptiveStream: adaptiveStream)

        if reconnectMode != nil {
            log("[Connect] with url: \(url)")
        } else {
            log("Connecting with url: \(url)")
        }

        // 根据是否为重连模式设置连接状态
        connectionState = (reconnectMode != nil ? .reconnecting : .connecting)

        do {
            // 创建WebSocket连接
            let socket = try await WebSocket(url: url, connectOptions: connectOptions)

            // 启动消息循环任务
            _messageLoopTask = Task.detached {
                self.log("Did enter WebSocket message loop...")
                do {
                    for try await message in socket {
                        await self._onWebSocketMessage(message: message)
                    }
                } catch {
                    await self.cleanUp(withError: error)
                }
            }

            // 等待连接响应
            let connectResponse = try await _connectResponseCompleter.wait()
            // 检查任务是否被取消
            try Task.checkCancellation()

            // 连接成功
            _webSocket = socket
            connectionState = .connected

            return connectResponse
        } catch {
            // 用户取消则跳过验证
            if error is CancellationError {
                await cleanUp(withError: error)
                throw error
            }

            // 重连模式跳过验证
            if reconnectMode != nil {
                await cleanUp(withError: error)
                throw error
            }

            await cleanUp(withError: error)

            // 如果连接失败，进行URL验证
            let validateUrl = try Utils.buildUrl(url,
                                                 token,
                                                 connectOptions: connectOptions,
                                                 participantSid: participantSid,
                                                 adaptiveStream: adaptiveStream,
                                                 validate: true)

            log("Validating with url: \(validateUrl)...")
            let validationResponse = try await HTTP.requestString(from: validateUrl)
            log("Validate response: \(validationResponse)")
            // 使用验证响应重新抛出错误
            throw LiveKitError(.network, message: "Validation response: \"\(validationResponse)\"")
        }
    }

    // 清理资源
    func cleanUp(withError disconnectError: Error? = nil) async {
        log("withError: \(String(describing: disconnectError))")

        // 取消所有定时器
        _pingIntervalTimer.cancel()
        _pingTimeoutTimer.cancel()

        // 取消消息循环任务
        _messageLoopTask?.cancel()
        _messageLoopTask = nil

        // 关闭WebSocket
        _webSocket?.close()
        _webSocket = nil

        // 重置各种状态和队列
        _connectResponseCompleter.reset()
        _lastJoinResponse = nil

        await _addTrackCompleters.reset()
        await _requestQueue.clear()
        await _responseQueue.clear()

        // 设置断开连接错误和状态
        self.disconnectError = LiveKitError.from(error: disconnectError)
        connectionState = .disconnected
    }
}

// MARK: - 私有方法

private extension SignalClient {
    // 发送请求或在重连期间将请求入队
    func _sendRequest(_ request: Livekit_SignalRequest) async throws {
        guard connectionState != .disconnected else {
            log("connectionState is .disconnected", .error)
            throw LiveKitError(.invalidState, message: "connectionState is .disconnected")
        }

        // 如果队列已恢复则直接处理请求，否则根据请求类型决定是否入队
        await _requestQueue.processIfResumed(request, elseEnqueue: request.canBeQueued())
    }

    // 处理WebSocket消息
    func _onWebSocketMessage(message: URLSessionWebSocketTask.Message) async {
        // 尝试解析信号响应
        let response: Livekit_SignalResponse? = {
            switch message {
            case let .data(data): return try? Livekit_SignalResponse(serializedData: data)
            case let .string(string): return try? Livekit_SignalResponse(jsonString: string)
            default: return nil
            }
        }()

        guard let response else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        Task.detached {
            // 判断是否需要立即处理的消息类型
            let alwaysProcess: Bool = {
                switch response.message {
                case .join, .reconnect, .leave: return true
                default: return false
                }
            }()
            // 重要消息即使队列暂停也会处理
            await self._responseQueue.processIfResumed(response, or: alwaysProcess)
        }
    }

    // 处理信号响应
    func _process(signalResponse: Livekit_SignalResponse) async {
        guard connectionState != .disconnected else {
            log("connectionState is .disconnected", .error)
            return
        }

        guard let message = signalResponse.message else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        // 根据消息类型分发处理
        switch message {
        case let .join(joinResponse):
            // 处理加入房间响应
            _lastJoinResponse = joinResponse
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveConnectResponse: .join(joinResponse)) }
            _connectResponseCompleter.resume(returning: .join(joinResponse))
            await _restartPingTimer()

        case let .reconnect(response):
            // 处理重连响应
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveConnectResponse: .reconnect(response)) }
            _connectResponseCompleter.resume(returning: .reconnect(response))
            await _restartPingTimer()

        case let .answer(sd):
            // 处理SDP应答
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveAnswer: sd.toRTCType()) }

        case let .offer(sd):
            // 处理SDP提议
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveOffer: sd.toRTCType()) }

        case let .trickle(trickle):
            // 处理ICE候选
            guard let rtcCandidate = try? RTC.createIceCandidate(fromJsonString: trickle.candidateInit) else {
                return
            }

            _delegate.notifyDetached { await $0.signalClient(self, didReceiveIceCandidate: rtcCandidate.toLKType(), target: trickle.target) }

        case let .update(update):
            // 处理参与者更新
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateParticipants: update.participants) }

        case let .roomUpdate(update):
            // 处理房间更新
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateRoom: update.room) }

        case let .trackPublished(trackPublished):
            // 处理轨道发布完成
            log("[publish] resolving completer for cid: \(trackPublished.cid)")
            // 完成发布操作
            await _addTrackCompleters.resume(returning: trackPublished.track, for: trackPublished.cid)

        case let .trackUnpublished(trackUnpublished):
            // 处理轨道取消发布
            _delegate.notifyDetached { await $0.signalClient(self, didUnpublishLocalTrack: trackUnpublished) }

        case let .speakersChanged(speakers):
            // 处理发言者变更
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateSpeakers: speakers.speakers) }

        case let .connectionQuality(quality):
            // 处理连接质量更新
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateConnectionQuality: quality.updates) }

        case let .mute(mute):
            // 处理远程静音状态变更
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateRemoteMute: Track.Sid(from: mute.sid), muted: mute.muted) }

        case let .leave(leave):
            // 处理离开房间
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveLeave: leave.canReconnect, reason: leave.reason) }

        case let .streamStateUpdate(states):
            // 处理流状态更新
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateTrackStreamStates: states.streamStates) }

        case let .subscribedQualityUpdate(update):
            // 处理订阅质量更新
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateSubscribedCodecs: update.subscribedCodecs,
                                                             qualities: update.subscribedQualities,
                                                             forTrackSid: update.trackSid) }

        case let .subscriptionPermissionUpdate(permissionUpdate):
            // 处理订阅权限更新
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateSubscriptionPermission: permissionUpdate) }

        case let .refreshToken(token):
            // 处理令牌刷新
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateToken: token) }

        case let .pong(r):
            // 处理服务器pong响应
            await _onReceivedPong(r)

        case .pongResp:
            log("Received pongResp message")

        case .subscriptionResponse:
            log("Received subscriptionResponse message")

        case .requestResponse:
            log("Received requestResponse message")

        case let .trackSubscribed(trackSubscribed):
            // 处理轨道订阅成功
            _delegate.notifyDetached { await $0.signalClient(self, didSubscribeTrack: Track.Sid(from: trackSubscribed.trackSid)) }
        }
    }
}

// MARK: - 内部方法

extension SignalClient {
    // 恢复队列处理
    func resumeQueues() async {
        await _responseQueue.resume()
        await _requestQueue.resume()
    }
}

// MARK: - 发送方法

extension SignalClient {
    // 发送SDP提议
    func send(offer: LKRTCSessionDescription) async throws {
        let r = Livekit_SignalRequest.with {
            $0.offer = offer.toPBType()
        }

        try await _sendRequest(r)
    }

    // 发送SDP应答
    func send(answer: LKRTCSessionDescription) async throws {
        let r = Livekit_SignalRequest.with {
            $0.answer = answer.toPBType()
        }

        try await _sendRequest(r)
    }

    // 发送ICE候选
    func sendCandidate(candidate: IceCandidate, target: Livekit_SignalTarget) async throws {
        let r = try Livekit_SignalRequest.with {
            $0.trickle = try Livekit_TrickleRequest.with {
                $0.target = target
                $0.candidateInit = try candidate.toJsonString()
            }
        }

        try await _sendRequest(r)
    }

    // 发送静音轨道请求
    func sendMuteTrack(trackSid: Track.Sid, muted: Bool) async throws {
        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid.stringValue
                $0.muted = muted
            }
        }

        try await _sendRequest(r)
    }

    // 发送添加轨道请求
    func sendAddTrack<R>(cid: String,
                         name: String,
                         type: Livekit_TrackType,
                         source: Livekit_TrackSource = .unknown,
                         encryption: Livekit_Encryption.TypeEnum = .none,
                         _ populator: AddTrackRequestPopulator<R>) async throws -> AddTrackResult<R>
    {
        // 准备添加轨道请求
        var addTrackRequest = Livekit_AddTrackRequest.with {
            $0.cid = cid
            $0.name = name
            $0.type = type
            $0.source = source
            $0.encryption = encryption
        }

        // 调用填充器填充请求
        let populateResult = try populator(&addTrackRequest)

        let request = Livekit_SignalRequest.with {
            $0.addTrack = addTrackRequest
        }

        // 获取此添加轨道请求的完成器
        let completer = await _addTrackCompleters.completer(for: cid)

        // 发送请求到服务器
        try await _sendRequest(request)

        // 等待轨道信息返回
        let trackInfo = try await completer.wait()

        return AddTrackResult(result: populateResult, trackInfo: trackInfo)
    }

    // 发送更新轨道设置请求
    func sendUpdateTrackSettings(trackSid: Track.Sid, settings: TrackSettings) async throws {
        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [trackSid.stringValue]
                $0.disabled = !settings.isEnabled
                $0.width = UInt32(settings.dimensions.width)
                $0.height = UInt32(settings.dimensions.height)
                $0.quality = settings.videoQuality.toPBType()
                $0.fps = UInt32(settings.preferredFPS)
            }
        }

        try await _sendRequest(r)
    }

    // 发送更新视频层请求
    func sendUpdateVideoLayers(trackSid: Track.Sid, layers: [Livekit_VideoLayer]) async throws {
        let r = Livekit_SignalRequest.with {
            $0.updateLayers = Livekit_UpdateVideoLayers.with {
                $0.trackSid = trackSid.stringValue
                $0.layers = layers
            }
        }

        try await _sendRequest(r)
    }

    // 发送更新订阅请求
    func sendUpdateSubscription(participantSid: Participant.Sid,
                                trackSid: Track.Sid,
                                isSubscribed: Bool) async throws
    {
        let p = Livekit_ParticipantTracks.with {
            $0.participantSid = participantSid.stringValue
            $0.trackSids = [trackSid.stringValue]
        }

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [trackSid.stringValue]
                $0.participantTracks = [p]
                $0.subscribe = isSubscribed
            }
        }

        try await _sendRequest(r)
    }

    // 发送更新订阅权限请求
    func sendUpdateSubscriptionPermission(allParticipants: Bool,
                                          trackPermissions: [ParticipantTrackPermission]) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.subscriptionPermission = Livekit_SubscriptionPermission.with {
                $0.allParticipants = allParticipants
                $0.trackPermissions = trackPermissions.map { $0.toPBType() }
            }
        }

        try await _sendRequest(r)
    }

    // 发送更新参与者信息请求
    func sendUpdateParticipant(name: String? = nil,
                               metadata: String? = nil,
                               attributes: [String: String]? = nil) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.updateMetadata = Livekit_UpdateParticipantMetadata.with {
                $0.name = name ?? ""
                $0.metadata = metadata ?? ""
                $0.attributes = attributes ?? [:]
            }
        }

        try await _sendRequest(r)
    }

    // 发送更新本地音频轨道请求
    func sendUpdateLocalAudioTrack(trackSid: Track.Sid, features: Set<Livekit_AudioTrackFeature>) async throws {
        let r = Livekit_SignalRequest.with {
            $0.updateAudioTrack = Livekit_UpdateLocalAudioTrack.with {
                $0.trackSid = trackSid.stringValue
                $0.features = Array(features)
            }
        }

        try await _sendRequest(r)
    }

    // 发送同步状态请求
    func sendSyncState(answer: Livekit_SessionDescription?,
                       offer: Livekit_SessionDescription?,
                       subscription: Livekit_UpdateSubscription,
                       publishTracks: [Livekit_TrackPublishedResponse]? = nil,
                       dataChannels: [Livekit_DataChannelInfo]? = nil) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.syncState = Livekit_SyncState.with {
                if let answer {
                    $0.answer = answer
                }
                if let offer {
                    $0.offer = offer
                }
                $0.subscription = subscription
                $0.publishTracks = publishTracks ?? []
                $0.dataChannels = dataChannels ?? []
            }
        }

        try await _sendRequest(r)
    }

    // 发送离开请求
    func sendLeave() async throws {
        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest.with {
                $0.canReconnect = false
                $0.reason = .clientInitiated
            }
        }

        try await _sendRequest(r)
    }

    // 发送模拟场景请求（用于测试）
    func sendSimulate(scenario: SimulateScenario) async throws {
        var shouldDisconnect = false

        let r = Livekit_SignalRequest.with {
            $0.simulate = Livekit_SimulateScenario.with {
                switch scenario {
                case .nodeFailure: $0.nodeFailure = true
                case .migration: $0.migration = true
                case .serverLeave: $0.serverLeave = true
                case let .speakerUpdate(secs): $0.speakerUpdate = Int32(secs)
                case .forceTCP:
                    $0.switchCandidateProtocol = Livekit_CandidateProtocol.tcp
                    shouldDisconnect = true
                case .forceTLS:
                    $0.switchCandidateProtocol = Livekit_CandidateProtocol.tls
                    shouldDisconnect = true
                default: break
                }
            }
        }

        defer {
            if shouldDisconnect {
                Task.detached {
                    await self.cleanUp()
                }
            }
        }

        try await _sendRequest(r)
    }

    // 发送ping请求
    private func _sendPing() async throws {
        let r = Livekit_SignalRequest.with {
            $0.ping = Int64(Date().timeIntervalSince1970)
        }

        try await _sendRequest(r)
    }
}

// MARK: - 服务器ping/pong逻辑

private extension SignalClient {
    // ping间隔定时器触发
    func _onPingIntervalTimer() async throws {
        guard let jr = _lastJoinResponse else { return }
        log("ping/pong sending ping...", .trace)
        try await _sendPing()

        // 设置ping超时定时器
        _pingTimeoutTimer.setTimerInterval(TimeInterval(jr.pingTimeout))
        _pingTimeoutTimer.setTimerBlock { [weak self] in
            guard let self else { return }
            self.log("ping/pong timed out", .error)
            await self.cleanUp(withError: LiveKitError(.serverPingTimedOut))
        }

        _pingTimeoutTimer.startIfStopped()
    }

    // 收到pong响应
    func _onReceivedPong(_: Int64) async {
        log("ping/pong received pong from server", .trace)
        // 清除超时定时器
        _pingTimeoutTimer.cancel()
    }

    // 重启ping定时器
    func _restartPingTimer() async {
        // 先取消现有定时器
        _pingIntervalTimer.cancel()
        _pingTimeoutTimer.cancel()

        // 检查之前接收到的加入响应
        guard let jr = _lastJoinResponse,
              // 检查服务器是否支持ping/pong
              jr.pingTimeout > 0,
              jr.pingInterval > 0 else { return }

        log("ping/pong starting with interval: \(jr.pingInterval), timeout: \(jr.pingTimeout)")

        // 更新定时器间隔
        _pingIntervalTimer.setTimerInterval(TimeInterval(jr.pingInterval))
        _pingIntervalTimer.setTimerBlock { [weak self] in
            guard let self else { return }
            try await self._onPingIntervalTimer()
        }
        _pingIntervalTimer.restart()
    }
}

// 扩展SignalRequest，判断请求是否可以入队
extension Livekit_SignalRequest {
    func canBeQueued() -> Bool {
        switch message {
        case .syncState, .trickle, .offer, .answer, .simulate, .leave: return false
        default: return true
        }
    }
}

// 获取WebSocket实例的辅助方法
private extension SignalClient {
    func requireWebSocket() async throws -> WebSocket {
        guard let result = _webSocket else {
            log("WebSocket is nil", .error)
            throw LiveKitError(.invalidState, message: "WebSocket is nil")
        }

        return result
    }
}
