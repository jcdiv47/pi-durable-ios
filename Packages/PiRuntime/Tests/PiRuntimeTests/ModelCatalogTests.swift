import Foundation
import os
import Testing
@testable import PiRuntime

/// pi.dev's model list endpoint (`js/src/app/catalog.ts`): DeepSeek's list with one new model the app can use and
/// one on another endpoint it can't, newer than pi-ai's built-in lists. Answers 304 to its own ETag.
final class FakeCatalog: LocalHTTPService, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(path: String, etag: String?)] = []

    var requests: [(path: String, etag: String?)] { lock.withLock { log } }

    static let body = Data("""
    [
      {"id":"deepseek-next","name":"DeepSeek Next","api":"openai-completions","baseUrl":"https://api.deepseek.com",
       "provider":"deepseek","reasoning":false,"input":["text"],"cost":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0},
       "contextWindow":128000,"maxTokens":8192,"type":"chat"},
      {"id":"deepseek-elsewhere","name":"Elsewhere","api":"openai-completions","baseUrl":"https://example.com/v1",
       "provider":"deepseek","reasoning":false,"input":["text"],"cost":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0},
       "contextWindow":128000,"maxTokens":8192,"type":"chat"}
    ]
    """.utf8)

    func respond(to request: LocalHTTPRequest, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async {
        let etag = request.headers.first { $0.0.lowercased() == "if-none-match" }?.1
        lock.withLock { log.append((request.url.path, etag)) }
        guard request.url.path == "/api/models/providers/deepseek" else {
            send(.response(status: 404, headers: [:]))
            return send(.end)
        }
        if etag == "\"v1\"" {
            send(.response(status: 304, headers: [:]))
            return send(.end)
        }
        let lastModified = Date().formatted(Date.HTTPFormatStyle())
        send(.response(status: 200, headers: ["content-type": "application/json", "etag": "\"v1\"", "last-modified": lastModified]))
        send(.chunk(Self.body))
        send(.end)
    }
}

private struct ModelRow: Decodable { let provider: String; let id: String }

@Suite("Model lists from pi.dev", .serialized)
struct ModelCatalogTests {
    private func open(_ catalog: FakeCatalog, saved: String?, db: String, events: @escaping @Sendable (String) -> Void) async throws -> PiHarness {
        let (_, url) = try bundledScript("pi-runtime")
        let harness = try await PiHarness.load(bundle: url, options: .init(
            onEvent: events,
            onLog: { level, message in if level == "error" || level == "warn" { print("[js \(level)] \(message)") } },
            hostCall: { name, _ in throw JSRuntimeError("unexpected host call \(name)") },
            localHosts: ["pi.dev": catalog],
            network: FakeNetwork(path: true, internet: true)
        ))
        _ = try await harness.open(.init(dbPath: db, provider: "faux", modelId: "killtest", keyedProviders: ["deepseek"], modelCatalogs: saved))
        return harness
    }

    @Test("A newer list adds the models the app can send, is saved, and comes back at the next launch without a request", .timeLimit(.minutes(1)))
    func refresh() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("chat.sqlite").path
        let saved = OSAllocatedUnfairLock<String?>(initialState: nil)
        let onEvent: @Sendable (String) -> Void = { json in
            guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  event["type"] as? String == "modelCatalogs" else { return }
            let json = event["json"] as? String
            saved.withLock { $0 = json }
        }

        // First launch: only the keyed provider's list is asked for, and saved.
        let catalog = FakeCatalog()
        var harness = try await open(catalog, saved: nil, db: db, events: onEvent)
        try await until { saved.withLock { $0 } != nil }
        #expect(catalog.requests.map(\.path) == ["/api/models/providers/deepseek"])
        var models: [ModelRow] = try await harness.call("PiRuntime.models")
        let deepseek = Set(models.filter { $0.provider == "deepseek" }.map(\.id))
        #expect(deepseek.contains("deepseek-next"))
        #expect(deepseek.contains("deepseek-flash"))
        #expect(!deepseek.contains("deepseek-elsewhere"))
        try await harness.close()

        // Next launch within the interval: the saved list, and no request.
        let again = FakeCatalog()
        harness = try await open(again, saved: saved.withLock { $0 }, db: db, events: onEvent)
        models = try await harness.call("PiRuntime.models")
        #expect(models.contains { $0.provider == "deepseek" && $0.id == "deepseek-next" })
        try await Task.sleep(for: .milliseconds(200))
        #expect(again.requests.isEmpty)

        // Settings' refresh asks anyway, revalidating with the saved ETag; a 304 keeps the list.
        let failed: [String: String] = try await harness.call("PiRuntime.refreshModelCatalogs")
        #expect(failed.isEmpty)
        #expect(again.requests.map(\.etag) == ["\"v1\""])
        models = try await harness.call("PiRuntime.models")
        #expect(models.contains { $0.provider == "deepseek" && $0.id == "deepseek-next" })
        try await harness.close()
    }
}
