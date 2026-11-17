import ActivityKit
import AVFoundation
import Foundation
import Observation
import os
import PiRuntime
import PiUI
import UIKit

/// A spoken conversation with Pi: OpenAI's Realtime API listens and talks, and Pi does the work. The voice model has
/// one tool, `ask_pi`, which sends the request into a Pi conversation through `ChatStore.askFromOutside`, so Pi's tools,
/// approvals and transcript work as they do in the chat; the voice model only hears the answer and says it.
///
/// Over a WebSocket from Swift with the OpenAI provider key, which never reaches JS. The session itself is not durable:
/// if the app dies it is gone, and a Pi turn it started finishes in its conversation (and notifies) as any other turn
/// does. What was said is: each line goes into the conversation as it is said (`voiceLine`, display-only), and the
/// session is recorded to a file the lines point into (`VoiceRecordings`, unless the user turned that off). One at a time (`shared`), started from the voice screen or `TalkToPiIntent` (the Action button,
/// Control Center), which may run with the app in the background: the session shows as a Live Activity
/// (`PiVoiceAttributes`), and iOS lets it record only while that shows. Leaving the voice screen does not end it.
@MainActor
@Observable
final class RealtimeVoice {
    static let shared = RealtimeVoice()

    /// The Realtime API's speech-to-speech models with tools (translation and transcription models can't hold a
    /// conversation), with what Settings › Talk to Pi says of each.
    static let models: [(id: String, name: String, detail: String)] = [
        ("gpt-realtime-2.1", "GPT Realtime 2.1", "The newest. Best at hearing and calling Pi."),
        ("gpt-realtime-2.1-mini", "GPT Realtime 2.1 mini", "Faster, about a third of the price; calls Pi less reliably."),
        ("gpt-realtime-2", "GPT Realtime 2", "The one before 2.1."),
    ]
    static let defaultModel = "gpt-realtime-2.1"
    /// Settings › Talk to Pi › Model. Like the voice, a session keeps the model it started with.
    static let modelKey = "voiceRealtimeModel"

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
            return models.contains { $0.id == stored } ? stored : defaultModel
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
    /// The Realtime API's built-in voices; `marin` and `cedar` are the newest and sound best.
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    static let defaultVoice = "marin"
    /// Settings › Talk to Pi › Voice. A session keeps the voice it started with (OpenAI cannot change it once the
    /// session has spoken); the next session takes the new one.
    static let voiceKey = "voiceRealtimeVoice"

    static var voice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: voiceKey) ?? defaultVoice
            return voices.contains(stored) ? stored : defaultVoice
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }
    static let provider = VoiceInput.provider
    /// Quiet this long (nobody speaking, nothing playing, Pi not working or waiting for approval) ends the session.
    static let idleLimit: Duration = .seconds(30)
    /// How long `ask_pi` waits for Pi's answer before telling the user it will come as a notification.
    static let answerWait = 120_000
    /// How long connecting may take before the session gives up.
    static let connectLimit: Duration = .seconds(15)

    enum Phase: Equatable {
        case off
        case connecting
        case live
        case ended
    }

    enum Mode: Equatable {
        case listening
        case hearing
        case working
        case speaking
    }

    struct Turn: Identifiable, Equatable {
        enum Role { case user, pi, note }
        let id: String
        let role: Role
        var text: String
        /// A Pi answer cut off by the user, or a request still with Pi.
        var pending = false
    }

    private(set) var phase = Phase.off
    private(set) var turns: [Turn] = []
    /// The microphone's level, 0...1.
    private(set) var level: Float = 0
    /// The Pi conversation the requests go to: created by the first `ask_pi`, kept by "Talk again".
    private(set) var conversationId: Int?
    /// Why the session ended, when it was not the user's doing.
    private(set) var endReason: String?
    /// The session whose recording is being written; nil once the file is complete.
    private(set) var recordingSession: String?

    private var hearing = false
    private var speaking = false
    private var asks = 0

    var activity: Mode {
        if speaking { return .speaking }
        if hearing { return .hearing }
        if asks > 0 || waitingForApproval { return .working }
        return .listening
    }

    /// The session going now.
    var liveSession: String? { phase == .connecting || phase == .live ? sessionId : nil }

    var waitingForApproval: Bool { approval != nil }

    /// The oldest approval this session's conversation waits for.
    var approval: ApprovalRequest? {
        guard let conversationId else { return nil }
        return store.approvals.first { $0.conversationId == conversationId }
    }

    private var store: ChatStore { .shared }
    private var socket: URLSessionWebSocketTask?
    private let outbox = AudioOutbox()
    private var liveActivity: Activity<PiVoiceAttributes>?
    private var shownActivity: PiVoiceAttributes.ContentState?
    private var queuedActivity: PiVoiceAttributes.ContentState?
    private var activityFlush: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var audio: VoiceAudio?
    private var log = SessionLog(session: "", conversationId: nil, recorded: false)
    private var interruptions: NSObjectProtocol?
    /// Bumped by every start and end: work from an earlier session finds it changed and does nothing.
    private var generation = 0
    private var sessionId = ""
    /// The model this session connected with: Settings may change while it talks.
    private var sessionModel = RealtimeVoice.defaultModel
    private var responseActive = false
    private var responseWanted = false

    // MARK: Starting and ending

    /// Connects and starts listening. `conversationId` continues a Pi conversation ("Talk again"); nil starts a new
    /// one with the first request. The microphone and the Live Activity start at once; what the user says before the
    /// connection is ready is held and sent then.
    func start(conversationId: Int? = nil) async {
        guard phase != .connecting, phase != .live else { return }
        generation += 1
        let generation = generation
        sessionId = UUID().uuidString
        self.conversationId = conversationId
        VoicePlayback.shared.stop()
        let recorded = VoiceRecordings.keep
        log = SessionLog(session: sessionId, conversationId: conversationId, recorded: recorded)
        recordingSession = recorded ? sessionId : nil
        turns = []
        endReason = nil
        hearing = false
        speaking = false
        asks = 0
        responseActive = false
        responseWanted = false
        phase = .connecting
        // Inactive is still on screen (a deep link's prompt, Control Center pulled down): prompts can show there.
        let background = UIApplication.shared.applicationState == .background

        guard let key = KeychainKeys().apiKey(for: Self.provider), !key.isEmpty else {
            return end("Talking to Pi uses OpenAI's Realtime API. Add an OpenAI key in Settings › Providers.")
        }
        // In the background iOS shows no permission prompt.
        if background, AVAudioApplication.shared.recordPermission == .undetermined {
            return end("Open Pi and allow the microphone once.")
        }
        // Before the microphone: an intent may record in the background only while the Live Activity shows.
        if !startActivity(), background {
            return end("Allow Live Activities for Pi in the Settings app, so it can listen with the app closed.")
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            return end("Pi can't use the microphone. Allow it in the Settings app › Apps › Pi.")
        }
        guard generation == self.generation else { return }
        VoicePreview.shared.stop()
        await startAudio(generation: generation, recording: recorded ? (VoiceRecordings.url(sessionId, .mic), VoiceRecordings.url(sessionId, .pi)) : nil)
        guard generation == self.generation else { return }

        sessionModel = Self.model
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(sessionModel)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        self.socket = socket
        outbox.attach(socket)
        socket.resume()
        send(sessionUpdate)
        receive(socket, generation: generation)
        interruptions = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            guard began else { return }
            MainActor.assumeIsolated { self?.end("Something else took the microphone, such as a call.") }
        }
        trackActivity(generation: generation)
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectLimit)
            guard let self, generation == self.generation, phase == .connecting else { return }
            end("OpenAI didn't answer. Check the connection and try again.")
        }
        store.diagnostics.record("info", "voice", "Voice session starting (\(Self.model), \(Self.voice))\(background ? " in the background" : "")")
    }

    /// `TalkToPiIntent`: starts a session, or ends the one going. Returns once the session is live, or throws why it
    /// could not start, for the Action button's or Siri's error.
    func toggle() async throws {
        if phase == .connecting || phase == .live { return await hangUp() }
        await start()
        while phase == .connecting { try? await Task.sleep(for: .milliseconds(100)) }
        if phase == .ended, let endReason { throw PiIntentError(endReason) }
    }

    /// End on the Live Activity, or a second press of the Action button. With the app away, waits for Pi's run to
    /// finish (up to 25 s), as the other buttons do, so iOS does not suspend the app mid-run.
    func hangUp() async {
        let wasRunning = phase == .connecting || phase == .live
        let log = log
        end()
        guard wasRunning, UIApplication.shared.applicationState != .active, store.phase == .ready else { return }
        // The last lines go into the conversation before iOS suspends the app.
        await log.chain?.value
        await store.background.waitForIdle(timeout: .seconds(25))
    }

    /// Hangs up. A request still with Pi carries on in its conversation.
    func end(_ reason: String? = nil) {
        guard phase == .connecting || phase == .live else { return }
        generation += 1
        receiver?.cancel()
        receiver = nil
        idle?.cancel()
        idle = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        outbox.close()
        // What was said and not written yet: Pi's words still playing (heard up to here), or not finished.
        audio?.cut()
        writeSpoken(all: true)
        let log = log
        if let audio {
            audio.onInput = nil
            audio.onPlaybackIdle = nil
            audio.queue.async { [weak self] in
                audio.stop()
                Task { @MainActor in self?.recordingClosed(log) }
            }
        } else {
            recordingClosed(log)
        }
        audio = nil
        if let interruptions { NotificationCenter.default.removeObserver(interruptions) }
        interruptions = nil
        hearing = false
        speaking = false
        level = 0
        for index in turns.indices where turns[index].pending { turns[index].pending = false }
        endReason = reason
        phase = .ended
        endActivity()
        store.diagnostics.record(reason == nil ? "info" : "warn", "voice", "Voice session ended\(reason.map { ": \($0)" } ?? "")")
    }

    // MARK: The session

    private var sessionUpdate: [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": Self.instructions,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(VoiceAudio.sampleRate)],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": ["model": VoiceInput.model, "prompt": Self.transcriptionPrompt],
                        "turn_detection": ["type": "semantic_vad", "create_response": true, "interrupt_response": true],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": Int(VoiceAudio.sampleRate)],
                        "voice": Self.voice,
                    ],
                ],
                "tools": [Self.askPiTool],
                "tool_choice": "auto",
            ] as [String: Any],
        ]
    }

    /// Biases the caption model (the transcript the user sees and the conversation keeps), not the voice model. No
    /// `language`: it takes one code, and fixing it would garble the other language.
    static let transcriptionPrompt = "The speaker uses Mandarin Chinese (Simplified) and English, sometimes mixed in one sentence."

    static let instructions = """
    You are the voice of Pi, the user's personal agent on their iPhone. You hear the user and speak Pi's answers; Pi does \
    the work. Pi can reach their home lab (machines over SSH), Home Assistant and other servers they connected, \
    their calendar, reminders, alarms, health data, photos and the web, and it remembers the earlier requests of this \
    conversation.

    For anything beyond small talk, call ask_pi with the user's request as a complete sentence in their words, adding \
    what Pi needs from earlier in this conversation. Never answer a question about their devices, home, schedule or the \
    world from your own knowledge. Before calling ask_pi, say two or three words, such as "Checking." or "On it."

    When ask_pi returns, say the answer in one or two short sentences, as someone would say it aloud: no lists, no \
    markdown, no IDs, paths or URLs unless asked, and round the numbers. Offer more only if there is clearly more that \
    matters. If Pi is still working, say the answer will come as a notification. If Pi failed, say so plainly.

    Pi asks the user before it changes anything that matters. The user approves on the screen. Never say that you \
    approved something, and never take a spoken yes as an approval: tell them to tap Allow or Deny.

    Speak in the user's language. Be brief; the user is often busy or on the move.
    """

    static let askPiTool: [String: Any] = [
        "type": "function",
        "name": "ask_pi",
        "description": "Sends a request to Pi, the user's agent, and returns its answer. Pi runs the user's tools: home lab "
            + "and servers, Home Assistant, calendar, reminders, alarms, health, photos, web search. Use it for every "
            + "request that needs facts or actions. It can take a while.",
        "parameters": [
            "type": "object",
            "properties": [
                "request": ["type": "string", "description": "What the user wants, as a complete request in their words."],
            ],
            "required": ["request"],
        ] as [String: Any],
    ]

    private func send(_ event: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    /// Asks the model to speak, or to speak once the response it is giving ends: one response at a time.
    private func requestResponse() {
        if responseActive {
            responseWanted = true
        } else {
            responseActive = true
            send(["type": "response.create"])
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask, generation: Int) {
        receiver = Task.detached { [weak self] in
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    let status = (socket.response as? HTTPURLResponse)?.statusCode
                    await self?.disconnected(error, status: status, generation: generation)
                    return
                }
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                guard let event = try? decoder.decode(ServerEvent.self, from: data) else { continue }
                await self?.handle(event, generation: generation)
            }
        }
    }

    private func disconnected(_ error: Error, status: Int?, generation: Int) {
        guard generation == self.generation else { return }
        switch status {
        case 401: end("OpenAI didn't accept the key. Check it in Settings › Providers.")
        case 403, 404: end("This OpenAI key can't use \(sessionModel) (HTTP \(status ?? 0)).")
        case 429: end("OpenAI's rate limit or quota is used up (HTTP 429).")
        default: end(phase == .connecting ? "Pi couldn't reach OpenAI: \(error.localizedDescription)" : "The connection to OpenAI closed.")
        }
    }

    private func handle(_ event: ServerEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event.type {
        case "session.updated":
            guard phase == .connecting else { break }
            outbox.open()
            phase = .live
            touch()

        case "input_audio_buffer.speech_started":
            hearing = true
            interrupt()
            if let item = event.itemId { log.heard[item, default: .init()].startMs = event.audioStartMs }

        case "input_audio_buffer.speech_stopped":
            hearing = false
            if let item = event.itemId, !turns.contains(where: { $0.id == item }) {
                turns.append(Turn(id: item, role: .user, text: "", pending: true))
            }
            if let item = event.itemId {
                log.heard[item, default: .init()].endMs = event.audioEndMs
                writeHeard(item)
            }
            touch()

        case "conversation.item.input_audio_transcription.failed":
            guard let item = event.itemId else { break }
            log.transcripts[item] = ""
            turns.removeAll { $0.id == item && $0.pending }

        case "conversation.item.input_audio_transcription.completed":
            guard let item = event.itemId else { break }
            let text = (event.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            log.transcripts[item] = text
            writeHeard(item)
            if let index = turns.firstIndex(where: { $0.id == item }) {
                turns[index].text = text
                turns[index].pending = false
                if text.isEmpty { turns.remove(at: index) }
            } else if !text.isEmpty {
                turns.append(Turn(id: item, role: .user, text: text))
            }

        case "response.created":
            responseActive = true

        case "response.output_audio.delta":
            if let delta = event.delta, let item = event.itemId {
                audio?.play(delta, item: item)
                speaking = true
            }

        case "response.output_audio_transcript.delta":
            guard let item = event.itemId, let delta = event.delta else { break }
            if let index = turns.firstIndex(where: { $0.id == item }) {
                turns[index].text += delta
            } else {
                turns.append(Turn(id: item, role: .pi, text: delta))
            }

        case "response.output_audio_transcript.done":
            guard let item = event.itemId, let transcript = event.transcript,
                  let index = turns.firstIndex(where: { $0.id == item }), !turns[index].pending else { break }
            turns[index].text = transcript
            // Written once it has been heard, or cut off: see `writeSpoken`.
            log.said.insert(item)
            if audio?.isPlaying != true { writeSpoken() }

        case "response.function_call_arguments.done":
            guard let call = event.callId else { break }
            if event.name == "ask_pi" {
                ask(call: call, arguments: event.arguments ?? "{}", generation: generation)
            } else {
                send(output(call, ["status": "failed", "error": "There is no tool named \(event.name ?? "")."]))
                requestResponse()
            }

        case "response.done":
            responseActive = false
            if event.response?.status == "failed" {
                let message = event.response?.statusDetails?.error?.message ?? "OpenAI couldn't answer."
                note(message)
                store.diagnostics.record("warn", "voice", "Response failed: \(message)")
            }
            if responseWanted {
                responseWanted = false
                requestResponse()
            }
            touch()

        case "error":
            let code = event.error?.code ?? ""
            let message = event.error?.message ?? "Unknown error"
            store.diagnostics.record("warn", "voice", "Realtime error \(code): \(message)")
            switch code {
            case "conversation_already_has_active_response":
                // Turn detection started one first; ours goes after it.
                responseWanted = true
            case "response_cancel_not_active":
                break
            case "invalid_api_key":
                end("OpenAI didn't accept the key. Check it in Settings › Providers.")
            default:
                if phase == .connecting { end(message) } else { note(message) }
            }

        default:
            break
        }
    }

    private func startAudio(generation: Int, recording: (mic: URL, pi: URL)?) async {
        let audio = VoiceAudio(recording: recording)
        let outbox = outbox
        audio.onInput = { [weak self] data, level in
            outbox.send(data)
            Task { @MainActor in self?.level = level }
        }
        audio.onPlaybackIdle = { [weak self] in
            Task { @MainActor in self?.playbackIdle(generation: generation) }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audio.queue.async {
                    do {
                        try audio.start()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            audio.queue.async { audio.stop() }
            guard generation == self.generation else { return }
            return end("The microphone didn't start: \(error.localizedDescription)")
        }
        guard generation == self.generation else {
            audio.queue.async { audio.stop() }
            return
        }
        self.audio = audio
    }

    private func playbackIdle(generation: Int) {
        guard generation == self.generation, audio?.isPlaying == false else { return }
        speaking = false
        writeSpoken()
        touch()
    }

    /// The user spoke over Pi: stop playing, and tell the model how much of its answer was heard, so it does not think
    /// it said the rest.
    private func interrupt() {
        guard let cut = audio?.interrupt() else { return }
        speaking = false
        send(["type": "conversation.item.truncate", "item_id": cut.item, "content_index": 0, "audio_end_ms": cut.playedMs])
        if let index = turns.firstIndex(where: { $0.id == cut.item }) {
            turns[index].pending = true
            turns[index].text += "…"
        }
        log.said.insert(cut.item)
        writeSpoken()
    }

    // MARK: ask_pi

    private func ask(call: String, arguments: String, generation: Int) {
        let request = (try? JSONDecoder().decode(AskArguments.self, from: Data(arguments.utf8)))?.request.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !request.isEmpty else {
            send(output(call, ["status": "failed", "error": "The request was empty."]))
            requestResponse()
            return
        }
        asks += 1
        let turnId = "ask-\(call)"
        turns.append(Turn(id: turnId, role: .note, text: request, pending: true))
        // The call ID is OpenAI's, unique to this call: a repeated delivery is one request, as for every entry point.
        let requestId = "voice:\(sessionId):\(call)"
        // "Checking." goes in before the request, though it is still being said.
        writeSpoken(all: true)
        let log = log
        // Admitted in turn with the lines, so the request sits after what led to it; then waited for outside the line.
        let admitted = log.enqueue { () async throws -> Int in
            // Started from the Action button, Pi may not be open yet.
            let store = await ChatStore.ready()
            guard let conversation = await self.conversation(log, store: store) else { throw PiIntentError("Pi could not start a conversation.") }
            _ = try await store.askFromOutside(request, conversationId: conversation, requestId: requestId, origin: "Voice", waitMs: 0, voice: log.session)
            return conversation
        }
        Task {
            var result: [String: Any]
            do {
                let conversation = try await admitted.value
                // The same request ID: this finds the submission just made and waits for its answer.
                let answer = try await ChatStore.shared.askFromOutside(
                    request, conversationId: conversation, requestId: requestId, origin: "Voice", waitMs: Self.answerWait, voice: log.session
                )
                switch answer.status {
                case "done": result = ["status": "done", "answer": String((answer.text ?? "").prefix(6000))]
                case "running": result = ["status": "running", "note": "Pi is still working. The answer will come as a notification."]
                default: result = ["status": "failed", "error": "Pi could not answer. The conversation in the app shows why."]
                }
            } catch {
                result = ["status": "failed", "error": (error as? PiIntentError)?.message ?? error.localizedDescription]
            }
            guard generation == self.generation else { return }
            asks -= 1
            if let index = turns.firstIndex(where: { $0.id == turnId }) { turns[index].pending = false }
            send(output(call, result))
            requestResponse()
            touch()
        }
    }

    /// The conversation for the session's lines and requests: the one it continues, or one made by the first thing
    /// said, once even when two need it together.
    private func conversation(_ log: SessionLog, store: ChatStore) async -> Int? {
        if let id = log.conversationId { return id }
        let task = log.creating ?? Task { await store.newConversation()?.id }
        log.creating = task
        let id = await task.value
        if log.conversationId == nil { log.conversationId = id }
        if log === self.log { conversationId = log.conversationId }
        return log.conversationId
    }

    // MARK: The record

    /// What the user said in `item`, into the conversation, once its transcription is in (a moment after the speech
    /// ends): it waits in the session's line, as what comes next was said after it. Nothing heard, nothing written.
    private func writeHeard(_ item: String) {
        let log = log
        guard log.queued.insert(item).inserted else { return }
        let at = Date.now
        log.enqueue {
            for _ in 0..<60 where log.transcripts[item] == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let text = log.transcripts[item], !text.isEmpty else { return }
            let store = await ChatStore.ready()
            guard let conversation = await self.conversation(log, store: store) else { return }
            let heard = log.heard[item]
            try await self.write(log, conversation: conversation, item: item, role: "user", text: text, startMs: heard?.startMs, endMs: heard?.endMs, at: at)
        }
    }

    /// What the voice said, into the conversation: the answers it finished saying (heard to the end or cut off), or
    /// with `all`, every answer it has words for, as when the session ends or the words lead to a request. Only into a
    /// conversation the session already has: the voice talking to itself starts none.
    private func writeSpoken(all: Bool = false) {
        let log = log
        for turn in turns where turn.role == .pi && !turn.text.isEmpty && !log.queued.contains(turn.id) {
            guard all || log.said.contains(turn.id) else { continue }
            log.queued.insert(turn.id)
            // Heard to the end unless it is still playing (a request goes in while "Checking." is said).
            let span = audio?.span(turn.id, finish: audio?.isPlaying != true)
            let text = turn.text
            let at = Date.now
            log.enqueue {
                guard let conversation = log.conversationId else { return }
                try await self.write(log, conversation: conversation, item: turn.id, role: "pi", text: text, startMs: span?.startMs, endMs: span?.endMs, at: at)
            }
        }
    }

    private func write(_ log: SessionLog, conversation: Int, item: String, role: String, text: String, startMs: Int?, endMs: Int?, at: Date) async throws {
        let line = VoiceLine(
            conversationId: conversation, itemId: item, session: log.session, role: role, text: text,
            startMs: log.recorded ? startMs : nil, endMs: log.recorded ? endMs : nil, at: (at.timeIntervalSince1970 * 1000).rounded()
        )
        do {
            try await ChatStore.shared.voiceLine(line)
            log.wrote = true
        } catch {
            ChatStore.shared.diagnostics.record("warn", "voice", "Could not keep a spoken line: \(error.localizedDescription)")
        }
    }

    /// The session's recording is complete. One with nothing written about it is deleted: nothing would play it.
    private func recordingClosed(_ log: SessionLog) {
        if recordingSession == log.session { recordingSession = nil }
        guard log.recorded else { return }
        Task {
            await log.chain?.value
            if !log.wrote { VoiceRecordings.delete(log.session) }
        }
    }

    private func output(_ call: String, _ result: [String: Any]) -> [String: Any] {
        let json = (try? JSONSerialization.data(withJSONObject: result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": call, "output": json]]
    }

    private struct AskArguments: Decodable { let request: String }

    // MARK: Approvals

    /// New approval requests from `ChatStore`: one in this session's conversation is said aloud, and answered on the
    /// screen (the root's approval sheet), never by voice.
    func approvalsChanged(new: [ApprovalRequest]) {
        guard phase == .live, let conversationId else { return }
        for request in new where request.conversationId == conversationId {
            let action = ToolTitles.action(for: request.tool)
            turns.append(Turn(id: "approval-\(request.id)", role: .note, text: "Waiting for your approval: \(action)"))
            send([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "system",
                    "content": [["type": "input_text", "text": "Pi is waiting for the user's approval to: \(action). In a few words, tell the user to tap Allow or Deny on the screen."]],
                ] as [String: Any],
            ])
            requestResponse()
        }
        touch()
    }

    // MARK: Live Activity

    /// What the Live Activity shows now.
    private var activityState: PiVoiceAttributes.ContentState {
        let line = turns.last { $0.role != .note && !$0.text.isEmpty }?.text
        if phase == .ended {
            return .init(status: endReason == nil ? "Ended" : "Couldn't continue", symbol: "waveform", line: endReason ?? line, ended: true, conversationId: conversationId)
        }
        if let approval {
            let action = ToolTitles.action(for: approval.tool)
            return .init(status: "Waiting for your approval", symbol: "hand.raised.fill", line: line, approval: .init(id: approval.id, action: action))
        }
        guard phase == .live else { return .init(status: "Connecting…", symbol: "waveform") }
        switch activity {
        case .listening: return .init(status: "Listening", symbol: "waveform", line: line)
        case .hearing: return .init(status: "Listening…", symbol: "waveform.badge.mic", line: line)
        case .working: return .init(status: "Pi is working…", symbol: "sparkle", line: line)
        case .speaking: return .init(status: "Speaking", symbol: "speaker.wave.2.fill", line: line)
        }
    }

    /// Starts the session's Live Activity; false when Live Activities are off or iOS refused.
    private func startActivity() -> Bool {
        endActivity(immediately: true)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let state = activityState
        do {
            liveActivity = try Activity.request(attributes: PiVoiceAttributes(), content: .init(state: state, staleDate: nil))
            shownActivity = state
            return true
        } catch {
            store.diagnostics.record("warn", "voice", "Could not start the Live Activity: \(error.localizedDescription)")
            return false
        }
    }

    /// Updates the Live Activity whenever what it shows changes, for as long as the session lasts: a new status or
    /// approval at once, the words as they come at most once a second.
    private func trackActivity(generation: Int) {
        guard generation == self.generation else { return }
        let state = withObservationTracking { activityState } onChange: { [weak self] in
            Task { @MainActor in self?.trackActivity(generation: generation) }
        }
        guard liveActivity != nil, state != shownActivity else { return }
        queuedActivity = state
        if state.status != shownActivity?.status || state.approval != shownActivity?.approval {
            flushActivity()
        } else if activityFlush == nil {
            activityFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.flushActivity()
            }
        }
    }

    private func flushActivity() {
        activityFlush?.cancel()
        activityFlush = nil
        guard let liveActivity, let state = queuedActivity, state != shownActivity else { return }
        shownActivity = state
        let box = ActivityBox(activity: liveActivity)
        Task.detached { await box.activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity(immediately: Bool = false) {
        // Every activity an earlier process or session left, too: there is only ever one voice session.
        let state = activityState
        let current = liveActivity
        liveActivity = nil
        shownActivity = nil
        queuedActivity = nil
        activityFlush?.cancel()
        activityFlush = nil
        for activity in Activity<PiVoiceAttributes>.activities where immediately || activity !== current {
            let box = ActivityBox(activity: activity)
            Task.detached { await box.activity.end(nil, dismissalPolicy: .immediate) }
        }
        guard let current, !immediately else { return }
        let box = ActivityBox(activity: current)
        Task.detached { await box.activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(8))) }
    }

    /// `Activity` is not `Sendable`; its async methods are called from outside the main actor, holding nothing else.
    private struct ActivityBox: @unchecked Sendable {
        let activity: Activity<PiVoiceAttributes>
    }

    // MARK: Quiet

    private func note(_ text: String) {
        turns.append(Turn(id: "note-\(UUID().uuidString)", role: .note, text: text))
    }

    /// Restarts the quiet timer: the session ends once nothing has happened for `idleLimit`.
    private func touch() {
        idle?.cancel()
        let generation = generation
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLimit)
            guard !Task.isCancelled, let self, generation == self.generation, phase == .live else { return }
            if activity == .listening { end() } else { touch() }
        }
    }
}

/// One session's record: what was heard and said, where in the recording, and the line its writes wait in, so each
/// goes into the conversation in the order it happened. A new session gets a new one; the old one's writes finish.
@MainActor
private final class SessionLog {
    struct Heard {
        var startMs: Int?
        var endMs: Int?
    }

    let session: String
    let recorded: Bool
    var conversationId: Int?
    var creating: Task<Int?, Never>?
    /// The user's speech by item: where it is in the recording, and its transcription once in ("" for nothing).
    var heard: [String: Heard] = [:]
    var transcripts: [String: String] = [:]
    /// The voice's answers it has finished saying (heard to the end, or cut off), by item.
    var said: Set<String> = []
    /// Items with a write queued.
    var queued: Set<String> = []
    /// Whether any line went into the conversation.
    var wrote = false
    private(set) var chain: Task<Void, Never>?

    init(session: String, conversationId: Int?, recorded: Bool) {
        self.session = session
        self.conversationId = conversationId
        self.recorded = recorded
    }

    /// Runs `work` after everything queued before it.
    @discardableResult
    func enqueue<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) -> Task<T, Error> {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        chain = Task { _ = try? await task.value }
        return task
    }
}

/// The Realtime server events the session reads; every other field is ignored.
private struct ServerEvent: Decodable, Sendable {
    struct Problem: Decodable, Sendable {
        let message: String?
        let code: String?
    }

    struct Response: Decodable, Sendable {
        struct Details: Decodable, Sendable { let error: Problem? }
        let status: String?
        let statusDetails: Details?
    }

    let type: String
    let delta: String?
    let itemId: String?
    let transcript: String?
    let callId: String?
    let name: String?
    let arguments: String?
    let error: Problem?
    let response: Response?
    /// Where speech started and stopped in the audio sent so far, for `input_audio_buffer.speech_*`.
    let audioStartMs: Int?
    let audioEndMs: Int?
}

/// Microphone chunks on their way to the socket. Held while the session is being set up, up to `maxHeld`, so the first
/// words count; sent in order once it is ready. Called from the audio thread.
private final class AudioOutbox: Sendable {
    private struct State: Sendable {
        var socket: URLSessionWebSocketTask?
        var open = false
        var held: [Data] = []
    }

    /// About 15 seconds of 100 ms chunks.
    static let maxHeld = 150
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A new session's socket. What the microphone gave before it is kept, as the recording has it: `close()` cleared
    /// what an earlier session left.
    func attach(_ socket: URLSessionWebSocketTask) {
        state.withLock { $0.socket = socket }
    }

    func send(_ chunk: Data) {
        state.withLock { state in
            guard state.open, let socket = state.socket else {
                if state.held.count < Self.maxHeld { state.held.append(chunk) }
                return
            }
            Self.send(chunk, on: socket)
        }
    }

    /// Sends what was held, then everything as it comes.
    func open() {
        state.withLock { state in
            state.open = true
            guard let socket = state.socket else { return }
            for chunk in state.held { Self.send(chunk, on: socket) }
            state.held = []
        }
    }

    func close() {
        state.withLock { $0 = State() }
    }

    private static func send(_ chunk: Data, on socket: URLSessionWebSocketTask) {
        socket.send(.string("{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(chunk.base64EncodedString())\"}")) { _ in }
    }
}
