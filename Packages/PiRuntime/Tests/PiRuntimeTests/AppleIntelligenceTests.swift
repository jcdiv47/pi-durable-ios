import Foundation
import Testing
@testable import PiRuntime

/// Stands in for Foundation Models behind the `apple` provider's local host: answers with the last user message, in
/// two chunks, the way `AppleIntelligence` streams. `fail` answers with an error inside the stream instead.
final class FakeAppleService: LocalHTTPService, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    let fail: Bool

    init(fail: Bool = false) { self.fail = fail }

    var requests: [[String: Any]] { lock.withLock { bodies } }

    func respond(to request: LocalHTTPRequest, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async {
        let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
        lock.withLock { bodies.append(body) }
        let chat = try! AppleChat.Request(body: request.body ?? Data())
        send(.response(status: 200, headers: ["content-type": "text/event-stream"]))
        send(.chunk(AppleChat.sse(id: "c1", model: chat.model, created: 0, delta: "", role: true)))
        if fail {
            send(.chunk(AppleChat.sseError("Apple Intelligence: refused")))
            send(.end)
            return
        }
        send(.chunk(AppleChat.sse(id: "c1", model: chat.model, created: 0, delta: "On device: ")))
        send(.chunk(AppleChat.sse(id: "c1", model: chat.model, created: 0, delta: chat.turns.last?.text ?? "")))
        send(.chunk(AppleChat.sse(id: "c1", model: chat.model, created: 0, finish: "stop")))
        send(.chunk(AppleChat.usage(id: "c1", model: chat.model, created: 0, prompt: 10, completion: 4)))
        send(.chunk(Data("data: [DONE]\n\n".utf8)))
        send(.end)
    }
}

@Suite("Apple Intelligence")
struct AppleIntelligenceTests {
    @Test("Chat messages become alternating turns; system prompts, tool calls and results become text")
    func turns() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "on-device",
            "max_completion_tokens": 900,
            "messages": [
                ["role": "system", "content": "Pi's long system prompt with tool sections"],
                ["role": "assistant", "content": "A stray answer first"],
                ["role": "user", "content": "What's on today?"],
                ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "t1", "type": "function", "function": ["name": "calendar_query", "arguments": "{}"]]]],
                ["role": "tool", "tool_call_id": "t1", "content": "{\"events\":[]}"],
                ["role": "assistant", "content": "Nothing today."],
                ["role": "user", "content": [["type": "text", "text": "Thanks"], ["type": "image_url", "image_url": ["url": "data:"]]]],
            ],
        ])
        let request = try AppleChat.Request(body: body)
        #expect(request.maxTokens == 900)
        #expect(request.turns.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(request.turns[0].text == "What's on today?")
        #expect(request.turns[1].text == "[Called the tool calendar_query]")
        #expect(request.turns[2].text.hasPrefix("[Tool result]"))
        #expect(request.turns[4].text == "Thanks\n[image]")
    }

    @Test("A conversation ending with an answer gets a user turn to continue from")
    func endsWithUser() {
        let turns = AppleChat.turns([["role": "user", "content": "Hi"], ["role": "assistant", "content": "Hello"]])
        #expect(turns.last == AppleChat.Turn(role: .user, text: "Continue."))
    }

    @Test("Fitting keeps the newest turns, starts with a user turn, and cuts a prompt too long on its own")
    func fit() {
        let turns = (0 ..< 10).map { AppleChat.Turn(role: $0.isMultiple(of: 2) ? .user : .assistant, text: String(repeating: "x", count: 300)) }
            + [AppleChat.Turn(role: .user, text: "last")]
        let kept = AppleChat.fit(turns, budget: 320)
        #expect(kept.last?.text == "last")
        #expect(kept.first?.role == .user)
        #expect(kept.reduce(0) { $0 + AppleChat.estimateTokens($1.text) } <= 320)
        #expect(kept.count < turns.count)

        let long = [AppleChat.Turn(role: .user, text: String(repeating: "word ", count: 2000))]
        let cut = AppleChat.fit(long, budget: 100)
        #expect(cut.count == 1)
        #expect(AppleChat.estimateTokens(cut[0].text) <= 100)
    }

    @Test("Titles lose quotes, a label and a final period")
    func cleanTitle() {
        #expect(AppleChat.cleanTitle("\"Weekend Hiking Plans.\"") == "Weekend Hiking Plans")
        #expect(AppleChat.cleanTitle("Title: Tax return checklist\nMore text") == "Tax return checklist")
        #expect(AppleChat.cleanTitle("「周末计划」。") == "周末计划")
        #expect(AppleChat.cleanTitle("  \"\" ") == nil)
    }

    @Test("Instructions say there are no tools and carry the user's AGENTS.md, cut to fit")
    func instructions() {
        let text = AppleChat.instructions(now: Date(timeIntervalSince1970: 0), user: String(repeating: "a", count: 5000))
        #expect(text.contains("You have no tools"))
        #expect(text.contains("The user's own instructions"))
        #expect(text.count < 2500)
    }
}

/// Against the real on-device model; skipped where Apple Intelligence is off or unsupported (CI, older Macs).
@Suite("Foundation Models on this machine", .enabled(if: AppleIntelligence.status == .available))
struct FoundationModelsTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var status: Int?
        func add(_ event: LocalHTTPEvent) {
            lock.withLock {
                switch event {
                case let .response(status, _): self.status = status
                case let .chunk(chunk): data.append(chunk)
                default: break
                }
            }
        }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    @Test("The endpoint streams an answer as OpenAI chunks, then a finish, usage and DONE", .timeLimit(.minutes(1)))
    func endpoint() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "on-device", "stream": true,
            "messages": [["role": "system", "content": "ignored"], ["role": "user", "content": "Say hello in three words."]],
        ])
        let events = Events()
        let request = LocalHTTPRequest(url: URL(string: "https://\(AppleIntelligence.host)/v1/chat/completions")!, method: "POST", body: body)
        await AppleIntelligence().respond(to: request) { events.add($0) }
        #expect(events.status == 200)
        let text = events.text
        #expect(text.contains("\"content\""))
        #expect(text.contains("\"finish_reason\":\"stop\""))
        #expect(text.contains("\"prompt_tokens\""))
        #expect(text.hasSuffix("data: [DONE]\n\n"))
        #expect(!text.contains("\"error\""))
    }

    @Test("A title comes back short and clean", .timeLimit(.minutes(1)))
    func title() async throws {
        let title = try #require(await AppleIntelligence().title(for: "can you help me plan a 3 day hike in yosemite next weekend"))
        print("title:", title)
        #expect(title.count <= 60)
        #expect(!title.hasPrefix("\""))
    }
}

@Suite("The apple provider inside JavaScriptCore", .serialized)
struct AppleProviderTests {
    private func open(_ log: ChatLog, service: FakeAppleService, db: String, titles: Bool = true) async throws -> PiHarness {
        let (_, url) = try bundledScript("pi-runtime")
        let harness = try await PiHarness.load(bundle: url, options: .init(
            onEvent: { log.handle($0) },
            onLog: { level, message in if level == "error" { print("[js \(level)] \(message)") } },
            hostCall: { name, json in
                log.record(name, json)
                if name == "intelligence.title" { return #""Greeting on device""# }
                throw JSRuntimeError("unexpected host call \(name)")
            },
            localHosts: [AppleIntelligence.host: service]
        ))
        _ = try await harness.open(.init(
            dbPath: db, provider: "faux", modelId: "killtest",
            appleModels: [AppleIntelligence.Model(id: "on-device", name: "Apple Intelligence (on device)", contextWindow: 4096, maxTokens: 1024)],
            intelligenceTitles: titles
        ))
        return harness
    }

    struct Model: Decodable { let provider: String; let id: String; let contextWindow: Double; let images: Bool }

    @Test("An apple/on-device conversation streams from the local host, and the model titles it", .timeLimit(.minutes(1)))
    func streams() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let service = FakeAppleService()
        let harness = try await open(log, service: service, db: directory.appendingPathComponent("chat.sqlite").path)

        let models: [Model] = try await harness.call("PiRuntime.models")
        let apple = try #require(models.first { $0.provider == "apple" })
        #expect(apple.id == "on-device" && apple.contextWindow == 4096 && !apple.images)

        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["apple", "on-device"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello there", "r1"])
        try await until { log.last(meta.id, kind: "assistant")?["text"] as? String == "On device: hello there" && !log.busy(meta.id) }
        #expect(service.requests.count == 1)
        #expect(service.requests.first?["stream"] as? Bool == true)
        // The first line is replaced by the model's title (the fake answers at once, so the list may show only the last).
        try await until { log.titles.last == "Greeting on device" }
        #expect(log.calls("intelligence.title") == 1)
        #expect(log.arguments("intelligence.title").first?["text"] as? String == "hello there")
        try await harness.close()
    }

    @Test("Without Apple Intelligence the provider leaves the picker; titles stay the first line when off", .timeLimit(.minutes(1)))
    func unavailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await open(log, service: FakeAppleService(), db: directory.appendingPathComponent("chat.sqlite").path, titles: false)
        try await harness.perform("PiRuntime.setAppleIntelligence", [[] as [String], false])
        let models: [Model] = try await harness.call("PiRuntime.models")
        #expect(!models.contains { $0.provider == "apple" })

        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "plain title", "r1"])
        try await until { !log.busy(meta.id) && log.last(meta.id, kind: "assistant") != nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.titles == ["plain title"])
        #expect(log.calls("intelligence.title") == 0)
        try await harness.close()
    }

    @Test("An error inside the stream ends the turn with that error", .timeLimit(.minutes(1)))
    func error() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await open(log, service: FakeAppleService(fail: true), db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["apple", "on-device"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hi", "r1"])
        try await until(.seconds(20)) { log.last(meta.id, kind: "assistant")?["stopReason"] as? String == "error" && !log.busy(meta.id) }
        #expect((log.last(meta.id, kind: "assistant")?["error"] as? String ?? "").contains("refused"))
        try await harness.close()
    }
}
