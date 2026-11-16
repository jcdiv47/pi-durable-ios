import Foundation
import PiUI
import Testing
@testable import PiRuntime

/// Opens the chat with the UI tools answered by PiUI's real `SurfaceHost` and the notification calls stubbed,
/// all recorded in `log`.
func openEntryChat(_ log: ChatLog, db: String) async throws -> PiHarness {
    let root = URL(fileURLWithPath: db).deletingLastPathComponent().appendingPathComponent("group")
    let host = SurfaceHost(store: SurfaceStore(root: root), reload: {})
    let (_, url) = try bundledScript("pi-runtime")
    let harness = try await PiHarness.load(bundle: url, options: .init(
        onEvent: { log.handle($0) },
        onLog: { level, message in if level == "error" || level == "warn" { print("[js \(level)] \(message)") } },
        hostCall: { name, json in
            log.record(name, json)
            if SurfaceHost.handlers.contains(name) { return try await host.handle(name, json) }
            switch name {
            case "notify.post", "notify.schedule": return #"{"scheduled":true}"#
            case "calendar.createEvent": return #"{"created":true,"eventId":"E1"}"#
            default: throw JSRuntimeError("unexpected host call \(name)")
            }
        }
    ))
    _ = try await harness.open(.init(dbPath: db, provider: "faux", modelId: "killtest"))
    return harness
}

struct ScheduleInfo: Decodable {
    let taskId: Int
    let conversationId: Int
    let name: String
    let runs: Int
    let nextAt: Double?
}

struct OutsideAnswer: Decodable {
    let conversationId: Int
    let status: String
    let text: String?
}

private let scripted: [String: any Sendable] = ["provider": "scripted", "modelId": "assistant"]

private func outside(_ text: String, requestId: String, conversationId: Int? = nil, waitMs: Int = 10_000) -> [String: any Sendable] {
    var input: [String: any Sendable] = ["text": text, "requestId": requestId, "origin": "Siri", "waitMs": waitMs, "model": scripted]
    if let conversationId { input["conversationId"] = conversationId }
    return input
}

@Suite("Scheduled tasks and outside entry points inside JavaScriptCore", .serialized)
struct EntryPointTests {
    @Test("An approved schedule sleeps, runs its prompt in the conversation, notifies, and updates $doc", .timeLimit(.minutes(1)))
    func schedule() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openEntryChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "schedule a nudge", "r1"])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "schedule_task")
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        let schedules: [ScheduleInfo] = try await harness.call("PiRuntime.schedules")
        #expect(schedules.map(\.name) == ["nudge"], "\(log.items(meta.id))")
        #expect(log.wakes.contains { $0.at != nil }, "the sleep is reported to the host")

        // Three seconds later the sleep wakes in this process: the prompt runs, set_value fires, the answer is posted.
        try await until(.seconds(20)) { log.calls("notify.post") == 1 && !log.busy(meta.id) }
        #expect(log.calls("ui.values") == 1)
        let scheduled = log.items(meta.id).first { $0["origin"] as? String == "Scheduled: nudge" }
        #expect((scheduled?["text"] as? String)?.hasPrefix("[Scheduled task \"nudge\"]") == true)
        let after: [ScheduleInfo] = try await harness.call("PiRuntime.schedules")
        #expect(after.isEmpty, "a one-shot schedule ends after its run")
        try await harness.close()
    }

    @Test("A scheduled run that answers NO_REPLY posts no notification and shows quietly", .timeLimit(.minutes(1)))
    func scheduleNoReply() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openEntryChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.setPolicies", [["schedule_task": "auto"]])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "quiet check", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }

        // The run three seconds later answers NO_REPLY.
        try await until(.seconds(20)) { log.items(meta.id).contains { $0["noReply"] as? Bool == true } && !log.busy(meta.id) }
        let answer = try #require(log.items(meta.id).last { $0["kind"] as? String == "assistant" })
        #expect(answer["text"] as? String == "Nothing to report")
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.calls("notify.post") == 0)
        try await harness.close()
    }

    @Test("A schedule sleeping when the process dies runs once in the next process", .timeLimit(.minutes(1)))
    func scheduleAcrossCrash() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("chat.sqlite").path
        let firstLog = ChatLog()
        let first = try await openEntryChat(firstLog, db: db)
        let meta: Meta = try await first.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await first.perform("PiRuntime.setPolicies", [["schedule_task": "auto"]])
        try await first.perform("PiRuntime.watchConversation", [meta.id])
        try await first.perform("PiRuntime.send", [meta.id, "schedule a nudge", "r1"])
        try await until { !firstLog.busy(meta.id) && firstLog.items(meta.id).count == 4 }
        first.runtime.terminate()

        let log = ChatLog()
        let second = try await openEntryChat(log, db: db)
        try await second.perform("PiRuntime.watchConversation", [meta.id])
        try await until(.seconds(20)) { log.calls("notify.post") == 1 && !log.busy(meta.id) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(firstLog.calls("notify.post") == 0)
        #expect(log.items(meta.id).filter { $0["origin"] as? String == "Scheduled: nudge" }.count == 1)
        try await second.close()
    }

    @Test("An outside request starts one conversation; retrying its request ID finds the same submission", .timeLimit(.minutes(1)))
    func askFromOutside() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openEntryChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let answer: OutsideAnswer = try await harness.call("PiRuntime.askFromOutside", [outside("hello from Siri", requestId: "siri-1")])
        #expect(answer.status == "done")
        #expect(answer.text == "You said: hello from Siri")
        let again: OutsideAnswer = try await harness.call("PiRuntime.askFromOutside", [outside("hello from Siri", requestId: "siri-1")])
        #expect(again.conversationId == answer.conversationId)
        let conversations: [Meta] = try await harness.call("PiRuntime.conversations")
        #expect(conversations.count == 1)
        try await harness.perform("PiRuntime.watchConversation", [answer.conversationId])
        try await until { log.items(answer.conversationId).count == 2 }
        #expect(log.items(answer.conversationId)[0]["origin"] as? String == "Siri")

        // Continue it: a new request ID in an existing conversation.
        let next: OutsideAnswer = try await harness.call(
            "PiRuntime.askFromOutside", [outside("and again", requestId: "siri-2", conversationId: answer.conversationId)]
        )
        #expect(next.text == "You said: and again")
        // Not waiting: admitted, then answered in the background.
        let quick: OutsideAnswer = try await harness.call("PiRuntime.askFromOutside", [outside("slow one", requestId: "siri-3", waitMs: 0)])
        #expect(quick.status == "running")
        try await harness.close()
    }

    @Test("Talk to Pi's spoken lines are display-only entries, once per item, around the request it handed to Pi", .timeLimit(.minutes(1)))
    func voiceLines() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openEntryChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        func line(_ item: String, _ role: String, _ text: String, startMs: Int) -> [String: any Sendable] {
            ["conversationId": meta.id, "itemId": item, "session": "s1", "role": role, "text": text, "startMs": startMs, "endMs": startMs + 900, "at": 1_000]
        }
        try await harness.perform("PiRuntime.voiceLine", [line("u1", "user", "is the home lab okay", startMs: 200)])
        // Delivered twice: one entry.
        try await harness.perform("PiRuntime.voiceLine", [line("u1", "user", "is the home lab okay", startMs: 200)])
        try await harness.perform("PiRuntime.voiceLine", [line("p1", "pi", "Checking.", startMs: 1_500)])
        var request = outside("Check the home lab", requestId: "voice:s1:c1", conversationId: meta.id)
        request["origin"] = "Voice"
        request["voice"] = "s1"
        // As RealtimeVoice sends it: admitted in turn with the lines, then the same request ID again to wait for the answer.
        request["waitMs"] = 0
        let admitted: OutsideAnswer = try await harness.call("PiRuntime.askFromOutside", [request])
        #expect(admitted.status == "running")
        request["waitMs"] = 10_000
        let answer: OutsideAnswer = try await harness.call("PiRuntime.askFromOutside", [request])
        #expect(answer.text == "You said: Check the home lab")
        try await harness.perform("PiRuntime.voiceLine", [line("p2", "pi", "All good.", startMs: 4_000)])
        try await until { log.items(meta.id).count == 5 }
        let items = log.items(meta.id)
        #expect(items.map { $0["kind"] as? String } == ["voice", "voice", "user", "assistant", "voice"])
        let heard = items[0]["voice"] as? [String: Any]
        #expect(heard?["role"] as? String == "user")
        #expect(heard?["startMs"] as? Int == 200)
        #expect((items[2]["voice"] as? [String: Any])?["session"] as? String == "s1")
        // The model read only the request, not the spoken lines.
        #expect(items[3]["text"] as? String == "You said: Check the home lab")
        let conversations: [Meta] = try await harness.call("PiRuntime.conversations")
        #expect(conversations.first { $0.id == meta.id }?.title == "is the home lab okay")
        let sessions: [String] = try await harness.call("PiRuntime.voiceSessions")
        #expect(sessions == ["s1"])
        try await harness.close()
    }

    @Test("A widget toggle changes a $doc list once per request ID", .timeLimit(.minutes(1)))
    func widgetToggle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openEntryChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        // No published surface: the action is refused.
        await #expect(throws: (any Error).self) {
            let missing: [String: any Sendable] = ["kind": "set", "key": "x", "value": 1]
            try await harness.perform("PiRuntime.widgetAction", ["c1-s1", missing, "w0", "scripted", "assistant"])
        }
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.setPolicies", [["publish_surface": "auto"]])
        try await harness.perform("PiRuntime.send", [meta.id, "widget please", "r1"])
        try await until { log.calls("ui.publish") == 1 }
        let publishedId = "c\(meta.id)-s1"
        // The host call comes before JS commits the published surface; wait for the commit, which widgetAction reads.
        for _ in 0 ..< 200 {
            let published: [PublishedInfo] = try await harness.call("PiRuntime.publishedSurfaces")
            if published.contains(where: { $0.publishedId == publishedId }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let list: [[String: any Sendable]] = [["title": "Water"], ["title": "Walk"]]
        func action(_ action: [String: any Sendable], _ requestId: String) async throws {
            try await harness.perform("PiRuntime.widgetAction", [publishedId, action, requestId, "scripted", "assistant"])
        }
        try await action(["kind": "set", "key": "todo", "value": list], "w1")
        try await action(["kind": "toggle", "key": "todo", "index": 1], "w2")
        try await action(["kind": "toggle", "key": "todo", "index": 1], "w2") // the same tap, delivered twice
        let values: [String: JSONValue] = try await harness.call("PiRuntime.surfaceValues")
        #expect(values["todo"]?[1]?["done"] == .bool(true))
        #expect(values["todo"]?[0]?["done"] == nil)
        #expect(log.calls("ui.values") == 2)

        // A prompt action goes to the surface's conversation, labelled with the widget and the button.
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await action(["kind": "prompt", "prompt": "log a glass of water", "title": "Water"], "w3")
        try await until { log.items(meta.id).contains { $0["origin"] as? String == "Widget: Morning › Water" } && !log.busy(meta.id) }
        try await harness.close()
    }

    @Test("An approval answered before the relaunched hook asks again is used, and the tool runs once", .timeLimit(.minutes(1)))
    func earlyApproval() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("chat.sqlite").path
        let firstLog = ChatLog()
        let first = try await openEntryChat(firstLog, db: db)
        let meta: Meta = try await first.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await first.perform("PiRuntime.send", [meta.id, "event Dentist", "r1"])
        try await until { firstLog.approvals.count == 1 }
        let request = firstLog.approvals[0]["id"] as! Int
        first.runtime.terminate()

        // A notification's Allow, delivered as soon as the new process has opened.
        let log = ChatLog()
        let second = try await openEntryChat(log, db: db)
        let _: Bool = try await second.call("PiRuntime.answerApproval", [request, "allow"])
        try await second.perform("PiRuntime.watchConversation", [meta.id])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        #expect(log.calls("calendar.createEvent") == 1)
        #expect(log.approvals.isEmpty)
        try await second.close()
    }
}
