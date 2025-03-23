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

// Room类是LiveKit SDK的核心类，管理整个实时通信会话
@objc
public class Room: NSObject, ObservableObject, Loggable {
    // MARK: - 多播委托

    // 用于通知多个监听者的委托系统
    public let delegates: MulticastDelegate<any RoomDelegate> = MulticastDelegate<RoomDelegate>(label: "RoomDelegate")

    // MARK: - 公共属性

    /// 服务器分配的房间ID
    @objc
    public var sid: Sid? { _state.sid }

    /// 服务器分配的房间ID（异步版本）
    @objc
    public func sid() async throws -> Sid {
        try await _sidCompleter.wait()
    }

    // 房间名称
    @objc
    public var name: String? { _state.name }

    /// 房间元数据
    @objc
    public var metadata: String? { _state.metadata }

    // 服务器版本
    @objc
    public var serverVersion: String? { _state.serverInfo?.version.nilIfEmpty }

    /// 客户端当前连接的区域代码
    @objc
    public var serverRegion: String? { _state.serverInfo?.region.nilIfEmpty }

    /// 客户端当前连接的节点ID
    @objc
    public var serverNodeId: String? { _state.serverInfo?.nodeID.nilIfEmpty }

    // 远程参与者字典（以身份标识为键）
    @objc
    public var remoteParticipants: [Participant.Identity: RemoteParticipant] { _state.remoteParticipants }

    // 当前活跃发言者列表
    @objc
    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    // 房间创建时间
    @objc
    public var creationTime: Date? { _state.creationTime }

    /// 当前房间是否有具有recorder:true JWT权限的参与者
    @objc
    public var isRecording: Bool { _state.isRecording }

    // 最大参与者数量
    @objc
    public var maxParticipants: Int { _state.maxParticipants }

    // 当前参与者数量
    @objc
    public var participantCount: Int { _state.numParticipants }

    // 发布者数量
    @objc
    public var publishersCount: Int { _state.numPublishers }

    // 暴露引擎变量
    @objc
    public var url: String? { _state.url?.absoluteString }

    @objc
    public var token: String? { _state.token }

    /// 房间当前的连接状态
    @objc
    public var connectionState: ConnectionState { _state.connectionState }

    // 断开连接错误
    @objc
    public var disconnectError: LiveKitError? { _state.disconnectError }

    // 连接计时器
    public var connectStopwatch: Stopwatch { _state.connectStopwatch }

    // MARK: - 内部属性

    // 端到端加密管理器
    public var e2eeManager: E2EEManager?

    // 本地参与者实例
    @objc
    public lazy var localParticipant: LocalParticipant = .init(room: self)

    // 传输连接完成器，用于异步等待传输连接状态
    let primaryTransportConnectedCompleter = AsyncCompleter<Void>(label: "Primary transport connect", defaultTimeout: .defaultTransportState)
    let publisherTransportConnectedCompleter = AsyncCompleter<Void>(label: "Publisher transport connect", defaultTimeout: .defaultTransportState)

    // 信令客户端，处理与LiveKit服务器的WebSocket通信
    let signalClient = SignalClient()

    // MARK: - 数据通道

    // 订阅者和发布者数据通道对
    lazy var subscriberDataChannel = DataChannelPair(delegate: self)
    lazy var publisherDataChannel = DataChannelPair(delegate: self)

    // 流媒体管理器
    lazy var incomingStreamManager = IncomingStreamManager()
    lazy var outgoingStreamManager = OutgoingStreamManager { [weak self] packet in
        try await self?.send(dataPacket: packet)
    }

    // MARK: - 预连接

    // 预连接音频缓冲区，用于在连接建立前缓存音频
    lazy var preConnectBuffer = PreConnectAudioBuffer(room: self)

    // MARK: - 队列

    // 用于处理待处理块的队列
    var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                           qos: .default)

    // 待处理块队列
    var _queuedBlocks = [ConditionalExecutionEntry]()

    // MARK: - RPC

    // RPC状态管理器
    let rpcState = RpcStateManager()

    // MARK: - 状态

    // Room内部状态结构体
    struct State: Equatable {
        // 连接和房间选项
        var connectOptions: ConnectOptions
        var roomOptions: RoomOptions

        // 房间信息
        var sid: Sid?
        var name: String?
        var metadata: String?

        // 参与者管理
        var remoteParticipants = [Participant.Identity: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        // 房间属性
        var creationTime: Date?
        var isRecording: Bool = false

        var maxParticipants: Int = 0
        var numParticipants: Int = 0
        var numPublishers: Int = 0

        var serverInfo: Livekit_ServerInfo?

        // 引擎属性
        var url: URL?
        var token: String?
        // 下次重连尝试的首选重连模式
        var nextReconnectMode: ReconnectMode?
        var isReconnectingWithMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false

        // 传输层管理 - 关键的P2P连接管理
        var publisher: Transport?      // 发布者传输通道（用于发送媒体）
        var subscriber: Transport?     // 订阅者传输通道（用于接收媒体）
        var isSubscriberPrimary: Bool = false  // 订阅者是否为主传输通道

        // 代理
        var transcriptionReceivedTimes: [String: Date] = [:]

        // 更新远程参与者信息
        @discardableResult
        mutating func updateRemoteParticipant(info: Livekit_ParticipantInfo, room: Room) -> RemoteParticipant {
            let identity = Participant.Identity(from: info.identity)
            // 检查是否已存在具有相同身份的RemoteParticipant
            if let participant = remoteParticipants[identity] { return participant }
            // 创建新的RemoteParticipant
            let participant = RemoteParticipant(info: info, room: room, connectionState: connectionState)
            remoteParticipants[identity] = participant
            return participant
        }

        // 通过Sid查找RemoteParticipant
        func remoteParticipant(forSid sid: Participant.Sid) -> RemoteParticipant? {
            remoteParticipants.values.first(where: { $0.sid == sid })
        }
    }

    // 线程安全的状态管理
    let _state: StateSync<State>

    // 房间ID完成器
    private let _sidCompleter = AsyncCompleter<Sid>(label: "sid", defaultTimeout: .resolveSid)

    // MARK: Objective-C 支持

    @objc
    override public convenience init() {
        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    // 初始化方法
    @objc
    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil)
    {
        // 确保设备管理器和音频管理器已准备就绪
        DeviceManager.prepare()
        AudioManager.prepare()

        // 初始化状态
        _state = StateSync(State(connectOptions: connectOptions ?? ConnectOptions(),
                                 roomOptions: roomOptions ?? RoomOptions()))

        super.init()
        // 记录SDK和操作系统版本
        log("sdk: \(LiveKitSDK.version), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        // 设置信令客户端委托
        signalClient._delegate.set(delegate: self)

        log()

        // 添加委托
        if let delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // 监听应用状态
        AppStateListener.shared.delegates.add(delegate: self)

        // 设置状态变更监听器
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            // 房间ID更新
            if let sid = newState.sid, sid != oldState.sid {
                // 解析房间ID
                self._sidCompleter.resume(returning: sid)
            }

            if case .connected = newState.connectionState {
                // 元数据更新
                if let metadata = newState.metadata, metadata != oldState.metadata,
                   // 仅在非空时通知（首次除外）
                   oldState.metadata == nil ? !metadata.isEmpty : true
                {
                    self.delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdateMetadata: metadata)
                    }
                }

                // 录制状态更新
                if newState.isRecording != oldState.isRecording {
                    self.delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdateIsRecording: newState.isRecording)
                    }
                }
            }

            // 重连模式验证
            if newState.connectionState == .reconnecting, newState.isReconnectingWithMode == nil {
                self.log("reconnectMode should not be .none", .error)
            }

            // 连接状态或重连模式变更日志
            if (newState.connectionState != oldState.connectionState) || (newState.isReconnectingWithMode != oldState.isReconnectingWithMode) {
                self.log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: newState.isReconnectingWithMode))")
            }

            // 通知引擎状态变更
            self.engine(self, didMutateState: newState, oldState: oldState)

            // 执行控制 - 处理队列中的条件块
            self._blockProcessQueue.async { [weak self] in
                guard let self, !self._queuedBlocks.isEmpty else { return }

                self.log("[execution control] processing pending entries (\(self._queuedBlocks.count))...")

                self._queuedBlocks.removeAll { entry in
                    // 如果匹配移除条件，则返回并移除此条目
                    guard !entry.removeCondition(newState, oldState) else { return true }
                    // 如果不匹配执行条件，则返回但不移除此条目
                    guard entry.executeCondition(newState, oldState) else { return false }

                    self.log("[execution control] condition matching block...")
                    entry.block()
                    // 移除此条目
                    return true
                }
            }

            // 通知Room状态变更，触发SwiftUI更新
            Task.detached { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    deinit {
        log(nil, .trace)
    }

    // 连接到房间
    @objc
    public func connect(url: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) async throws
    {
        // 验证URL格式
        guard let url = URL(string: url), url.isValidForConnect else {
            log("URL parse failed", .error)
            throw LiveKitError(.failedToParseUrl)
        }

        log("Connecting to room...", .info)

        var state = _state.copy()

        // 更新房间选项（如果指定）
        if let roomOptions, roomOptions != state.roomOptions {
            state = _state.mutate {
                $0.roomOptions = roomOptions
                return $0
            }
        }

        // 更新连接选项（如果指定）
        if let connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        // 启用端到端加密（如果配置了）
        if let e2eeOptions = state.roomOptions.e2eeOptions {
            e2eeManager = E2EEManager(e2eeOptions: e2eeOptions)
            e2eeManager!.setup(room: self)
        }

        // 清理现有连接
        await cleanUp()

        // 检查任务是否被取消
        try Task.checkCancellation()

        // 更新连接状态为连接中
        _state.mutate { $0.connectionState = .connecting }

        do {
            // 执行完整连接序列
            try await fullConnectSequence(url, token)

            // 连接序列成功
            log("Connect sequence completed")

            // 最终检查是否被取消，避免触发已连接事件
            try Task.checkCancellation()

            // 更新内部变量（仅在连接成功时）
            _state.mutate {
                $0.url = url
                $0.token = token
                $0.connectionState = .connected
            }

        } catch {
            // 清理并传递错误
            await cleanUp(withError: error)
            // 重新抛出错误
            throw error
        }

        log("Connected to \(String(describing: self))", .info)
    }

    // 断开与房间的连接
    @objc
    public func disconnect() async {
        // 如果已处于断开状态则直接返回
        if case .disconnected = connectionState { return }

        // 尝试发送离开信号
        do {
            try await signalClient.sendLeave()
        } catch {
            log("Failed to send leave with error: \(error)")
        }

        // 清理资源
        await cleanUp()
    }
}

// MARK: - 内部方法

extension Room {
    // 重置房间状态
    func cleanUp(withError disconnectError: Error? = nil,
                 isFullReconnect: Bool = false) async
    {
        log("withError: \(String(describing: disconnectError)), isFullReconnect: \(isFullReconnect)")

        // 重置完成器
        _sidCompleter.reset()
        primaryTransportConnectedCompleter.reset()
        publisherTransportConnectedCompleter.reset()

        // 清理信令客户端
        await signalClient.cleanUp(withError: disconnectError)
        // 清理RTC资源
        await cleanUpRTC()
        // 清理参与者资源
        await cleanUpParticipants(isFullReconnect: isFullReconnect)

        // 清理端到端加密
        if let e2eeManager {
            e2eeManager.cleanUp()
        }

        // 如果有错误则停止预连接录制
        if disconnectError != nil {
            preConnectBuffer.stopRecording(flush: true)
        }

        // 重置状态
        _state.mutate {
            // 如果是完全重连，保留连接相关状态
            $0 = isFullReconnect ? State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                url: $0.url,
                token: $0.token,
                nextReconnectMode: $0.nextReconnectMode,
                isReconnectingWithMode: $0.isReconnectingWithMode,
                connectionState: $0.connectionState
            ) : State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                connectionState: .disconnected,
                disconnectError: LiveKitError.from(error: disconnectError)
            )
        }
    }
}

// MARK: - 内部方法

extension Room {
    // 清理参与者资源
    func cleanUpParticipants(isFullReconnect: Bool = false, notify _notify: Bool = true) async {
        log("notify: \(_notify)")

        // 收集所有本地和远程参与者
        var allParticipants: [Participant] = Array(_state.remoteParticipants.values)
        if !isFullReconnect {
            allParticipants.append(localParticipant)
        }

        // 并发清理所有参与者
        await withTaskGroup(of: Void.self) { group in
            for participant in allParticipants {
                group.addTask {
                    await participant.cleanUp(notify: _notify)
                }
            }

            await group.waitForAll()
        }

        // 清空远程参与者字典
        _state.mutate {
            $0.remoteParticipants = [:]
        }
    }

    // 处理参与者断开连接
    func _onParticipantDidDisconnect(identity: Participant.Identity) async throws {
        // 从状态中移除参与者
        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: identity) }) else {
            throw LiveKitError(.invalidState, message: "Participant not found for \(identity)")
        }

        // 清理参与者资源
        await participant.cleanUp(notify: true)
    }
}

// MARK: - 会话迁移

extension Room {
    // 重置所有轨道设置
    func resetTrackSettings() {
        log("resetting track settings...")

        // 创建所有远程轨道发布对象的数组
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }
        }.joined()

        // 重置所有远程轨道的设置
        for publication in remoteTrackPublications {
            publication.resetTrackSettings()
        }
    }
}

// MARK: - 应用状态委托

extension Room: AppStateDelegate {
    // 应用进入后台
    func appDidEnterBackground() {
        guard _state.roomOptions.suspendLocalVideoTracksInBackground else { return }

        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.suspend()
                } catch {
                    self.log("Failed to suspend video track with error: \(error)")
                }
            }
        }
    }

    // 应用即将进入前台
    func appWillEnterForeground() {
        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.resume()
                } catch {
                    self.log("Failed to resumed video track with error: \(error)")
                }
            }
        }
    }

    // 应用即将终止
    func appWillTerminate() {
        // 尝试断开连接（如果已连接）
        // 这不能保证，因为没有可靠的方法检测应用终止
        Task.detached {
            await self.disconnect()
        }
    }

    // 应用即将睡眠
    func appWillSleep() {
        Task.detached {
            await self.disconnect()
        }
    }

    // 应用唤醒
    func appDidWake() {}
}

// MARK: - 设备

public extension Room {
    /// 设置为true以绕过语音处理初始化
    @available(*, deprecated, renamed: "AudioManager.shared.isVoiceProcessingBypassed")
    @objc
    static var bypassVoiceProcessing: Bool {
        get { AudioManager.shared.isVoiceProcessingBypassed }
        set { AudioManager.shared.isVoiceProcessingBypassed = newValue }
    }
}

// MARK: - 数据通道委托

extension Room: DataChannelDelegate {
    // 处理接收到的数据包
    func dataChannel(_: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket) {
        switch dataPacket.value {
        case let .speaker(update): engine(self, didUpdateSpeakers: update.speakers)
        case let .user(userPacket): engine(self, didReceiveUserPacket: userPacket)
        case let .transcription(packet): room(didReceiveTranscriptionPacket: packet)
        case let .rpcResponse(response): room(didReceiveRpcResponse: response)
        case let .rpcAck(ack): room(didReceiveRpcAck: ack)
        case let .rpcRequest(request): room(didReceiveRpcRequest: request, from: dataPacket.participantIdentity)
        case let .streamHeader(header): Task { await incomingStreamManager.handle(header: header, from: dataPacket.participantIdentity) }
        case let .streamChunk(chunk): Task { await incomingStreamManager.handle(chunk: chunk) }
        case let .streamTrailer(trailer): Task { await incomingStreamManager.handle(trailer: trailer) }
        default: return
        }
    }
}
