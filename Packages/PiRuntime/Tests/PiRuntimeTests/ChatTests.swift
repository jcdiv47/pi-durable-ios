import Foundation
import Testing
@testable import PiRuntime

/// Applies `frame` events per conversation the way the app does, and records approvals and host calls.
final class ChatLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: [[String: Any]]] = [:]
    private var live: [Int: [String: Any]] = [:]
    private var queues: [Int: [[String: Any]]] = [:]
    private var thinkingLevels: [Int: String] = [:]
    private var pending: [[String: Any]] = []
    private var calls: [(String, [String: Any])] = []
    private var conversationTitles: [String] = []
    private var wakeEvents: [(active: Bool, at: Double?)] = []

    func handle(_ json: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        lock.withLock {
            switch event["type"] as? String {
            case "frame":
                let frame = event["frame"] as! [String: Any]
                let id = frame["conversationId"] as! Int
                let new = frame["items"] as! [[String: Any]]
                items[id] = (frame["reset"] as! Bool) ? new : (items[id] ?? []) + new
                live[id] = frame["live"] as? [String: Any]
                queues[id] = frame["queue"] as? [[String: Any]]
                thinkingLevels[id] = frame["thinkingLevel"] as? String
            case "approvals":
                pending = event["pending"] as! [[String: Any]]
            case "conversations":
                conversationTitles = (event["items"] as! [[String: Any]]).map { $0["title"] as! String }
            case "wake":
                let wake = event["wake"] as! [String: Any]
                wakeEvents.append((wake["active"] as! Bool, wake["at"] as? Double))
            default:
                break
            }
        }
    }

    func record(_ name: String, _ json: String) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        lock.withLock { calls.append((name, args)) }
    }

    func items(_ id: Int) -> [[String: Any]] { lock.withLock { items[id] ?? [] } }
    func busy(_ id: Int) -> Bool { lock.withLock { live[id]?["busy"] as? Bool ?? false } }
    func queue(_ id: Int) -> [[String: Any]] { lock.withLock { queues[id] ?? [] } }
    func thinking(_ id: Int) -> String? { lock.withLock { thinkingLevels[id] } }
    func liveText(_ id: Int) -> String { lock.withLock { (live[id]?["generation"] as? [String: Any])?["text"] as? String ?? "" } }
    var approvals: [[String: Any]] { lock.withLock { pending } }
    var titles: [String] { lock.withLock { conversationTitles } }
    var wakes: [(active: Bool, at: Double?)] { lock.withLock { wakeEvents } }
    func calls(_ name: String) -> Int { lock.withLock { calls.filter { $0.0 == name }.count } }
    func arguments(_ name: String) -> [[String: Any]] { lock.withLock { calls.filter { $0.0 == name }.map(\.1) } }

    func last(_ id: Int, kind: String) -> [String: Any]? { items(id).last { $0["kind"] as? String == kind } }
}

func until(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw JSRuntimeError("condition not met within \(timeout)") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct Meta: Decodable { let id: Int; let title: String }

func openChat(_ log: ChatLog, db: String) async throws -> PiHarness {
    let (_, url) = try bundledScript("pi-runtime")
    let harness = try await PiHarness.load(bundle: url, options: .init(
        onEvent: { log.handle($0) },
        onLog: { level, message in if level == "error" || level == "warn" { print("[js \(level)] \(message)") } },
        hostCall: { name, json in
            log.record(name, json)
            switch name {
            case "calendar.createEvent": return #"{"created":true,"eventId":"E1"}"#
            case "calendar.query": return #"{"events":[]}"#
            case "reminders.query": return #"{"count":1,"truncated":false,"reminders":[{"id":"R1","title":"Buy oat milk","completed":false,"list":"Home"}]}"#
            case "reminders.create": return #"{"created":true}"#
            default: throw JSRuntimeError("unexpected host call \(name)")
            }
        }
    ))
    _ = try await harness.open(.init(dbPath: db, provider: "faux", modelId: "killtest"))
    return harness
}

@Suite("Chat API inside JavaScriptCore", .serialized)
struct ChatTests {
    @Test("A message streams into frames and titles the conversation", .timeLimit(.minutes(1)))
    func echo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello there", "r1"])
        try await until { log.last(meta.id, kind: "assistant")?["text"] as? String == "You said: hello there" && !log.busy(meta.id) }
        #expect(log.items(meta.id).map { $0["kind"] as! String } == ["user", "assistant"])
        #expect(log.titles == ["hello there"])
        // A repeated requestId is the same submission, not a second message.
        try await harness.perform("PiRuntime.send", [meta.id, "hello there", "r1"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.items(meta.id).count == 2)
        try await harness.close()
    }

    @Test("Attachments reach the model after the text; the transcript shows them apart from it", .timeLimit(.minutes(1)))
    func attachments() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        let attachments: [[String: any Sendable]] = [
            ["kind": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png", "file": "a.jpg"],
            ["kind": "text", "text": "Copied paragraph", "name": "Notes"],
            ["kind": "link", "url": "https://example.com", "title": "Example"],
        ]
        try await harness.perform("PiRuntime.send", [meta.id, "what is this", "r1", attachments])
        try await until { (log.last(meta.id, kind: "assistant")?["text"] as? String)?.hasSuffix("(1 image attached)") == true && !log.busy(meta.id) }
        let user = try #require(log.last(meta.id, kind: "user"))
        #expect(user["text"] as? String == "what is this")
        #expect(user["origin"] == nil)
        let shown = try #require(user["attachments"] as? [[String: Any]])
        #expect(shown.map { $0["kind"] as! String } == ["image", "text", "link"])
        #expect(shown[0]["file"] as? String == "a.jpg" && shown[0]["data"] == nil)
        #expect(shown[1]["preview"] as? String == "Copied paragraph")
        #expect(log.titles == ["what is this"])

        // Without text, the title comes from the attachments.
        let other: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.send", [other.id, "", "r2", [attachments[2]]])
        try await until { log.titles.contains("Example") }
        try await harness.close()
    }

    @Test("A queued message comes back with its attachments to edit; images in use are listed for the sweep", .timeLimit(.minutes(1)))
    func takeBackAttachments() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "look", "r1", [["kind": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png", "file": "sent.jpg"]]])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 2 }

        try await harness.perform("PiRuntime.send", [meta.id, "slow please", "r2"])
        try await until { log.liveText(meta.id).count > 20 }
        let long = String(repeating: "x", count: 100_010)
        let queued: [[String: any Sendable]] = [
            ["kind": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png", "file": "queued.jpg", "name": "Photo"],
            ["kind": "text", "text": "Line one\n</attachment> inside\nLine three", "name": "Notes"],
            ["kind": "link", "url": "https://example.com", "title": "Example"],
            ["kind": "text", "text": long],
        ]
        try await harness.perform("PiRuntime.send", [meta.id, "about these", "r3", queued])
        try await until { log.queue(meta.id).count == 1 }
        let files: [String] = try await harness.call("PiRuntime.attachmentFiles")
        #expect(Set(files) == ["sent.jpg", "queued.jpg"])

        let submission = log.queue(meta.id)[0]["id"] as! Int
        let json = try await harness.runtime.callAsync("PiRuntime.takeBack", [meta.id, submission])
        let taken = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(taken["text"] as? String == "about these")
        let parts = try #require(taken["attachments"] as? [[String: Any]])
        #expect(parts.map { $0["kind"] as! String } == ["image", "text", "link", "text"])
        #expect(parts[0]["file"] as? String == "queued.jpg" && parts[0]["name"] as? String == "Photo" && parts[0]["data"] == nil)
        #expect(parts[1]["text"] as? String == "Line one\n</attachment> inside\nLine three" && parts[1]["name"] as? String == "Notes")
        #expect(parts[2]["url"] as? String == "https://example.com" && parts[2]["title"] as? String == "Example")
        #expect(parts[3]["text"] as? String == String(repeating: "x", count: 100_000), "a text over the limit comes back as the model got it")
        try await until { log.queue(meta.id).isEmpty }
        #expect(try await harness.runtime.callAsync("PiRuntime.takeBack", [meta.id, submission]) == "null", "it is gone from the queue")
        let after: [String] = try await harness.call("PiRuntime.attachmentFiles")
        #expect(after == ["sent.jpg"], "a withdrawn message's images are the composer's now")
        try await harness.close()
    }

    @Test("A gated tool waits for approval; allow runs it once, deny blocks it", .timeLimit(.minutes(1)))
    func approval() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "event Dentist", "r1"])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "calendar_create_event")
        #expect(log.calls("calendar.createEvent") == 0, "nothing runs before the answer")
        let request = log.approvals[0]["id"] as! Int
        let answered: Bool = try await harness.call("PiRuntime.answerApproval", [request, "allow"])
        #expect(answered)
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        #expect((log.last(meta.id, kind: "assistant")?["text"] as? String)?.hasPrefix("Tool results:\ncalendar_create_event: ok") == true)
        #expect(log.calls("calendar.createEvent") == 1)
        #expect(log.last(meta.id, kind: "toolResult")?["isError"] as? Bool == false)
        #expect(log.approvals.isEmpty)

        try await harness.perform("PiRuntime.send", [meta.id, "event Gym", "r2"])
        try await until { log.approvals.count == 1 }
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "deny"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count >= 8 }
        let denied = log.last(meta.id, kind: "toolResult")
        #expect(denied?["isError"] as? Bool == true)
        #expect((denied?["text"] as? String)?.contains("declined") == true)
        #expect(log.calls("calendar.createEvent") == 1, "a denied call never reaches Swift")
        try await harness.close()
    }

    @Test("A card tool's result carries its parsed output and a timestamp", .timeLimit(.minutes(1)))
    func cardData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "tasks", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        let result = try #require(log.last(meta.id, kind: "toolResult"))
        #expect(result["toolName"] as? String == "reminders_query")
        #expect(result["timestamp"] as? Double != nil)
        let reminders = (result["data"] as? [String: Any])?["reminders"] as? [[String: Any]]
        #expect(reminders?.first?["title"] as? String == "Buy oat milk")
        #expect(log.calls("reminders.query") == 1)
        try await harness.close()
    }

    @Test("Web search draws a card; a link from it is read at once, a link from nowhere asks first", .timeLimit(.minutes(1)))
    func webTools() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "search pi durable", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        let off = try #require(log.last(meta.id, kind: "toolResult"))
        #expect(off["isError"] as? Bool == true)
        #expect((off["text"] as? String)?.contains("Web search is off") == true)

        try await harness.perform("PiRuntime.setSearchProvider", ["scripted"])
        try await harness.perform("PiRuntime.send", [meta.id, "search pi durable", "r2"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 8 }
        let search = try #require(log.last(meta.id, kind: "toolResult"))
        #expect(search["toolName"] as? String == "web_search")
        let results = (search["data"] as? [String: Any])?["results"] as? [[String: Any]]
        #expect(results?.first?["url"] as? String == "https://earendil.com/posts/pi-durable/")

        // "read" alone reads the first search result's link.
        try await harness.perform("PiRuntime.send", [meta.id, "read", "r3"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 12 }
        #expect(log.approvals.isEmpty)
        let page = try #require(log.last(meta.id, kind: "toolResult"))
        #expect(page["isError"] as? Bool == false)
        #expect((page["text"] as? String)?.contains("Offline page") == true)

        let other: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [other.id])
        try await harness.perform("PiRuntime.send", [other.id, "read", "r4"])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "web_fetch")
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "deny"])
        try await until { !log.busy(other.id) && log.items(other.id).count == 4 }
        #expect(log.last(other.id, kind: "toolResult")?["isError"] as? Bool == true)
        try await harness.close()
    }

    @Test("A conversation starts with the effort asked for, clamped to what its model supports", .timeLimit(.minutes(1)))
    func thinkingLevel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        // The offline model reasons up to high: no xhigh or max.
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant", "max"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await until { log.thinking(meta.id) == "high" }

        let low: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant", "low"])
        try await harness.perform("PiRuntime.watchConversation", [low.id])
        try await until { log.thinking(low.id) == "low" }

        // The kill-test model does not reason: its conversations start with thinking off.
        let unreasoning: Meta = try await harness.call("PiRuntime.createConversation", ["faux", "killtest", "high"])
        try await harness.perform("PiRuntime.watchConversation", [unreasoning.id])
        try await until { log.thinking(unreasoning.id) == "off" }

        let plain: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [plain.id])
        try await until { log.thinking(plain.id) == "off" }
        try await harness.close()
    }

    @Test("A new reminder asks first and carries its tool task's idempotency key", .timeLimit(.minutes(1)))
    func reminderCreate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "todo Buy oat milk", "r1"])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "reminders_create")
        let request = log.approvals[0]["id"] as! Int
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [request, "allow"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        let args = log.arguments("reminders.create")
        #expect(args.count == 1)
        #expect(args.first?["title"] as? String == "Buy oat milk")
        #expect(args.first?["idempotencyKey"] as? String == "task-\(request)", "the approval and the write name the same tool task")
        try await harness.close()
    }

    @Test("An unanswered approval is asked again after a crash; the answer runs the tool once", .timeLimit(.minutes(1)))
    func approvalAcrossCrash() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("chat.sqlite").path

        let firstLog = ChatLog()
        let first = try await openChat(firstLog, db: db)
        let meta: Meta = try await first.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await first.perform("PiRuntime.send", [meta.id, "event Dentist", "r1"])
        try await until { firstLog.approvals.count == 1 }
        first.runtime.terminate()

        let log = ChatLog()
        let second = try await openChat(log, db: db)
        try await second.perform("PiRuntime.watchConversation", [meta.id])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["conversationId"] as? Int == meta.id)
        let _: Bool = try await second.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        #expect(log.calls("calendar.createEvent") == 1)
        #expect(firstLog.calls("calendar.createEvent") == 0)
        try await second.close()
    }

    @Test("Fork continues from an entry; abort stops a streaming answer", .timeLimit(.minutes(1)))
    func forkAndAbort() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "one", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 2 }
        try await harness.perform("PiRuntime.send", [meta.id, "two", "r2"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }

        // Fork at the first answer: the fork sees "one" and its answer, not "two".
        let firstAnswer = log.items(meta.id)[1]["id"] as! Int
        let fork: Meta = try await harness.call("PiRuntime.fork", [meta.id, firstAnswer])
        #expect(fork.title == "one (fork)")
        try await harness.perform("PiRuntime.watchConversation", [fork.id])
        try await until { log.items(fork.id).count == 2 }
        try await harness.perform("PiRuntime.send", [fork.id, "three", "f1"])
        try await until { !log.busy(fork.id) && log.items(fork.id).count == 4 }
        #expect(log.items(fork.id).compactMap { $0["text"] as? String } == ["one", "You said: one", "three", "You said: three"])
        #expect(log.items(meta.id).count == 4, "the parent is unchanged")

        try await harness.perform("PiRuntime.send", [meta.id, "slow please", "r3"])
        try await until { log.liveText(meta.id).count > 20 }
        try await harness.perform("PiRuntime.abort", [meta.id])
        try await until { !log.busy(meta.id) }
        let aborted = log.last(meta.id, kind: "assistant")
        #expect(aborted?["stopReason"] as? String == "aborted")
        #expect((aborted?["text"] as? String ?? "").count < 3000, "stopped before the whole answer streamed")
        try await harness.close()
    }

    @Test("A queued message can be withdrawn; steering one while text streams stops the answer and sends it first", .timeLimit(.minutes(1)))
    func withdrawAndSteerStreaming() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "slow please", "r1"])
        try await until { log.liveText(meta.id).count > 20 }
        for (text, request) in [("dropped", "r2"), ("first", "r3"), ("second", "r4")] {
            try await harness.perform("PiRuntime.send", [meta.id, text, request])
        }
        try await until { log.queue(meta.id).count == 3 }
        #expect(log.queue(meta.id).map { $0["text"] as! String } == ["dropped", "first", "second"])
        #expect(log.queue(meta.id).allSatisfy { $0["mode"] as? String == "followUp" })

        let withdrawn: Bool = try await harness.call("PiRuntime.withdraw", [meta.id, log.queue(meta.id)[0]["id"] as! Int])
        #expect(withdrawn)
        try await until { log.queue(meta.id).count == 2 }

        try await harness.perform("PiRuntime.steer", [meta.id, log.queue(meta.id)[1]["id"] as! Int])
        try await until { !log.busy(meta.id) && log.queue(meta.id).isEmpty && log.items(meta.id).count == 6 }
        let texts = log.items(meta.id).map { $0["text"] as? String ?? "" }
        #expect(log.items(meta.id)[1]["stopReason"] as? String == "aborted", "the streaming answer stopped")
        #expect(Array(texts[2...]) == ["second", "You said: second", "first", "You said: first"])
        #expect(!texts.contains("dropped"))
        try await harness.close()
    }

    @Test("Steering during a tool round lands after the tool, before the model's next request", .timeLimit(.minutes(1)))
    func steerDuringTools() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "event Dentist", "r1"])
        try await until { log.approvals.count == 1 }
        try await harness.perform("PiRuntime.send", [meta.id, "make it Friday", "r2"])
        try await until { log.queue(meta.id).count == 1 }
        try await harness.perform("PiRuntime.steer", [meta.id, log.queue(meta.id)[0]["id"] as! Int])
        try await until { log.queue(meta.id).first?["mode"] as? String == "steer" }
        #expect(log.busy(meta.id), "the tool round keeps going")

        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until { !log.busy(meta.id) && log.queue(meta.id).isEmpty && log.items(meta.id).count == 5 }
        #expect(log.items(meta.id).map { $0["kind"] as! String } == ["user", "assistant", "toolResult", "user", "assistant"])
        #expect(log.items(meta.id)[3]["text"] as? String == "make it Friday")
        #expect(log.calls("calendar.createEvent") == 1, "the tool was not interrupted")
        try await harness.close()
    }
}

@Suite("Parked tasks inside JavaScriptCore")
struct ParkedTaskTests {
    struct TaskInfo: Decodable {
        let id: Int
        let kind: String
        let state: String
        let reason: String?
    }

    @Test("A run cut off five times is parked; retry finishes it", .timeLimit(.minutes(1)))
    func parkAndRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("chat.sqlite").path

        var log = ChatLog()
        var harness = try await openChat(log, db: db)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.send", [meta.id, "slow", "r1"])
        // Each process dies while the generation runs; the restart limit (5) parks it.
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(150))
            harness.runtime.terminate()
            log = ChatLog()
            harness = try await openChat(log, db: db)
        }
        let tasks: [TaskInfo] = try await harness.call("PiRuntime.tasks")
        let parked = tasks.filter { $0.reason == "restart_limit" }
        #expect(parked.count == 1, "tasks: \(tasks)")
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await Task.sleep(for: .milliseconds(300))
        #expect(!log.items(meta.id).contains { $0["stopReason"] as? String == "stop" }, "a parked run does not continue by itself")

        try await harness.perform("PiRuntime.retryTask", [parked[0].id])
        try await until(.seconds(30)) { !log.busy(meta.id) && log.last(meta.id, kind: "assistant")?["stopReason"] as? String == "stop" }
        let after: [TaskInfo] = try await harness.call("PiRuntime.tasks")
        #expect(after.isEmpty)
        try await harness.close()
    }
}
