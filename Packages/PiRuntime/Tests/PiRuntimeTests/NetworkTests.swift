import Foundation
import os
import Testing
@testable import PiRuntime

/// A network path the test turns on and off.
final class FakeNetwork: NetworkStatus {
    private let state: OSAllocatedUnfairLock<Bool>
    init(online: Bool) { state = OSAllocatedUnfairLock(initialState: online) }
    var online: Bool { state.withLock { $0 } }
    func set(online: Bool) { state.withLock { $0 = online } }
}

/// An OpenAI-compatible endpoint on Apple Intelligence's local host that fails as URLSession does without a network
/// while `network` is offline, or for its first `failures` requests, and otherwise echoes the last message.
final class FlakyModelService: LocalHTTPService, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failures: Int
    let network: FakeNetwork

    init(network: FakeNetwork, failures: Int = 0) {
        self.network = network
        self.failures = failures
    }

    var requests: Int { lock.withLock { count } }

    func respond(to request: LocalHTTPRequest, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async {
        let fail = lock.withLock {
            count += 1
            guard failures > 0 else { return false }
            failures -= 1
            return true
        }
        if fail || !network.online {
            send(.error("The Internet connection appears to be offline."))
            return
        }
        let chat = try! AppleChat.Request(body: request.body ?? Data())
        send(.response(status: 200, headers: ["content-type": "text/event-stream"]))
        send(.chunk(AppleChat.sse(id: "c1", model: chat.model, created: 0, delta: "", role: true)))
        send(.chunk(AppleChat.sse(id: "c1", model: chat.model, created: 0, delta: "Echo: \(chat.turns.last?.text ?? "")")))
        send(.chunk(AppleChat.sse(id: "c1", model: chat.model, created: 0, finish: "stop")))
        send(.chunk(Data("data: [DONE]\n\n".utf8)))
        send(.end)
    }
}

@Suite("Model requests while the phone is offline", .serialized)
struct NetworkTests {
    private func open(_ log: ChatLog, service: FlakyModelService, db: String) async throws -> PiHarness {
        let (_, url) = try bundledScript("pi-runtime")
        let harness = try await PiHarness.load(bundle: url, options: .init(
            onEvent: { log.handle($0) },
            onLog: { level, message in if level == "error" { print("[js \(level)] \(message)") } },
            hostCall: { name, json in
                log.record(name, json)
                throw JSRuntimeError("unexpected host call \(name)")
            },
            localHosts: [AppleIntelligence.host: service],
            network: service.network
        ))
        _ = try await harness.open(.init(
            dbPath: db, provider: "faux", modelId: "killtest",
            appleModels: [AppleIntelligence.Model(id: "on-device", name: "Apple Intelligence (on device)", contextWindow: 4096, maxTokens: 1024)]
        ))
        return harness
    }

    private func errors(_ log: ChatLog, _ id: Int) -> [[String: Any]] {
        log.items(id).filter { $0["kind"] as? String == "assistant" && $0["stopReason"] as? String == "error" }
    }

    @Test("Offline, a request waits without failing, and is sent again once the network is back", .timeLimit(.minutes(1)))
    func waitsForNetwork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let service = FlakyModelService(network: FakeNetwork(online: false))
        let harness = try await open(log, service: service, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["apple", "on-device"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello", "r1"])

        try await until { log.networkWaits.last == 1 }
        // A few polls later: still one request, still busy, nothing committed as a failed attempt.
        try await Task.sleep(for: .seconds(3))
        #expect(service.requests == 1)
        #expect(log.busy(meta.id))
        #expect(errors(log, meta.id).isEmpty)

        service.network.set(online: true)
        try await until { log.last(meta.id, kind: "assistant")?["text"] as? String == "Echo: hello" && !log.busy(meta.id) }
        #expect(service.requests == 2)
        #expect(log.networkWaits == [1, 0])
        #expect(errors(log, meta.id).isEmpty)
        try await harness.close()
    }

    @Test("Online, a transport failure goes to Pi's retry as before", .timeLimit(.minutes(1)))
    func onlineFailureRetries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let service = FlakyModelService(network: FakeNetwork(online: true), failures: 1)
        let harness = try await open(log, service: service, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["apple", "on-device"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello", "r1"])

        try await until(.seconds(30)) { log.last(meta.id, kind: "assistant")?["text"] as? String == "Echo: hello" && !log.busy(meta.id) }
        #expect(service.requests == 2)
        #expect(errors(log, meta.id).count == 1, "the failed attempt is in the transcript")
        #expect(log.networkWaits.isEmpty)
        try await harness.close()
    }

    @Test("Stop ends a run that waits for the network", .timeLimit(.minutes(1)))
    func stopWhileWaiting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let service = FlakyModelService(network: FakeNetwork(online: false))
        let harness = try await open(log, service: service, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["apple", "on-device"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello", "r1"])
        try await until { log.networkWaits.last == 1 }

        try await harness.perform("PiRuntime.abort", [meta.id])
        try await until { !log.busy(meta.id) && log.networkWaits.last == 0 }
        #expect(service.requests == 1)
        try await harness.close()
    }
}
