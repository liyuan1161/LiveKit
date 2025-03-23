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

// 为RTCPeerConnectionState扩展辅助方法，简化连接状态判断
extension RTCPeerConnectionState {
    // 判断是否为已连接状态
    var isConnected: Bool {
        self == .connected
    }

    // 判断是否为断开连接状态（包括失败状态）
    var isDisconnected: Bool {
        [.disconnected, .failed].contains(self)
    }
}

// Room实现TransportDelegate协议，处理传输层事件
extension Room: TransportDelegate {
    // 处理传输层连接状态变化
    func transport(_ transport: Transport, didUpdateState pcState: RTCPeerConnectionState) {
        log("target: \(transport.target), connectionState: \(pcState.description)")

        // 主传输通道连接状态处理
        if transport.isPrimary {
            if pcState.isConnected {
                // 主传输连接成功，完成等待
                primaryTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                // 主传输断开，重置完成器
                primaryTransportConnectedCompleter.reset()
            }
        }

        // 发布者传输通道连接状态处理
        if case .publisher = transport.target {
            if pcState.isConnected {
                // 发布者传输连接成功
                publisherTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                // 发布者传输断开
                publisherTransportConnectedCompleter.reset()
            }
        }

        // 已连接状态下的断线重连逻辑
        if _state.connectionState == .connected {
            // 如果主传输或已发布内容的发布者传输断开，则尝试重连
            if transport.isPrimary || (_state.hasPublished && transport.target == .publisher), pcState.isDisconnected {
                Task {
                    do {
                        // 启动重连过程
                        try await startReconnect(reason: .transport)
                    } catch {
                        log("Failed calling startReconnect, error: \(error)", .error)
                    }
                }
            }
        }
    }

    // 处理ICE候选生成事件
    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: IceCandidate) {
        Task {
            do {
                log("sending iceCandidate")
                // 将ICE候选发送到服务器，指定目标传输通道
                try await signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
            } catch {
                log("Failed to send iceCandidate, error: \(error)", .error)
            }
        }
    }

    // 处理远程轨道添加事件（从订阅者传输接收新轨道）
    func transport(_ transport: Transport, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard !streams.isEmpty else {
            log("Received onTrack with no streams!", .warning)
            return
        }

        // 只处理订阅者传输通道的轨道添加
        if transport.target == .subscriber {
            // 当房间连接状态为已连接时执行轨道添加，避免连接过程中的错误处理
            execute(when: { state, _ in state.connectionState == .connected },
                    // 在断开连接时移除此回调
                    removeWhen: { state, _ in state.connectionState == .disconnected })
            { [weak self] in
                guard let self else { return }
                Task {
                    // 通知引擎处理新添加的轨道
                    await self.engine(self, didAddTrack: track, rtpReceiver: rtpReceiver, stream: streams.first!)
                }
            }
        }
    }

    // 处理远程轨道移除事件
    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack) {
        // 只处理订阅者传输通道的轨道移除
        if transport.target == .subscriber {
            Task {
                // 通知引擎处理轨道移除
                await engine(self, didRemoveTrack: track)
            }
        }
    }

    // 处理服务器打开的数据通道事件
    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel) {
        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        // 当订阅者是主传输且当前处理的是订阅者传输通道时
        if _state.isSubscriberPrimary, transport.target == .subscriber {
            // 根据通道标签设置相应的数据通道
            switch dataChannel.label {
            case LKRTCDataChannel.labels.reliable: subscriberDataChannel.set(reliable: dataChannel)
            case LKRTCDataChannel.labels.lossy: subscriberDataChannel.set(lossy: dataChannel)
            default: log("Unknown data channel label \(dataChannel.label)", .warning)
            }
        }
    }

    // 传输层请求协商（此实现为空，由Room主动控制协商）
    func transportShouldNegotiate(_: Transport) {}
}
