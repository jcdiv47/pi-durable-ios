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
/// Over a WebSocket from Swift with the OpenAI provider key, which never reaches JS. Nothing about the voice session is
/// durable: if the app dies the session is gone, and a Pi turn it started finishes in its conversation (and notifies) as
/// any other turn does. One at a time (`shared`), started from the voice screen or `TalkToPiIntent` (the Action button,
/// Control Center), which may run with the app in the background: the session shows as a Live Activity
/// (`PiVoiceAttributes`), and iOS lets it record only while that shows. Leaving the voice screen does not end it.
@MainActor
@Observable
final class RealtimeVoice {
    static let shared = RealtimeVoice()

    static let model = "gpt-realtime-2.1"
    static let voice = "marin"
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

    private var hearing = false
    private var speaking = false
    private var asks = 0

    var activity: Mode {
        if speaking { return .speaking }
        if hearing { return .hearing }
        if asks > 0 || waitingForApproval { return .working }
        return .listening
    }

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
    private var creating: Task<Int?, Never>?
    private var interruptions: NSObjectProtocol?
    /// Bumped by every start and end: work from an earlier session finds it changed and does nothing.
    private var generation = 0
    private var sessionId = ""
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
        creating = nil
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
        await startAudio(generation: generation)
        guard generation == self.generation else { return }

        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(Self.model)")!)
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
        store.diagnostics.record("info", "voice", "Voice session starting (\(Self.model))\(background ? " in the background" : "")")
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
        end()
        guard wasRunning, UIApplication.shared.applicationState != .active, store.phase == .ready else { return }
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
        if let audio {
            audio.onInput = nil
            audio.onPlaybackIdle = nil
            audio.queue.async { audio.stop() }
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
                        "transcription": ["model": VoiceInput.model],
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

    static let instructions = """
    You are the voice of Pi, the user's personal agent on their iPhone. You hear the user and speak Pi's answers; Pi does \
    the work. Pi can reach their home lab (Proxmox, SSH machines), Home Assistant and other servers they connected, \
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
        case 403, 404: end("This OpenAI key can't use \(Self.model) (HTTP \(status ?? 0)).")
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

        case "input_audio_buffer.speech_stopped":
            hearing = false
            if let item = event.itemId, !turns.contains(where: { $0.id == item }) {
                turns.append(Turn(id: item, role: .user, text: "", pending: true))
            }
            touch()

        case "conversation.item.input_audio_transcription.completed":
            guard let item = event.itemId else { break }
            let text = (event.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func startAudio(generation: Int) async {
        let audio = VoiceAudio()
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
        Task {
            var result: [String: Any]
            do {
                // Started from the Action button, Pi may not be open yet.
                let store = await ChatStore.ready()
                guard let conversation = await conversation(store: store) else { throw PiIntentError("Pi could not start a conversation.") }
                let answer = try await store.askFromOutside(
                    request, conversationId: conversation, requestId: requestId, origin: "Voice", waitMs: Self.answerWait
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

    /// The conversation for this session's requests, created once even when two arrive together.
    private func conversation(store: ChatStore) async -> Int? {
        if let conversationId { return conversationId }
        let task = creating ?? Task { await store.newConversation()?.id }
        creating = task
        let id = await task.value
        if conversationId == nil { conversationId = id }
        return conversationId
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

    /// A new session's socket; chunks an earlier session left are dropped.
    func attach(_ socket: URLSessionWebSocketTask) {
        state.withLock { $0 = State(socket: socket) }
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
