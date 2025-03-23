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

private extension Array where Element: LKRTCVideoCodecInfo {
    func rewriteCodecsIfNeeded() -> [LKRTCVideoCodecInfo] {
        // 将H264的profileLevelId重写为42e032（基线配置5级）
        let codecs = map { $0.name == kRTCVideoCodecH264Name ? RTC.h264BaselineLevel5CodecInfo : $0 }
        // 日志记录已被注释掉
        return codecs
    }
}

private class VideoEncoderFactory: LKRTCDefaultVideoEncoderFactory {
    override func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoDecoderFactory: LKRTCDefaultVideoDecoderFactory {
    override func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoEncoderFactorySimulcast: LKRTCVideoEncoderFactorySimulcast {
    override func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

class RTC {
    // H264基线配置5级编解码器信息，用于高质量视频传输
    static let h264BaselineLevel5CodecInfo: LKRTCVideoCodecInfo = {
        // 创建H264配置文件级别ID
        guard let profileLevelId = LKRTCH264ProfileLevelId(profile: .constrainedBaseline, level: .level5) else {
            logger.log("failed to generate profileLevelId", .error, type: Room.self)
            fatalError("failed to generate profileLevelId")
        }

        // 创建具有特定参数的H264编解码器
        return LKRTCVideoCodecInfo(name: kRTCH264CodecName,
                                   parameters: ["profile-level-id": profileLevelId.hexString,
                                                "level-asymmetry-allowed": "1",
                                                "packetization-mode": "1"])
    }()

    // global properties are already lazy

    // 视频编码器工厂
    private static let encoderFactory: LKRTCVideoEncoderFactory = {
        let encoderFactory = VideoEncoderFactory()
        return VideoEncoderFactorySimulcast(primary: encoderFactory,
                                            fallback: encoderFactory)
    }()

    // 视频解码器工厂
    private static let decoderFactory = VideoDecoderFactory()

    // 音频处理模块
    static let audioProcessingModule: LKRTCDefaultAudioProcessingModule = .init()

    // 视频发送能力
    static let videoSenderCapabilities = peerConnectionFactory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
    // 音频发送能力
    static let audioSenderCapabilities = peerConnectionFactory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)

    // 对等连接工厂，用于创建WebRTC连接
    static let peerConnectionFactory: LKRTCPeerConnectionFactory = {
        logger.log("Initializing SSL...", type: Room.self)

        RTCInitializeSSL()

        logger.log("Initializing PeerConnectionFactory...", type: Room.self)

        return LKRTCPeerConnectionFactory(bypassVoiceProcessing: false,
                                          encoderFactory: encoderFactory,
                                          decoderFactory: decoderFactory,
                                          audioProcessingModule: audioProcessingModule)
    }()

    // 禁止直接访问，通过属性访问音频设备模块

    // 音频设备模块
    static var audioDeviceModule: LKRTCAudioDeviceModule {
        peerConnectionFactory.audioDeviceModule
    }

    // 创建对等连接
    static func createPeerConnection(_ configuration: LKRTCConfiguration,
                                     constraints: LKRTCMediaConstraints) -> LKRTCPeerConnection?
    {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.peerConnection(with: configuration,
                                                                                constraints: constraints,
                                                                                delegate: nil) }
    }

    // 创建视频源，支持屏幕共享选项
    static func createVideoSource(forScreenShare: Bool) -> LKRTCVideoSource {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.videoSource(forScreenCast: forScreenShare) }
    }

    // 从视频源创建视频轨道
    static func createVideoTrack(source: LKRTCVideoSource) -> LKRTCVideoTrack {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.videoTrack(with: source,
                                                                            trackId: UUID().uuidString) }
    }

    // 创建音频源
    static func createAudioSource(_ constraints: LKRTCMediaConstraints?) -> LKRTCAudioSource {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.audioSource(with: constraints) }
    }

    // 从音频源创建音频轨道
    static func createAudioTrack(source: LKRTCAudioSource) -> LKRTCAudioTrack {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.audioTrack(with: source,
                                                                            trackId: UUID().uuidString) }
    }

    // 创建数据通道配置
    static func createDataChannelConfiguration(ordered: Bool = true,
                                               maxRetransmits: Int32 = -1) -> LKRTCDataChannelConfiguration
    {
        let result = DispatchQueue.liveKitWebRTC.sync { LKRTCDataChannelConfiguration() }
        result.isOrdered = ordered
        result.maxRetransmits = maxRetransmits
        return result
    }

    // 创建数据缓冲区
    static func createDataBuffer(data: Data) -> LKRTCDataBuffer {
        DispatchQueue.liveKitWebRTC.sync { LKRTCDataBuffer(data: data, isBinary: true) }
    }

    // 从JSON字符串创建ICE候选
    static func createIceCandidate(fromJsonString: String) throws -> LKRTCIceCandidate {
        try DispatchQueue.liveKitWebRTC.sync { try LKRTCIceCandidate(fromJsonString: fromJsonString) }
    }

    // 创建会话描述
    static func createSessionDescription(type: RTCSdpType, sdp: String) -> LKRTCSessionDescription {
        DispatchQueue.liveKitWebRTC.sync { LKRTCSessionDescription(type: type, sdp: sdp) }
    }

    // 创建视频捕获器
    static func createVideoCapturer() -> LKRTCVideoCapturer {
        DispatchQueue.liveKitWebRTC.sync { LKRTCVideoCapturer() }
    }

    // 创建RTP编码参数
    static func createRtpEncodingParameters(rid: String? = nil,
                                            encoding: MediaEncoding? = nil,
                                            scaleDownBy: Double? = nil,
                                            active: Bool = true,
                                            scalabilityMode: ScalabilityMode? = nil) -> LKRTCRtpEncodingParameters
    {
        let result = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpEncodingParameters() }

        result.isActive = active
        result.rid = rid

        if let scaleDownBy {
            result.scaleResolutionDownBy = NSNumber(value: scaleDownBy)
        }

        if let encoding {
            result.maxBitrateBps = NSNumber(value: encoding.maxBitrate)

            // 视频编码特定配置
            if let videoEncoding = encoding as? VideoEncoding {
                result.maxFramerate = NSNumber(value: videoEncoding.maxFps)
            }
        }

        if let scalabilityMode {
            result.scalabilityMode = scalabilityMode.rawStringValue
        }

        return result
    }
}
