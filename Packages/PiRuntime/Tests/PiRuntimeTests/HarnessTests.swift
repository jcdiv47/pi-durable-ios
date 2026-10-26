import Foundation
import Testing
@testable import PiRuntime

/// Collects JS events (markers, agent events) for assertions.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []

    func append(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        lock.withLock { events.append(object) }
    }

    func markers(_ tool: String, _ event: String) -> Int {
        lock.withLock { events.filter { $0["type"] as? String == "marker" && $0["tool"] as? String == tool && $0["event"] as? String == event }.count }
    }
}

func loadHarness(_ log: EventLog) async throws -> PiHarness {
    let (_, url) = try bundledScript("pi-runtime")
    return try await PiHarness.load(bundle: url, options: .init(
        onEvent: { log.append($0) },
        onLog: { level, message in if level == "error" || level == "warn" { print("[js \(level)] \(message)") } }
    ))
}

@Suite("Harness inside JavaScriptCore")
struct HarnessTests {
    @Test("A scripted run with two tools completes on SQLite storage", .timeLimit(.minutes(1)))
    func scriptedRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EventLog()
        let harness = try await loadHarness(log)
        print("bundle evaluate: \(Int(harness.evaluateMs)) ms")
        let opened = try await harness.open(.init(dbPath: directory.appendingPathComponent("s.sqlite").path, provider: "faux", modelId: "killtest", toolMs: 20))
        print("open: \(Int(opened.openMs)) ms")
        let answer = try await harness.ask("go", requestId: "r1")
        #expect(answer.status == "done")
        #expect(answer.text == "Done: slow_lookup=ok, send_message=ok")
        let before = try await harness.runtime.callAsync("PiRuntime.entries")
        let again = try await harness.settle("go", requestId: "r1")
        let after = try await harness.runtime.callAsync("PiRuntime.entries")
        #expect(again.status == "done")
        #expect(before == after, "a repeated requestId must not submit again")
        try await harness.close()
    }

    @Test("After an abrupt stop mid-tool, a new runtime reruns the safe tool and interrupts the unsafe one", .timeLimit(.minutes(1)))
    func crashAndResume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("kill.sqlite").path
        print("kill db: \(db)")

        let firstLog = EventLog()
        let first = try await loadHarness(firstLog)
        _ = try await first.open(.init(dbPath: db, provider: "faux", modelId: "killtest", toolMs: 5000))
        try await first.submit("go", requestId: "kill-1")
        for _ in 0..<200 where firstLog.markers("slow_lookup", "start") == 0 || firstLog.markers("send_message", "start") == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(firstLog.markers("slow_lookup", "start") == 1)
        #expect(firstLog.markers("send_message", "start") == 1)
        first.runtime.terminate()

        let secondLog = EventLog()
        let second = try await loadHarness(secondLog)
        _ = try await second.open(.init(dbPath: db, provider: "faux", modelId: "killtest", toolMs: 20))
        let settled = try await second.settle("go", requestId: "kill-1")
        print("settled: \(settled)")
        #expect(settled.status == "done")
        #expect(secondLog.markers("slow_lookup", "start") == 1, "replay-safe tool reruns")
        #expect(secondLog.markers("send_message", "start") == 0, "non-replay-safe tool does not rerun")
        let lookup = settled.toolResults.first { $0.tool == "slow_lookup" }
        let send = settled.toolResults.first { $0.tool == "send_message" }
        #expect(lookup?.isError == false)
        #expect(send?.isError == true)
        #expect(settled.answer == "Done: slow_lookup=ok, send_message=error")
        try await second.close()
    }
}
