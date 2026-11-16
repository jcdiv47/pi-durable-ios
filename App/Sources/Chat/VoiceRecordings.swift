import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Talk to Pi's recordings, in Application Support `voice/`: two AAC tracks per voice session, the microphone's
/// (`<session>.mic.m4a`) and Pi's voice as OpenAI sent it (`<session>.pi.m4a`), so neither voice is in them twice. Kept
/// on this iPhone only (not in backups). The conversation's spoken lines point into their role's track by offset
/// (`DisplayVoice`); a recording no conversation shows any more is deleted by `sweep`, as attachment images are.
/// (The first build kept one mixed `<session>.m4a`; its lines point into that, and it still plays.)
enum VoiceRecordings {
    enum Track: String {
        case mic, pi
    }

    /// Settings › Talk to Pi › Keep Recordings; on unless the user turned it off.
    static let keepKey = "voiceKeepRecordings"

    static var keep: Bool {
        get { UserDefaults.standard.object(forKey: keepKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepKey) }
    }

    static var directory: URL {
        var url = URL.applicationSupportDirectory.appending(path: "voice", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    static func url(_ session: String, _ track: Track) -> URL {
        directory.appending(path: "\(session).\(track.rawValue).m4a")
    }

    /// The file a line of `role` (`user`, `pi`) plays from, if there is one.
    static func file(_ session: String, role: String?) -> URL? {
        let track = url(session, role == "user" ? .mic : .pi)
        if FileManager.default.fileExists(atPath: track.path) { return track }
        let mixed = directory.appending(path: "\(session).m4a")
        return FileManager.default.fileExists(atPath: mixed.path) ? mixed : nil
    }

    private static func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "m4a" }
    }

    /// The session a file belongs to: its name up to the first dot.
    private static func session(of file: URL) -> String {
        String(file.lastPathComponent.prefix { $0 != "." })
    }

    /// The sessions with a recording, and their total size in bytes.
    static func usage() -> (count: Int, bytes: Int64) {
        let files = files()
        let bytes = files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }.reduce(0, +)
        return (Set(files.map(session(of:))).count, bytes)
    }

    static func delete(_ session: String) {
        for file in files() where self.session(of: file) == session { try? FileManager.default.removeItem(at: file) }
    }

    /// Deletes the recordings of sessions not in `keeping`, except `live` (being recorded). Returns how many went.
    @discardableResult
    static func sweep(keeping: Set<String>, live: String?) -> Int {
        var removed: Set<String> = []
        for file in files() {
            let session = session(of: file)
            guard !keeping.contains(session), session != live else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed.insert(session) }
        }
        return removed.count
    }

    /// Settings › Talk to Pi › Delete All Recordings. The transcripts stay.
    static func deleteAll(except live: String?) {
        sweep(keeping: [], live: live)
    }
}

/// Plays voice recordings in the transcript: one line (what the user said, what the voice said) from its bubble, or
/// from a session's header all its lines one after another, with a short pause between, as the conversation went
/// without the waits. One thing at a time; nothing of a session still being recorded. A back swipe stops it.
@MainActor
@Observable
final class VoicePlayback {
    static let shared = VoicePlayback()

    /// A line's place: the session, and the line's role and start (nil for the whole session).
    struct Key: Hashable {
        let session: String
        var line: String?

        init(session: String, line: DisplayVoice? = nil) {
            self.session = session
            self.line = line.map { "\($0.role ?? "")-\($0.startMs ?? -1)" }
        }
    }

    /// What is playing now.
    private(set) var playing: Key?

    private var players: [URL: AVAudioPlayer] = [:]
    private var task: Task<Void, Never>?

    func isPlaying(_ key: Key) -> Bool { playing == key }

    /// Whether a line can play: it has a place in a recording that exists and is complete.
    static func playable(_ line: DisplayVoice) -> Bool {
        line.startMs != nil && line.endMs != nil && RealtimeVoice.shared.recordingSession != line.session
            && VoiceRecordings.file(line.session, role: line.role) != nil
    }

    /// Plays `lines` in order (one, or a whole session's), or stops if `key` is what plays.
    func toggle(_ key: Key, lines: [DisplayVoice]) {
        if playing == key { return stop() }
        stop()
        let clips = lines.filter(Self.playable).compactMap { line -> (URL, TimeInterval, TimeInterval)? in
            guard let file = VoiceRecordings.file(line.session, role: line.role), let start = line.startMs, let end = line.endMs, end > start else { return nil }
            return (file, Double(start) / 1000, Double(end) / 1000)
        }
        guard !clips.isEmpty else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            ChatStore.shared.diagnostics.record("warn", "voice", "Playing a recording failed: \(error.localizedDescription)")
            return
        }
        playing = key
        task = Task { [weak self] in
            for (index, (file, start, end)) in clips.enumerated() {
                guard let self, !Task.isCancelled else { return }
                if index > 0 { try? await Task.sleep(for: .milliseconds(350)) }
                guard !Task.isCancelled, let player = player(file) else { continue }
                // A little either side: transcription's speech marks can be tight.
                player.currentTime = max(0, start - 0.1)
                guard player.play() else { continue }
                let length = min(end + 0.2, player.duration) - player.currentTime
                try? await Task.sleep(for: .seconds(max(0.1, length)))
                player.pause()
            }
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func player(_ file: URL) -> AVAudioPlayer? {
        if let player = players[file] { return player }
        guard let player = try? AVAudioPlayer(contentsOf: file) else { return nil }
        player.prepareToPlay()
        players[file] = player
        return player
    }

    func stop() {
        task?.cancel()
        task = nil
        guard playing != nil || !players.isEmpty else { return }
        for player in players.values { player.stop() }
        players = [:]
        playing = nil
        // A voice session may be starting: only give the audio session back when nothing else holds it.
        if RealtimeVoice.shared.recordingSession == nil, RealtimeVoice.shared.liveSession == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Stops playing: the recordings are being deleted.
    func forgetAll() {
        stop()
    }
}

/// Settings › Talk to Pi: the model and Pi's voice, whether sessions are recorded, and the recordings kept.
struct VoiceSettingsView: View {
    @State private var model = RealtimeVoice.model
    @State private var voice = RealtimeVoice.voice
    @State private var keep = VoiceRecordings.keep
    @State private var usage = VoiceRecordings.usage()
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $model) {
                    ForEach(RealtimeVoice.models, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .accessibilityIdentifier("voice.model")
            } footer: {
                Text("\(RealtimeVoice.models.first { $0.id == model }?.detail ?? "") A session already talking keeps its model.")
            }
            Section {
                ForEach(RealtimeVoice.voices, id: \.self) { name in
                    VoiceChoiceRow(name: name, selected: voice == name) { voice = name }
                }
            } header: {
                Text("Voice")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = preview.error {
                        Text(error).foregroundStyle(.red)
                    }
                    Text("The voice Pi speaks with, from OpenAI's Realtime API. A session already talking keeps its voice; the next one uses this. Samples use your OpenAI key once per voice.")
                }
            }
            Section {
                Toggle("Keep Recordings", isOn: $keep)
                    .accessibilityIdentifier("voice.keep")
            } footer: {
                Text("What you and Pi said is kept in the conversation either way. With this on, the audio is kept too, so you can play it back. Recordings stay on this iPhone, are not backed up, and go when their conversation is deleted.")
            }
            Section {
                LabeledContent("Recordings", value: usage.count == 0 ? "None" : "\(usage.count)")
                LabeledContent("Space Used", value: usage.bytes.formatted(.byteCount(style: .file)))
                Button("Delete All Recordings", role: .destructive) { confirmingDelete = true }
                    .disabled(usage.count == 0)
                    .confirmationDialog("Delete all recordings?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete All Recordings", role: .destructive) {
                            VoicePlayback.shared.forgetAll()
                            VoiceRecordings.deleteAll(except: RealtimeVoice.shared.recordingSession)
                            usage = VoiceRecordings.usage()
                        }
                    } message: {
                        Text("The transcripts stay in their conversations.")
                    }
            }
        }
        .navigationTitle("Talk to Pi")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: keep) { VoiceRecordings.keep = keep }
        .onChange(of: voice) { RealtimeVoice.voice = voice }
        .onChange(of: model) { RealtimeVoice.model = model }
        .onDisappear { preview.stop() }
    }

    private var preview: VoicePreview { .shared }
}

/// A voice in Settings › Talk to Pi: tap to choose it, or its button to hear a sample (`VoicePreview`).
private struct VoiceChoiceRow: View {
    let name: String
    let selected: Bool
    let choose: () -> Void

    private var preview: VoicePreview { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: choose) {
                HStack {
                    Text(name.capitalized).foregroundStyle(.primary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("voice.voice.\(name)")

            Button { preview.toggle(name) } label: {
                Group {
                    switch preview.state {
                    case .loading(name): ProgressView()
                    case .playing(name): Image(systemName: "stop.circle.fill")
                    default: Image(systemName: "play.circle")
                    }
                }
                .font(.title2)
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .disabled(!preview.available)
            .accessibilityLabel(preview.state == .playing(name) ? "Stop \(name.capitalized) sample" : "Play \(name.capitalized) sample")
            .accessibilityIdentifier("voice.sample.\(name)")
        }
    }
}
