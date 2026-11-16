import AVFoundation
import Foundation
import Observation
import PiRuntime

/// Settings › Talk to Pi › Voice's sample: a short line in a Realtime voice, so the user hears it before choosing.
/// OpenAI's speech endpoint (`gpt-4o-mini-tts`, which has the Realtime voices) says it once per voice, with the
/// `openai` provider key sent from Swift as `VoiceInput` does; the audio is kept in Caches, so a second listen is free.
@MainActor
@Observable
final class VoicePreview {
    static let shared = VoicePreview()

    nonisolated static let model = "gpt-4o-mini-tts"
    nonisolated static let sample = "Hi, I'm Pi. Ask me anything, and I'll get it done while we talk."

    enum State: Equatable {
        case idle
        case loading(String)
        case playing(String)
    }

    private(set) var state: State = .idle
    private(set) var error: String?

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    /// Whether a sample can play now: a voice session holds the microphone and speaker.
    var available: Bool {
        RealtimeVoice.shared.liveSession == nil && RealtimeVoice.shared.recordingSession == nil
    }

    /// Plays `voice`'s sample, or stops if it is the one loading or playing.
    func toggle(_ voice: String) {
        if state == .loading(voice) || state == .playing(voice) { return stop() }
        stop()
        error = nil
        guard available else { return }
        state = .loading(voice)
        task = Task { [weak self] in
            do {
                let file = try await Self.sampleFile(voice)
                guard let self, !Task.isCancelled else { return }
                try self.play(file, voice: voice)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                ChatStore.shared.diagnostics.record("warn", "voice", "Voice sample failed: \(error.localizedDescription)")
                self.stop()
            }
        }
    }

    private func play(_ file: URL, voice: String) throws {
        VoicePlayback.shared.stop()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let player = try AVAudioPlayer(contentsOf: file)
        self.player = player
        guard player.play() else { throw PreviewError.message("The sample could not play.") }
        state = .playing(voice)
        let length = player.duration
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 0.1))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let held = player != nil
        player?.stop()
        player = nil
        state = .idle
        if held, available {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - The sample's audio

    enum PreviewError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): text }
        }
    }

    nonisolated static var directory: URL {
        let url = URL.cachesDirectory.appending(path: "voice-samples", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The cached sample for `voice`, fetched first if there is none.
    nonisolated static func sampleFile(_ voice: String) async throws -> URL {
        let file = directory.appending(path: "\(voice).mp3")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let key = KeychainKeys().apiKey(for: "openai"), !key.isEmpty else {
            throw PreviewError.message("Add an OpenAI key in Settings to hear the voices.")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "voice": voice,
            "input": sample,
            "response_format": "mp3",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw PreviewError.message(message ?? "OpenAI answered \(status).")
        }
        try data.write(to: file, options: .atomic)
        return file
    }
}
