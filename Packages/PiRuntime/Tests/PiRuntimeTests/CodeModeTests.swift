import Foundation
import Testing
@testable import PiRuntime

/// Code Mode: the scripted model's "code <script>" cue calls `codemode` with the script.
@Suite("Code Mode inside JavaScriptCore", .serialized)
struct CodeModeTests {
    private static let due = #"{dueBefore: "2030-01-01T00:00:00Z"}"#

    @Test("A script calls tools in parallel; only its output reaches the transcript", .timeLimit(.minutes(1)))
    func script() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        let script = """
        code const [a, b] = await Promise.all([tools.reminders_query(\(Self.due)), tools.reminders_query(\(Self.due))]);
        const titles = [...JSON.parse(a).reminders, ...JSON.parse(b).reminders].map((r) => r.title);
        text("found " + titles.length + ": " + titles.join(", "));
        """
        try await harness.perform("PiRuntime.send", [meta.id, script, "r1"])
        try await until(.seconds(30)) { !log.busy(meta.id) && log.last(meta.id, kind: "assistant") != nil }
        let results = log.items(meta.id).filter { $0["kind"] as? String == "toolResult" }
        #expect(results.map { $0["toolName"] as? String } == ["codemode"], "nested calls stay out of the transcript")
        let output = results.first?["text"] as? String ?? ""
        #expect(output.contains("found 2: Buy oat milk, Buy oat milk"), "output: \(output)")
        #expect(results.first?["isError"] as? Bool == false)
        #expect(log.calls("reminders.query") == 2)
        try await harness.close()
    }

    @Test("A script's gated call asks under the codemode call; a denial rejects inside the script", .timeLimit(.minutes(1)))
    func approvals() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        let script = """
        code try { await tools.calendar_create_event({title: "Dentist", start: "2030-01-01T15:00:00Z", end: "2030-01-01T16:00:00Z"}); text("created"); }
        catch (error) { text("refused: " + error.message); }
        """
        try await harness.perform("PiRuntime.send", [meta.id, script, "r1"])
        try await until(.seconds(30)) { log.approvals.count == 1 }
        let request = log.approvals[0]
        #expect(request["tool"] as? String == "calendar_create_event", "the approval names the script's tool")
        let call = log.items(meta.id).flatMap { ($0["toolCalls"] as? [[String: Any]]) ?? [] }.first { $0["name"] as? String == "codemode" }
        #expect(call != nil && request["callId"] as? String == call?["id"] as? String, "the transcript shows it on the codemode row")
        #expect(log.calls("calendar.createEvent") == 0)
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [request["id"] as! Int, "deny"])
        try await until(.seconds(30)) { !log.busy(meta.id) && log.last(meta.id, kind: "assistant") != nil }
        let output = log.last(meta.id, kind: "toolResult")?["text"] as? String ?? ""
        #expect(output.contains("refused: Tool call blocked: The user declined this action."), "output: \(output)")
        #expect(log.calls("calendar.createEvent") == 0)
        try await harness.close()
    }

    @Test("A script a crash interrupts resumes without running its finished calls again", .timeLimit(.minutes(1)))
    func resume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("chat.sqlite").path
        let script = """
        code const before = JSON.parse(await tools.reminders_query(\(Self.due))).reminders.length;
        await tools.calendar_create_event({title: "Dentist", start: "2030-01-01T15:00:00Z", end: "2030-01-01T16:00:00Z"});
        text("reminders " + before + ", event created");
        """

        let firstLog = ChatLog()
        let first = try await openChat(firstLog, db: db)
        let meta: Meta = try await first.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await first.perform("PiRuntime.send", [meta.id, script, "r1"])
        try await until(.seconds(30)) { firstLog.approvals.count == 1 }
        #expect(firstLog.calls("reminders.query") == 1)
        first.runtime.terminate()

        let log = ChatLog()
        let second = try await openChat(log, db: db)
        try await second.perform("PiRuntime.watchConversation", [meta.id])
        try await until(.seconds(30)) { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "calendar_create_event")
        let _: Bool = try await second.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until(.seconds(30)) { !log.busy(meta.id) && log.last(meta.id, kind: "assistant") != nil }
        let output = log.last(meta.id, kind: "toolResult")?["text"] as? String ?? ""
        #expect(output.contains("reminders 1, event created"), "output: \(output)")
        #expect(log.calls("reminders.query") == 0, "the replay hands the script the journaled result")
        #expect(log.calls("calendar.createEvent") == 1)
        try await second.close()
    }
}
