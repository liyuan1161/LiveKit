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

// 传输层Actor，封装WebRTC对等连接的管理，确保线程安全
actor Transport: NSObject, Loggable {
    // MARK: - 类型定义

    // 定义处理提议的回调类型
    typealias OnOfferBlock = (LKRTCSessionDescription) async throws -> Void

    // MARK: - 公共属性

    // 信令目标，指示该传输层服务于哪个端点
    nonisolated let target: Livekit_SignalTarget
    // 是否为主传输层
    nonisolated let isPrimary: Bool

    // 获取连接状态
    var connectionState: RTCPeerConnectionState {
        _pc.connectionState
    }

    // 判断连接是否已建立
    var isConnected: Bool {
        connectionState == .connected
    }

    // 获取本地SDP描述
    var localDescription: LKRTCSessionDescription? {
        _pc.localDescription
    }

    // 获取远程SDP描述
    var remoteDescription: LKRTCSessionDescription? {
        _pc.remoteDescription
    }

    // 获取信令状态
    var signalingState: RTCSignalingState {
        _pc.signalingState
    }

    // MARK: - 私有属性

    // 传输层委托的多播管理器
    private let _delegate = MulticastDelegate<TransportDelegate>(label: "TransportDelegate")
    // 用于延迟处理操作的辅助类
    private let _debounce = Debounce(delay: 0.1)

    // 是否需要重新协商标志
    private var _reNegotiate: Bool = false
    // 提议回调处理
    private var _onOffer: OnOfferBlock?
    // 是否正在重启ICE
    private var _isRestartingIce: Bool = false

    // 禁止直接访问PeerConnection
    private let _pc: LKRTCPeerConnection

    // ICE候选队列，用于管理ICE候选的添加
    private lazy var _iceCandidatesQueue = QueueActor<IceCandidate>(onProcess: { [weak self] iceCandidate in
        guard let self else { return }

        do {
            try await self._pc.add(iceCandidate.toRTCType())
        } catch {
            self.log("Failed to add(iceCandidate:) with error: \(error)", .error)
        }
    })

    // 初始化传输层
    init(config: LKRTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate) throws
    {
        // 尝试创建对等连接
        guard let pc = RTC.createPeerConnection(config, constraints: .defaultPCConstraints) else {
            // log("[WebRTC] Failed to create PeerConnection", .error)
            throw LiveKitError(.webRTC, message: "Failed to create PeerConnection")
        }

        self.target = target
        isPrimary = primary
        _pc = pc

        super.init()
        log()

        // 设置委托和添加初始委托对象
        _pc.delegate = self
        _delegate.add(delegate: delegate)
    }

    deinit {
        log(nil, .trace)
    }

    // 协商媒体会话（延迟处理以避免频繁调用）
    func negotiate() async {
        await _debounce.schedule {
            try await self.createAndSendOffer()
        }
    }

    // 设置提议处理回调
    func set(onOfferBlock block: @escaping OnOfferBlock) {
        _onOffer = block
    }

    // 标记正在重启ICE
    func setIsRestartingIce() {
        _isRestartingIce = true
    }

    // 添加ICE候选
    func add(iceCandidate candidate: IceCandidate) async throws {
        // 只有在已收到远程描述且非ICE重启状态时才处理候选
        await _iceCandidatesQueue.process(candidate, if: remoteDescription != nil && !_isRestartingIce)
    }

    // 设置远程SDP描述
    func set(remoteDescription sd: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _pc.setRemoteDescription(sd) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // 恢复ICE候选处理队列
        await _iceCandidatesQueue.resume()

        // 重置ICE重启状态
        _isRestartingIce = false

        // 如果需要重新协商，则创建并发送提议
        if _reNegotiate {
            _reNegotiate = false
            try await createAndSendOffer()
        }
    }

    // 设置对等连接配置
    func set(configuration: LKRTCConfiguration) throws {
        if !_pc.setConfiguration(configuration) {
            throw LiveKitError(.webRTC, message: "Failed to set configuration")
        }
    }

    // 创建并发送SDP提议
    func createAndSendOffer(iceRestart: Bool = false) async throws {
        guard let _onOffer else {
            log("_onOffer is nil", .error)
            return
        }

        // 准备媒体约束
        var constraints = [String: String]()
        if iceRestart {
            log("Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            _isRestartingIce = true
        }

        // 如果已有本地提议且非ICE重启，则标记待重新协商
        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            _reNegotiate = true
            return
        }

        // 执行协商序列
        func _negotiateSequence() async throws {
            let offer = try await createOffer(for: constraints)
            try await set(localDescription: offer)
            try await _onOffer(offer)
        }

        // 特殊情况：已有本地提议但需要ICE重启
        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            try await set(remoteDescription: sd)
            return try await _negotiateSequence()
        }

        try await _negotiateSequence()
    }

    // 关闭传输层
    func close() async {
        // 取消延迟的协商任务
        await _debounce.cancel()

        // 停止监听委托事件
        _pc.delegate = nil
        // 移除所有发送器
        for sender in _pc.senders {
            _pc.removeTrack(sender)
        }

        // 关闭对等连接
        _pc.close()
    }
}

// MARK: - 统计信息相关方法

extension Transport {
    // 获取发送器的统计信息
    func statistics(for sender: LKRTCRtpSender) async -> LKRTCStatisticsReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<LKRTCStatisticsReport, Never>) in
            _pc.statistics(for: sender) { sd in
                continuation.resume(returning: sd)
            }
        }
    }

    // 获取接收器的统计信息
    func statistics(for receiver: LKRTCRtpReceiver) async -> LKRTCStatisticsReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<LKRTCStatisticsReport, Never>) in
            _pc.statistics(for: receiver) { sd in
                continuation.resume(returning: sd)
            }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate实现

extension Transport: LKRTCPeerConnectionDelegate {
    // 连接状态变更回调
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange state: RTCPeerConnectionState) {
        log("[Connect] Transport(\(target)) did update state: \(state.description)")
        _delegate.notify { $0.transport(self, didUpdateState: state) }
    }

    // ICE候选生成回调
    nonisolated func peerConnection(_: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        _delegate.notify { $0.transport(self, didGenerateIceCandidate: candidate.toLKType()) }
    }

    // 需要协商回调
    nonisolated func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {
        log("ShouldNegotiate for \(target)")
        _delegate.notify { $0.transportShouldNegotiate(self) }
    }

    // 添加轨道回调
    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("type: \(type(of: track)), track.id: \(track.trackId), streams: \(streams.map { "Stream(hash: \($0.hash), id: \($0.streamId), videoTracks: \($0.videoTracks.count), audioTracks: \($0.audioTracks.count))" })")
        _delegate.notify { $0.transport(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: streams) }
    }

    // 移除轨道回调
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didRemove track: \(track.trackId)")
        _delegate.notify { $0.transport(self, didRemoveTrack: track) }
    }

    // 数据通道打开回调
    nonisolated func peerConnection(_: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        log("Received data channel \(dataChannel.label) for \(target)")
        _delegate.notify { $0.transport(self, didOpenDataChannel: dataChannel) }
    }

    // 以下是未使用的委托方法
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCIceConnectionState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCSignalingState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCIceGatheringState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
}

// MARK: - 私有辅助方法

private extension Transport {
    // 创建SDP提议
    func createOffer(for constraints: [String: String]? = nil) async throws -> LKRTCSessionDescription {
        let mediaConstraints = LKRTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            _pc.offer(for: mediaConstraints) { sd, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sd {
                    continuation.resume(returning: sd)
                } else {
                    continuation.resume(throwing: LiveKitError(.invalidState, message: "No session description and no error were provided."))
                }
            }
        }
    }
}

// MARK: - 内部方法

extension Transport {
    // 创建SDP应答
    func createAnswer(for constraints: [String: String]? = nil) async throws -> LKRTCSessionDescription {
        let mediaConstraints = LKRTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            _pc.answer(for: mediaConstraints) { sd, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sd {
                    continuation.resume(returning: sd)
                } else {
                    continuation.resume(throwing: LiveKitError(.invalidState, message: "No session description and no error were provided."))
                }
            }
        }
    }

    // 设置本地SDP描述
    func set(localDescription sd: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _pc.setLocalDescription(sd) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // 添加收发器
    func addTransceiver(with track: LKRTCMediaStreamTrack,
                        transceiverInit: LKRTCRtpTransceiverInit) throws -> LKRTCRtpTransceiver
    {
        guard let transceiver = _pc.addTransceiver(with: track, init: transceiverInit) else {
            throw LiveKitError(.webRTC, message: "Failed to add transceiver")
        }

        return transceiver
    }

    // 移除轨道
    func remove(track sender: LKRTCRtpSender) throws {
        guard _pc.removeTrack(sender) else {
            throw LiveKitError(.webRTC, message: "Failed to remove track")
        }
    }

    // 创建数据通道
    func dataChannel(for label: String,
                     configuration: LKRTCDataChannelConfiguration,
                     delegate: LKRTCDataChannelDelegate? = nil) -> LKRTCDataChannel?
    {
        let result = _pc.dataChannel(forLabel: label, configuration: configuration)
        result?.delegate = delegate
        return result
    }
}
