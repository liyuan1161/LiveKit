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

import DequeModule
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// MARK: - 数据通道委托协议

// 定义接收数据包的委托接口
protocol DataChannelDelegate {
    func dataChannel(_ dataChannelPair: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket)
}

// 数据通道对类，管理两种类型的WebRTC数据通道
class DataChannelPair: NSObject, Loggable {
    // MARK: - 公共属性

    // 多播委托系统，用于通知多个监听者数据接收事件
    public let delegates = MulticastDelegate<DataChannelDelegate>(label: "DataChannelDelegate")

    // 数据通道打开完成器，用于异步等待通道就绪
    public let openCompleter = AsyncCompleter<Void>(label: "Data channel open", defaultTimeout: .defaultPublisherDataChannelOpen)

    // 判断数据通道是否打开
    public var isOpen: Bool { _state.isOpen }

    // MARK: - 私有状态

    // 内部状态结构体，存储通道引用和状态
    private struct State {
        var lossy: LKRTCDataChannel?     // 有损数据通道（适用于低延迟优先的数据）
        var reliable: LKRTCDataChannel?  // 可靠数据通道（确保数据完整性）

        // 检查两个通道是否都打开
        var isOpen: Bool {
            guard let lossy, let reliable else { return false }
            return reliable.readyState == .open && lossy.readyState == .open
        }
    }

    // 线程安全的状态存储
    private let _state: StateSync<State>

    // 数据通道类型枚举
    fileprivate enum ChannelKind {
        case lossy, reliable
    }

    // 缓冲状态结构体，管理发送队列
    private struct BufferingState {
        var queue: Deque<PublishDataRequest> = []  // 发送请求队列
        var amount: UInt64 = 0                    // 当前缓冲区大小
    }

    // 发布数据请求结构体
    private struct PublishDataRequest {
        let data: LKRTCDataBuffer                      // 要发送的数据
        let continuation: CheckedContinuation<Void, any Error>?  // 异步续体
    }

    // 通道事件结构体，用于事件驱动的处理
    private struct ChannelEvent {
        let channelKind: ChannelKind  // 通道类型
        let detail: Detail           // 事件详情

        // 事件详情枚举
        enum Detail {
            case publishData(PublishDataRequest)      // 发布数据请求
            case bufferedAmountChanged(UInt64)        // 缓冲区大小变化
        }
    }

    // 事件处理续体
    private var eventContinuation: AsyncStream<ChannelEvent>.Continuation?

    // 处理通道事件的异步任务
    @Sendable private func handleEvents(
        events: AsyncStream<ChannelEvent>
    ) async {
        // 初始化缓冲状态
        var lossyBuffering = BufferingState()
        var reliableBuffering = BufferingState()

        // 处理事件流
        for await event in events {
            switch event.detail {
            case let .publishData(request):
                // 根据通道类型将请求加入相应队列
                switch event.channelKind {
                case .lossy: lossyBuffering.queue.append(request)
                case .reliable: reliableBuffering.queue.append(request)
                }
            case let .bufferedAmountChanged(amount):
                // 根据通道类型更新缓冲状态
                switch event.channelKind {
                case .lossy: updateBufferingState(state: &lossyBuffering, newAmount: amount)
                case .reliable: updateBufferingState(state: &reliableBuffering, newAmount: amount)
                }
            }

            // 处理发送队列
            switch event.channelKind {
            case .lossy:
                processSendQueue(
                    threshold: Self.lossyLowThreshold,
                    state: &lossyBuffering,
                    kind: .lossy
                )
            case .reliable:
                processSendQueue(
                    threshold: Self.reliableLowThreshold,
                    state: &reliableBuffering,
                    kind: .reliable
                )
            }
        }
    }

    // 获取指定类型的通道
    private func channel(for kind: ChannelKind) -> LKRTCDataChannel? {
        _state.read {
            guard let lossy = $0.lossy, let reliable = $0.reliable, $0.isOpen else { return nil }
            return kind == .reliable ? reliable : lossy
        }
    }

    // 处理发送队列，实现流量控制
    private func processSendQueue(
        threshold: UInt64,
        state: inout BufferingState,
        kind: ChannelKind
    ) {
        // 当缓冲区低于阈值时继续发送
        while state.amount <= threshold {
            guard !state.queue.isEmpty else { break }
            let request = state.queue.removeFirst()

            // 更新缓冲区大小
            state.amount += UInt64(request.data.data.count)

            // 获取通道并发送数据
            guard let channel = channel(for: kind) else {
                request.continuation?.resume(
                    throwing: LiveKitError(.invalidState, message: "Data channel is not open")
                )
                return
            }
            guard channel.sendData(request.data) else {
                request.continuation?.resume(
                    throwing: LiveKitError(.invalidState, message: "sendData failed")
                )
                return
            }
            request.continuation?.resume()
        }
    }

    // 更新缓冲状态
    private func updateBufferingState(
        state: inout BufferingState,
        newAmount: UInt64
    ) {
        guard state.amount >= newAmount else {
            log("Unexpected buffer size detected", .error)
            state.amount = 0
            return
        }
        state.amount -= newAmount
    }

    // 初始化方法
    public init(delegate: DataChannelDelegate? = nil,
                lossyChannel: LKRTCDataChannel? = nil,
                reliableChannel: LKRTCDataChannel? = nil)
    {
        _state = StateSync(State(lossy: lossyChannel,
                                 reliable: reliableChannel))

        if let delegate {
            delegates.add(delegate: delegate)
        }
        super.init()

        // 创建并启动事件处理任务
        Task {
            let eventStream = AsyncStream<ChannelEvent> { continuation in
                self.eventContinuation = continuation
            }
            await handleEvents(events: eventStream)
        }
    }

    // 设置可靠通道
    public func set(reliable channel: LKRTCDataChannel?) {
        let isOpen = _state.mutate {
            $0.reliable = channel
            return $0.isOpen
        }

        channel?.delegate = self

        // 如果两个通道都打开，完成openCompleter
        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    // 设置有损通道
    public func set(lossy channel: LKRTCDataChannel?) {
        let isOpen = _state.mutate {
            $0.lossy = channel
            return $0.isOpen
        }

        channel?.delegate = self

        // 如果两个通道都打开，完成openCompleter
        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    // 重置通道，关闭所有连接
    public func reset() {
        let (lossy, reliable) = _state.mutate {
            let result = ($0.lossy, $0.reliable)
            $0.reliable = nil
            $0.lossy = nil
            return result
        }

        lossy?.close()
        reliable?.close()

        openCompleter.reset()
    }

    // 发送用户数据包
    public func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        try await send(dataPacket: .with {
            $0.kind = kind // TODO: field is deprecated
            $0.user = userPacket
        })
    }

    // 发送数据包的核心方法
    public func send(dataPacket packet: Livekit_DataPacket) async throws {
        // 序列化数据包
        let serializedData = try packet.serializedData()
        let rtcData = RTC.createDataBuffer(data: serializedData)

        // 使用异步/等待模式发送数据
        try await withCheckedThrowingContinuation { continuation in
            let request = PublishDataRequest(
                data: rtcData,
                continuation: continuation
            )
            let event = ChannelEvent(
                channelKind: ChannelKind(packet.kind), // TODO: field is deprecated
                detail: .publishData(request)
            )
            // 将发送请求作为事件提交
            eventContinuation?.yield(event)
        }
    }

    // 获取数据通道信息（用于信令）
    public func infos() -> [Livekit_DataChannelInfo] {
        _state.read { [$0.lossy, $0.reliable] }
            .compactMap { $0 }
            .map { $0.toLKInfoType() }
    }

    // 缓冲区阈值常量
    private static let reliableLowThreshold: UInt64 = 2 * 1024 * 1024 // 2 MB
    private static let lossyLowThreshold: UInt64 = reliableLowThreshold

    // 析构函数，清理事件流
    deinit {
        eventContinuation?.finish()
    }
}

// MARK: - RTCDataChannelDelegate 实现

extension DataChannelPair: LKRTCDataChannelDelegate {
    // 监听缓冲区大小变化
    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        let event = ChannelEvent(
            channelKind: dataChannel.kind,
            detail: .bufferedAmountChanged(amount)
        )
        eventContinuation?.yield(event)
    }

    // 监听通道状态变化
    func dataChannelDidChangeState(_: LKRTCDataChannel) {
        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    // 处理接收到的消息
    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        // 尝试解码数据包
        guard let dataPacket = try? Livekit_DataPacket(serializedData: buffer.data) else {
            log("Could not decode data message", .error)
            return
        }

        // 通知所有委托
        delegates.notify {
            $0.dataChannel(self, didReceiveDataPacket: dataPacket)
        }
    }
}

// MARK: - 辅助扩展

// 从数据包类型确定通道类型
private extension DataChannelPair.ChannelKind {
    init(_ packetKind: Livekit_DataPacket.Kind) {
        guard case .lossy = packetKind else {
            self = .reliable
            return
        }
        self = .lossy
    }
}

// 从通道标签确定通道类型
private extension LKRTCDataChannel {
    var kind: DataChannelPair.ChannelKind {
        guard label == LKRTCDataChannel.labels.lossy else {
            return .reliable
        }
        return .lossy
    }
}
