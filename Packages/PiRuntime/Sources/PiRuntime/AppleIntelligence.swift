import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence (docs/adr/0008-apple-intelligence.md): the on-device model as an OpenAI-compatible chat
/// endpoint served in the process (`JSRuntime.Options.localHosts`), so pi-ai streams from it like from any provider,
/// and one-shot jobs (titles, summaries) Swift and JS ask for directly.
public final class AppleIntelligence: LocalHTTPService, @unchecked Sendable {
    /// The host JS's `apple` provider points at; `fetch` to it never leaves the process.
    public static let host = "apple-intelligence.pi.local"

    /// A model JS registers (`PiRuntime.setAppleModels`).
    public struct Model: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let contextWindow: Int
        public let maxTokens: Int
    }

    /// Whether the on-device model can run, for Settings and the model list.
    public enum Status: String, Sendable, Equatable {
        case available
        case deviceNotEligible
        case notEnabled
        case modelNotReady
        case unsupported

        public var explanation: String {
            switch self {
            case .available: "Ready on this iPhone."
            case .deviceNotEligible: "This device can't run Apple Intelligence."
            case .notEnabled: "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri."
            case .modelNotReady: "The model is still downloading. Try again later."
            case .unsupported: "Foundation Models isn't available in this build."
            }
        }
    }

    private let userInstructions: @Sendable () -> String?

    /// `userInstructions` returns the user's AGENTS.md, added to the model's instructions when it fits.
    public init(userInstructions: @escaping @Sendable () -> String? = { nil }) {
        self.userInstructions = userInstructions
    }

    public static var status: Status {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    /// The models that can run now. Empty when Apple Intelligence is off or unsupported.
    public static func models() -> [Model] {
        #if canImport(FoundationModels)
        guard status == .available else { return [] }
        let context = SystemLanguageModel.default.contextSize
        return [Model(id: "on-device", name: "Apple Intelligence (on device)", contextWindow: context, maxTokens: max(512, context / 4))]
        #else
        return []
        #endif
    }

    // MARK: Chat endpoint

    public func respond(to request: LocalHTTPRequest, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async {
        guard request.method.uppercased() == "POST", request.url.path.hasSuffix("/chat/completions") else {
            return AppleChat.sendError(status: 404, message: "Not found: \(request.url.path)", send: send)
        }
        let chat: AppleChat.Request
        do {
            chat = try AppleChat.Request(body: request.body ?? Data())
        } catch {
            return AppleChat.sendError(status: 400, message: "Bad request: \(error)", send: send)
        }
        #if canImport(FoundationModels)
        guard Self.status == .available else {
            return AppleChat.sendError(status: 503, message: "Apple Intelligence: \(Self.status.explanation)", send: send)
        }
        await streamOnDevice(chat, send: send)
        #else
        AppleChat.sendError(status: 503, message: Status.unsupported.explanation, send: send)
        #endif
    }

    #if canImport(FoundationModels)
    private func streamOnDevice(_ chat: AppleChat.Request, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async {
        let context = SystemLanguageModel.default.contextSize
        let answerRoom = min(chat.maxTokens ?? context / 4, context / 3)
        let instructions = AppleChat.instructions(now: .now, user: userInstructions())
        var budget = context - answerRoom - AppleChat.estimateTokens(instructions)
        let id = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let created = Int(Date.now.timeIntervalSince1970)
        send(.response(status: 200, headers: ["content-type": "text/event-stream", "cache-control": "no-cache"]))
        send(.chunk(AppleChat.sse(id: id, model: chat.model, created: created, delta: "", role: true)))

        // Two tries: if the estimate was too generous, the second keeps half as much history.
        for attempt in 0 ..< 2 {
            let turns = AppleChat.fit(chat.turns, budget: budget)
            guard let prompt = turns.last else { break }
            let promptTokens = AppleChat.estimateTokens(instructions) + turns.reduce(0) { $0 + AppleChat.estimateTokens($1.text) }
            var entries: [Transcript.Entry] = [
                .instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: [])),
            ]
            for turn in turns.dropLast() {
                switch turn.role {
                case .user: entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: turn.text))])))
                case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.text))])))
                }
            }
            let session = LanguageModelSession(model: SystemLanguageModel.default, transcript: Transcript(entries: entries))
            let options = GenerationOptions(temperature: chat.temperature, maximumResponseTokens: answerRoom)
            var sent = ""
            do {
                for try await snapshot in session.streamResponse(to: prompt.text, options: options) {
                    if Task.isCancelled { return }
                    let text = snapshot.content
                    let delta = text.hasPrefix(sent) ? String(text.dropFirst(sent.count)) : text
                    sent = text
                    if !delta.isEmpty { send(.chunk(AppleChat.sse(id: id, model: chat.model, created: created, delta: delta))) }
                }
                let completion = AppleChat.estimateTokens(sent)
                send(.chunk(AppleChat.sse(id: id, model: chat.model, created: created, finish: "stop")))
                send(.chunk(AppleChat.usage(id: id, model: chat.model, created: created, prompt: promptTokens, completion: completion)))
                send(.chunk(Data("data: [DONE]\n\n".utf8)))
                send(.end)
                return
            } catch {
                if Task.isCancelled { return }
                if attempt == 0, sent.isEmpty, Self.isContextOverflow(error) {
                    budget /= 2
                    continue
                }
                send(.chunk(AppleChat.sseError(Self.describe(error))))
                send(.end)
                return
            }
        }
        send(.chunk(AppleChat.sseError("Apple Intelligence: the conversation doesn't fit the on-device model's context.")))
        send(.end)
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        if case .exceededContextWindowSize = error as? LanguageModelSession.GenerationError { return true }
        if #available(iOS 27.0, macOS 27.0, *), case .contextSizeExceeded = error as? LanguageModelError { return true }
        return false
    }

    static func describe(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "Apple Intelligence: \(detail)"
    }
    #endif

    // MARK: One-shot jobs

    /// Answers `prompt` under `instructions` on device, or nil when the model is unavailable, refuses, fails or takes
    /// longer than `timeout`.
    public func generate(_ prompt: String, instructions: String, maxTokens: Int = 120, timeout: Duration = .seconds(6)) async -> String? {
        #if canImport(FoundationModels)
        guard Self.status == .available else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
                let response = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens))
                return response?.content
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }

    /// A short conversation title for its first message.
    public func title(for text: String) async -> String? {
        let message = String(text.prefix(2000))
        let answer = await generate(
            message,
            instructions: """
            Write a title of two to six words for a conversation that starts with the user's message below. \
            Use the message's language. Reply with the title only: no quotes, no final period, no emoji.
            """,
            maxTokens: 24
        )
        return answer.flatMap(AppleChat.cleanTitle)
    }

    /// One or two sentences that say what `text` (an assistant's answer) found or did.
    public func summary(of text: String) async -> String? {
        let answer = await generate(
            String(text.prefix(6000)),
            instructions: """
            Summarize the assistant's answer below in one or two short sentences for a notification. \
            Keep names, numbers and times. Use the answer's language. Reply with the summary only.
            """,
            maxTokens: 80
        )
        let trimmed = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The OpenAI chat request and response shapes the endpoint speaks, kept free of Foundation Models so they can be
/// tested anywhere.
enum AppleChat {
    struct Turn: Equatable {
        enum Role: Equatable { case user, assistant }
        let role: Role
        var text: String
    }

    struct Request {
        let model: String
        let turns: [Turn]
        let maxTokens: Int?
        let temperature: Double?

        init(body: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw JSRuntimeError("expected a JSON object")
            }
            guard let messages = object["messages"] as? [[String: Any]] else { throw JSRuntimeError("missing messages") }
            model = object["model"] as? String ?? "on-device"
            maxTokens = (object["max_completion_tokens"] as? Int) ?? (object["max_tokens"] as? Int)
            temperature = object["temperature"] as? Double
            turns = AppleChat.turns(messages)
        }
    }

    /// The conversation as alternating user and assistant turns. System and developer messages are dropped (the
    /// endpoint writes its own instructions); tool calls and results become short text, since the model has no tools.
    static func turns(_ messages: [[String: Any]]) -> [Turn] {
        var turns: [Turn] = []
        func add(_ role: Turn.Role, _ text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if turns.last?.role == role { turns[turns.count - 1].text += "\n\n" + text } else { turns.append(Turn(role: role, text: text)) }
        }
        for message in messages {
            let role = message["role"] as? String ?? ""
            let content = text(message["content"])
            switch role {
            case "user":
                add(.user, content)
            case "assistant":
                var parts = [content]
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any]
                    parts.append("[Called the tool \(function?["name"] as? String ?? "?")]")
                }
                add(.assistant, parts.filter { !$0.isEmpty }.joined(separator: "\n"))
            case "tool":
                let name = message["name"] as? String
                add(.user, "[Tool result\(name.map { " from \($0)" } ?? "")]\n" + String(content.prefix(1500)))
            default:
                continue
            }
        }
        if turns.first?.role == .assistant { turns.removeFirst() }
        if turns.last?.role == .assistant { turns.append(Turn(role: .user, text: "Continue.")) }
        return turns
    }

    private static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.map { part in
            switch part["type"] as? String {
            case "text": part["text"] as? String ?? ""
            case "image_url": "[image]"
            default: ""
            }
        }.joined(separator: "\n")
    }

    /// Tokens `text` takes, overestimated: about three UTF-8 bytes a token, which counts a CJK character as one.
    static func estimateTokens(_ text: String) -> Int { max(1, (text.utf8.count + 2) / 3) }

    /// The newest turns that fit `budget` tokens, starting with a user turn. The last (the prompt) always stays, cut
    /// to fit if it alone is too long.
    static func fit(_ turns: [Turn], budget: Int) -> [Turn] {
        guard var prompt = turns.last else { return [] }
        let budget = max(budget, 64)
        if estimateTokens(prompt.text) > budget {
            prompt.text = String(prompt.text.utf8.prefix(budget * 3)).map { String($0) } ?? String(prompt.text.prefix(budget))
            return [prompt]
        }
        var kept = [prompt]
        var used = estimateTokens(prompt.text)
        for turn in turns.dropLast().reversed() {
            let cost = estimateTokens(turn.text)
            if used + cost > budget { break }
            kept.insert(turn, at: 0)
            used += cost
        }
        while kept.count > 1, kept.first?.role == .assistant { kept.removeFirst() }
        return kept
    }

    static func instructions(now: Date, user: String?) -> String {
        let date = now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        var text = """
        You are Pi, a helpful assistant on the user's iPhone. You run on the device with Apple Intelligence. \
        It is \(date). You have no tools: you can't read the calendar, reminders, health data, location or the \
        web, and can't create widgets or schedule anything. When a request needs one of those, say so briefly and \
        suggest switching this conversation to a cloud model in the model picker. Answer concisely, in the user's \
        language. Use Markdown only when it helps.
        """
        if let user = user?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            text += "\n\nThe user's own instructions:\n" + String(user.prefix(1500))
        }
        return text
    }

    /// A title as the model wrote it, without quotes, a heading mark or a final period; nil if nothing is left.
    static func cleanTitle(_ raw: String) -> String? {
        var title = raw.split(separator: "\n").first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: .whitespaces)
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"'“”‘’「」『』.。").union(.whitespaces))
        guard !title.isEmpty else { return nil }
        return title.count > 60 ? String(title.prefix(57)) + "…" : title
    }

    // MARK: SSE

    static func sse(id: String, model: String, created: Int, delta: String? = nil, role: Bool = false, finish: String? = nil) -> Data {
        var deltaObject: [String: Any] = [:]
        if role { deltaObject["role"] = "assistant" }
        if let delta { deltaObject["content"] = delta }
        let choice: [String: Any] = ["index": 0, "delta": deltaObject, "finish_reason": finish ?? NSNull()]
        return event(["id": id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [choice]])
    }

    static func usage(id: String, model: String, created: Int, prompt: Int, completion: Int) -> Data {
        event([
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [] as [Any],
            "usage": ["prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion],
        ])
    }

    /// An error inside the stream; the OpenAI client throws it as an API error.
    static func sseError(_ message: String) -> Data {
        event(["error": ["message": message, "type": "apple_intelligence_error"]])
    }

    static func sendError(status: Int, message: String, send: @Sendable (LocalHTTPEvent) -> Void) {
        send(.response(status: status, headers: ["content-type": "application/json"]))
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "apple_intelligence_error"]])) ?? Data()
        send(.chunk(body))
        send(.end)
    }

    private static func event(_ object: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
}
