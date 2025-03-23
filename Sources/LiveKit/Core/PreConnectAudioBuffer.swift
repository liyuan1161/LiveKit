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

import AVFAudio
import Foundation

/// 连接服务器前捕获音频的缓冲区，
/// 并在特定的 ``RoomDelegate`` 事件发生时发送音频数据。
@objc
public final class PreConnectAudioBuffer: NSObject, Loggable {
    /// 用于指示音频缓冲区活跃的默认参与者属性键。
    @objc
    public static let attributeKey = "lk.agent.pre-connect-audio"

    /// 用于发送音频缓冲区的默认数据主题。
    @objc
    public static let dataTopic = "lk.agent.pre-connect-audio-buffer"

    /// 监听事件的Room实例。
    @objc
    public let room: Room?

    /// 音频录制器实例。
    @objc
    public let recorder: LocalAudioTrackRecorder

    // 内部状态管理
    private let state = StateSync<State>(State())
    private struct State {
        var audioStream: LocalAudioTrackRecorder.Stream?
    }

    /// 使用Room实例初始化音频缓冲区。
    /// - 参数:
    ///   - room: 监听事件的Room实例。
    ///   - recorder: 用于捕获的音频录制器。
    @objc
    public init(room: Room?,
                recorder: LocalAudioTrackRecorder = LocalAudioTrackRecorder(
                    track: LocalAudioTrack.createTrack(),
                    format: .pcmFormatInt16, // 代理插件支持的格式
                    sampleRate: 24000,       // 代理插件支持的采样率
                    maxSize: 10 * 1024 * 1024 // 10MB的任意最大录制大小
                ))
    {
        self.room = room
        self.recorder = recorder
        super.init()
    }

    // 清理资源
    deinit {
        stopRecording()
        room?.remove(delegate: self)
    }

    /// 开始捕获音频并监听 ``RoomDelegate`` 事件。
    @objc
    public func startRecording() async throws {
        // 将自身添加为Room的委托
        room?.add(delegate: self)

        // 启动录制器并获取音频流
        let stream = try await recorder.start()
        log("Started capturing audio", .info)
        state.mutate { state in
            state.audioStream = stream
        }
    }

    /// 停止捕获音频。
    /// - 参数:
    ///   - flush: 若为`true`，将立即刷新音频流而不发送。
    @objc
    public func stopRecording(flush: Bool = false) {
        recorder.stop()
        log("Stopped capturing audio", .info)
        if flush, let stream = state.audioStream {
            // 如果需要刷新，消费流中的所有数据但不处理
            Task {
                for await _ in stream {}
            }
        }
    }
}

// MARK: - RoomDelegate 实现

extension PreConnectAudioBuffer: RoomDelegate {
    // 房间连接成功时设置参与者属性
    public func roomDidConnect(_ room: Room) {
        Task {
            try? await setParticipantAttribute(room: room)
        }
    }

    // 当远程参与者订阅本地轨道时发送音频数据
    public func room(_ room: Room, participant _: LocalParticipant, remoteDidSubscribeTrack _: LocalTrackPublication) {
        stopRecording()
        Task {
            try? await sendAudioData(to: room)
        }
    }

    /// 设置参与者属性以指示音频缓冲区处于活跃状态。
    /// - 参数:
    ///   - key: 设置属性的键。
    ///   - room: 设置属性的Room实例。
    @objc
    public func setParticipantAttribute(key _: String = attributeKey, room: Room) async throws {
        // 获取当前属性并添加标记
        var attributes = room.localParticipant.attributes
        attributes[Self.attributeKey] = "true"
        try await room.localParticipant.set(attributes: attributes)
        log("Set participant attribute", .info)
    }

    /// 将音频数据发送到房间。
    /// - 参数:
    ///   - room: 接收音频数据的Room实例。
    ///   - topic: 发送音频数据的主题。
    @objc
    public func sendAudioData(to room: Room, on topic: String = dataTopic) async throws {
        // 确保音频流存在
        guard let audioStream = state.audioStream else {
            throw LiveKitError(.invalidState, message: "Audio stream is nil")
        }

        // 创建字节流选项，附加音频元数据
        let streamOptions = StreamByteOptions(
            topic: topic,
            attributes: [
                "sampleRate": "\(recorder.sampleRate)",
                "channels": "\(recorder.channels)",
            ]
        )
        
        // 获取字节流写入器，写入收集的音频数据
        let writer = try await room.localParticipant.streamBytes(options: streamOptions)
        try await writer.write(audioStream.collect())
        try await writer.close()
        log("Sent audio data", .info)

        // 发送完成后移除自身作为委托
        room.remove(delegate: self)
    }
}
