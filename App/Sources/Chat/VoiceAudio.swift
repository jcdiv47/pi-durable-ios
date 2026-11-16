import AVFoundation
import Foundation
import os

/// The voice session's audio (`RealtimeVoice`): the microphone, through the system's echo cancellation so Pi does not
/// hear itself, as 24 kHz mono PCM16 for the Realtime API, and the model's PCM16 played back. The microphone stays
/// open while Pi speaks, so the user can interrupt; `interrupt()` stops playback and says how much of the answer was
/// heard, for `conversation.item.truncate`.
///
/// Built and started on `queue`, as activating the audio session can block. The tap runs on the audio thread and
/// hands each chunk to `onInput`; playback reports to `onPlaybackIdle` when everything scheduled has played.
final class VoiceAudio: @unchecked Sendable {
    static let sampleRate = 24_000.0

    /// PCM16 chunks of about 100 ms, and the chunk's level, 0...1.
    var onInput: (@Sendable (Data, Float) -> Void)?
    var onPlaybackIdle: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let playback = OSAllocatedUnfairLock(initialState: Playback())
    private var configurationChanges: NSObjectProtocol?

    /// What has been scheduled and played of the answer being spoken, in frames.
    private struct Playback {
        var item: String?
        var scheduled = 0
        var played = 0
        /// Bumped by `interrupt()`, so the completions of buffers it threw away count for nothing.
        var generation = 0
    }

    let queue = DispatchQueue(label: "dev.pi.durable.voice-audio")

    /// Activates the audio session for a call (speaker, Bluetooth, echo cancellation) and starts the engine. On `queue`.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // A call's mode and echo cancellation, so Pi does not hear itself and stop. Not on the simulator: there the
        // voice-chat I/O deadlocks while initializing, and CoreAudio aborts the app (Xcode 27 beta).
        #if targetEnvironment(simulator)
        let mode = AVAudioSession.Mode.default
        #else
        let mode = AVAudioSession.Mode.voiceChat
        #endif
        try session.setCategory(.playAndRecord, mode: mode, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        #if !targetEnvironment(simulator)
        try? input.setVoiceProcessingEnabled(true)
        #endif
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw VoiceAudioError("Pi found no microphone.") }
        guard let converter = AVAudioConverter(from: inputFormat, to: wireFormat) else { throw VoiceAudioError("Pi can't convert the microphone's audio.") }
        converter.downmix = true
        self.converter = converter

        let chunk = AVAudioFrameCount(inputFormat.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: chunk, format: inputFormat) { [weak self] buffer, _ in
            self?.captured(buffer)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        try engine.start()
        player.play()
        // A route change (AirPods connecting, the speaker taking over) stops the engine; start it again on the new route.
        configurationChanges = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restart() }
        }
    }

    private func restart() {
        guard configurationChanges != nil, !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
        player.play()
    }

    /// Stops everything and gives the audio session back. On `queue`.
    func stop() {
        if let configurationChanges { NotificationCenter.default.removeObserver(configurationChanges) }
        configurationChanges = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        playback.withLock { $0 = Playback(generation: $0.generation + 1) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Plays a chunk of the answer `item`; a new item starts counting again.
    func play(_ base64: String, item: String) {
        guard let data = Data(base64Encoded: base64), data.count >= 2 else { return }
        let frames = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)), let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { out[index] = Float(Int16(littleEndian: samples[index])) / 32768 }
        }
        let generation = playback.withLock { state in
            if state.item != item { state = Playback(item: item, generation: state.generation) }
            state.scheduled += frames
            return state.generation
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            let idle = playback.withLock { state -> Bool in
                guard state.generation == generation else { return false }
                state.played += frames
                return state.played >= state.scheduled
            }
            if idle { onPlaybackIdle?() }
        }
        if !player.isPlaying { player.play() }
    }

    var isPlaying: Bool { playback.withLock { $0.played < $0.scheduled } }

    /// Stops playback (the user spoke) and returns the answer that was cut off and how many milliseconds of it were
    /// heard; nil when nothing was playing.
    func interrupt() -> (item: String, playedMs: Int)? {
        let cut = playback.withLock { state -> (item: String, playedMs: Int)? in
            defer { state = Playback(generation: state.generation + 1) }
            guard let item = state.item, state.played < state.scheduled else { return nil }
            return (item, Int(Double(state.played) / Self.sampleRate * 1000))
        }
        player.stop()
        player.play()
        return cut
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let onInput else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let count = Int(out.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = Float(samples[index]) / 32768
            sum += sample * sample
        }
        // -50 dB and below is silence, 0 dB the loudest, as the composer's mic draws it.
        let decibels = 10 * log10(max(sum / Float(count), 1e-10))
        let level = max(0, min(1, (decibels + 50) / 50))
        onInput(Data(bytes: samples, count: count * 2), level)
    }
}

struct VoiceAudioError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
