import Foundation
import Testing
@testable import PiRuntime

@Suite("SSH tools inside JavaScriptCore", .serialized)
struct SSHChatTests {
    static func hosts(runWithoutAsking: Bool, ready: Bool = true) -> [[String: any Sendable]] {
        [[
            "id": "nas", "name": "NAS", "address": "me@nas.local", "shell": "fish", "enabled": true, "ready": ready,
            "needsVpn": true, "runWithoutAsking": runWithoutAsking,
        ]]
    }

    @Test("ssh_exec asks first; allowed, it runs once as a job named after its task", .timeLimit(.minutes(1)))
    func asks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        try await harness.perform("PiRuntime.setSshHosts", [Self.hosts(runWithoutAsking: false)])
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "ssh nas uname -a", "r1"])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "ssh_exec")
        let arguments = log.approvals[0]["arguments"] as? [String: Any]
        #expect(arguments?["host"] as? String == "nas" && arguments?["command"] as? String == "uname -a")
        #expect(log.calls("ssh.exec") == 0)
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        let call = try #require(log.arguments("ssh.exec").first)
        #expect(call["host"] as? String == "nas" && call["timeoutSeconds"] as? Int == 60)
        #expect((call["idempotencyKey"] as? String)?.hasPrefix("t") == true)
        let result = try #require(log.last(meta.id, kind: "toolResult"))
        #expect(result["isError"] as? Bool == false)
        let text = result["text"] as? String ?? ""
        #expect(text.contains("Exit code: 0") && text.contains("Linux nas") && text.contains("me@nas.local"), "\(text)")

        // ssh_job is a read: no approval.
        try await harness.perform("PiRuntime.send", [meta.id, "sshjob nas i1-t1", "r2"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 8 }
        #expect(log.approvals.isEmpty)
        let job = log.last(meta.id, kind: "toolResult")?["text"] as? String ?? ""
        #expect(job.contains("Still running") && job.contains("kill 42"), "\(job)")
        try await harness.close()
    }

    @Test("A host set to run without asking runs at once, until the conversation holds web results", .timeLimit(.minutes(1)))
    func runWithoutAsking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        try await harness.perform("PiRuntime.setSshHosts", [Self.hosts(runWithoutAsking: true)])
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "ssh nas uptime", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        #expect(log.calls("ssh.exec") == 1 && log.approvals.isEmpty)

        try await harness.perform("PiRuntime.setSearchProvider", ["scripted"])
        try await harness.perform("PiRuntime.send", [meta.id, "search pi durable", "r2"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 8 }
        try await harness.perform("PiRuntime.send", [meta.id, "ssh nas uptime", "r3"])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "ssh_exec", "web results in the conversation: ask again")
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "deny"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 12 }
        #expect(log.calls("ssh.exec") == 1)
        try await harness.close()
    }

    @Test("A script's ssh_exec asks even on a host that runs without asking, and so does any after a script", .timeLimit(.minutes(1)))
    func codeModeAsks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        try await harness.perform("PiRuntime.setSshHosts", [Self.hosts(runWithoutAsking: true)])
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, #"code await tools.ssh_exec({host: "nas", command: "uptime"})"#, "r1"])
        try await until(.seconds(30)) { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "ssh_exec", "what the script read is not in the transcript: ask")
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "deny"])
        try await until(.seconds(30)) { !log.busy(meta.id) && log.items(meta.id).count == 4 }

        try await harness.perform("PiRuntime.send", [meta.id, "ssh nas uptime", "r2"])
        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "ssh_exec", "a script's output in the conversation: ask")
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "deny"])
        try await until { !log.busy(meta.id) }
        #expect(log.calls("ssh.exec") == 0)
        try await harness.close()
    }

    @Test("Unknown and unready hosts fail without reaching Swift; the prompt lists ready hosts", .timeLimit(.minutes(1)))
    func hosts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openChat(log, db: directory.appendingPathComponent("chat.sqlite").path)
        try await harness.perform("PiRuntime.setSshHosts", [Self.hosts(runWithoutAsking: true, ready: false)])
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "section ssh", "r0"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 2 }
        #expect(log.last(meta.id, kind: "assistant")?["text"] as? String == "Section ssh: (none)")

        try await harness.perform("PiRuntime.send", [meta.id, "ssh nas ls", "r1"])
        try await until { log.approvals.count == 1 }
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 6 }
        let unready = log.last(meta.id, kind: "toolResult")
        #expect(unready?["isError"] as? Bool == true && (unready?["text"] as? String)?.contains("isn't set up yet") == true)
        #expect(log.calls("ssh.exec") == 0)

        try await harness.perform("PiRuntime.setSshHosts", [Self.hosts(runWithoutAsking: true)])
        try await harness.perform("PiRuntime.send", [meta.id, "section ssh", "r2"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 8 }
        let section = log.last(meta.id, kind: "assistant")?["text"] as? String ?? ""
        #expect(section.contains("- nas: NAS (me@nas.local, fish)"), "\(section)")
        try await harness.close()
    }
}
