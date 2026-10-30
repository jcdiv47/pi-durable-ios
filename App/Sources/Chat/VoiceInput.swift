import AVFoundation
import Foundation
import Observation
import PiRuntime

/// Voice input for the composer: records from the microphone, then OpenAI's transcription API turns the recording into
/// text for the conversation's draft, to edit before sending. It uses the OpenAI provider key from the Keychain, sent from Swift
/// straight to api.openai.com, so like every key it never reaches JS. One per conversation view; nothing is kept.
@MainActor
@Observable
final class VoiceInput {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var phase = Phase.idle
    /// Recent input levels, 0...1, oldest first, for the waveform.
    private(set) var levels: [Float] = Array(repeating: 0, count: VoiceInput.levelCount)
    private(set) var startedAt: Date?
    /// The last failure, for the composer's alert.
    var error: String?

    static let provider = "openai"
    nonisolated static let model = "gpt-4o-transcribe"
    /// Well under the API's 25 MB upload limit at this recording's bit rate.
    nonisolated static let maxDuration: TimeInterval = 600
    static let levelCount = 24

    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private var key: String?
    private var diagnostics: DiagnosticsLog?
    private var onText: ((String) -> Void)?
    /// Between a tap on the mic and recording: permission and the audio session.
    private var starting = false
    /// Activating and deactivating the audio session can block (starting a recorder activates it too), so it happens
    /// here, in order, off the main thread.
    private nonisolated static let sessionQueue = DispatchQueue(label: "dev.pi.durable.voice-session")

    /// Asks for the microphone on first use, then records until `finish()` or `cancel()`, the time limit, or an
    /// interruption such as a call, which also finish. The transcript goes to `onText`.
    func start(diagnostics: DiagnosticsLog, onText: @escaping (String) -> Void) async {
        guard phase == .idle, !starting else { return }
        starting = true
        defer { starting = false }
        self.diagnostics = diagnostics
        guard let key = KeychainKeys().apiKey(for: Self.provider), !key.isEmpty else {
            fail(VoiceInputError("Voice input uses OpenAI's transcription. Add an OpenAI key in Settings › Providers."))
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            fail(VoiceInputError("Pi can't use the microphone. Allow it in the Settings app › Apps › Pi."))
            return
        }
        do {
            let recorder = try await Self.startRecorder()
            self.recorder = recorder
            self.key = key
            self.onText = onText
            levels = Array(repeating: 0, count: Self.levelCount)
            startedAt = .now
            phase = .recording
            meter = Task { [weak self] in await self?.watch(recorder) }
        } catch {
            fail(error)
            stopRecording()
        }
    }

    /// Stops recording and transcribes it. A tap shorter than half a second is dropped.
    func finish() {
        guard phase == .recording, let recorder, let key else { return }
        let duration = recorder.currentTime > 0 ? recorder.currentTime : Date.now.timeIntervalSince(startedAt ?? .now)
        let url = recorder.url
        stopRecording()
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            reset()
            return
        }
        phase = .transcribing
        Task {
            defer {
                try? FileManager.default.removeItem(at: url)
                reset()
            }
            do {
                let text = try await Self.transcribe(url, key: key).trimmingCharacters(in: .whitespacesAndNewlines)
                diagnostics?.record("info", "voice", "Transcribed \(Int(duration.rounded())) s of audio into \(text.count) characters")
                if !text.isEmpty { onText?(text) }
            } catch {
                fail(error)
            }
        }
    }

    /// Stops recording and throws it away.
    func cancel() {
        guard phase == .recording, let url = recorder?.url else { return }
        stopRecording()
        try? FileManager.default.removeItem(at: url)
        reset()
    }

    private func watch(_ recorder: AVAudioRecorder) async {
        while !Task.isCancelled, phase == .recording {
            // Stopped by the time limit or an interruption: send what was recorded.
            guard recorder.isRecording else { finish(); return }
            recorder.updateMeters()
            // -50 dB and below is silence; 0 dB is the loudest.
            let level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
            levels = Array(levels.dropFirst()) + [level]
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    private func stopRecording() {
        meter?.cancel()
        meter = nil
        recorder?.stop()
        recorder = nil
        Self.sessionQueue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func reset() {
        phase = .idle
        startedAt = nil
        key = nil
        onText = nil
    }

    private func fail(_ error: Error) {
        let message = (error as? VoiceInputError)?.message ?? error.localizedDescription
        self.error = message
        diagnostics?.record("warn", "voice", message)
    }

    /// Activates the session and starts a recorder on `sessionQueue`; from then on the main actor owns the recorder.
    private nonisolated static func startRecorder() async throws -> AVAudioRecorder {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StartedRecorder, Error>) in
            sessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .default)
                    try session.setActive(true)
                    let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
                    let recorder = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 32_000,
                    ])
                    recorder.isMeteringEnabled = true
                    guard recorder.record(forDuration: maxDuration) else { throw VoiceInputError("The microphone didn't start recording.") }
                    continuation.resume(returning: StartedRecorder(recorder: recorder))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }.recorder
    }

    /// Hands the recorder from `sessionQueue` to the main actor; nothing on the queue touches it afterwards.
    private struct StartedRecorder: @unchecked Sendable {
        let recorder: AVAudioRecorder
    }

    /// `POST /v1/audio/transcriptions`, multipart: the model and the recording. The language is detected.
    nonisolated static func transcribe(_ file: URL, key: String) async throws -> String {
        let boundary = "pi-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func part(_ headers: String, _ content: Data) {
            body.append(Data("--\(boundary)\r\n\(headers)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part("Content-Disposition: form-data; name=\"model\"", Data(model.utf8))
        part("Content-Disposition: form-data; name=\"response_format\"", Data("json".utf8))
        part("Content-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4", try Data(contentsOf: file))
        body.append(Data("--\(boundary)--\r\n".utf8))

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
            throw VoiceInputError("Transcription failed (HTTP \(status))\(message.map { ": \($0)" } ?? ".")")
        }
        return try JSONDecoder().decode(Transcript.self, from: data).text
    }

    private struct Transcript: Decodable { let text: String }
    private struct APIError: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }
}

struct VoiceInputError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
