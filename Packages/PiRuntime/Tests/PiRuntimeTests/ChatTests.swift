import Foundation
import Testing
@testable import PiRuntime

/// Applies `frame` events per conversation the way the app does, and records approvals and host calls.
final class ChatLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: [[String: Any]]] = [:]
    private var live: [Int: [String: Any]] = [:]
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
    func liveText(_ id: Int) -> String { lock.withLock { (live[id]?["generation"] as? [String: Any])?["text"] as? String ?? "" } }
    var approvals: [[String: Any]] { lock.withLock { pending } }
    var titles: [String] { lock.withLock { conversationTitles } }
    var wakes: [(active: Bool, at: Double?)] { lock.withLock { wakeEvents } }
    func calls(_ name: String) -> Int { lock.withLock { calls.filter { $0.0 == name }.count } }

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
