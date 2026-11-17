import Foundation
import Testing
@testable import PiRuntime

struct ConformanceReport: Decodable {
    struct Case: Decodable {
        let name: String
        let ok: Bool
        let ms: Double
        let error: String?
    }

    let suite: String
    let passed: Int
    let failed: Int
    let totalMs: Double
    let cases: [Case]
}

func bundledScript(_ name: String) throws -> (String, URL) {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "JS"),
        "Missing \(name).js; run `bun js/build.ts` first"
    )
    return (try String(contentsOf: url, encoding: .utf8), url)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Evaluates the conformance bundle in a fresh runtime, runs one `PiConformance` suite, and records failures.
func runSuite(_ function: String, _ arguments: [any Sendable] = []) async throws -> ConformanceReport {
    let (source, url) = try bundledScript("pi-conformance")
    let runtime = JSRuntime(options: .init(onLog: { level, message in
        if level == "error" || level == "warn" { print("[js \(level)] \(message)") }
    }))
    try await runtime.evaluate(source, sourceURL: url)
    let json = try await runtime.callAsync("PiConformance.\(function)", arguments)
    let report = try JSONDecoder().decode(ConformanceReport.self, from: Data(json.utf8))
    for failure in report.cases where !failure.ok {
        Issue.record("\(failure.name): \(failure.error ?? "")")
    }
    print("\(report.suite): \(report.passed) passed, \(report.failed) failed in \(Int(report.totalMs)) ms")
    return report
}

@Suite("Runs inside JavaScriptCore")
struct ConformanceTests {
    @Test("Pi Durable storage conformance over the sqlite3 facade", .timeLimit(.minutes(5)))
    func storageConformance() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await runSuite("runStorage", [directory.path])
        #expect(report.failed == 0)
        #expect(report.passed == 32)
    }

    @Test("SqliteDatabase facade contract", .timeLimit(.minutes(1)))
    func facadeContract() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await runSuite("runFacade", [directory.path])
        #expect(report.failed == 0)
        #expect(report.passed > 0)
    }

    @Test("MCP client and extension against an in-memory server", .timeLimit(.minutes(1)))
    func mcp() async throws {
        let report = try await runSuite("runMcp")
        #expect(report.failed == 0)
        #expect(report.passed == 9)
    }

    @Test("HTTP endpoint tools: URLs, refusals, reads and writes, trust, responses", .timeLimit(.minutes(1)))
    func http() async throws {
        let report = try await runSuite("runHttp")
        #expect(report.failed == 0)
        #expect(report.passed == 7)
    }

    @Test("Host polyfills", .timeLimit(.minutes(1)))
    func polyfills() async throws {
        let report = try await runSuite("runPolyfills")
        #expect(report.failed == 0)
        #expect(report.passed > 0)
    }
}
