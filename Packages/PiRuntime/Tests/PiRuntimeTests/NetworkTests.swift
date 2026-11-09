import Foundation
import os
import Testing
@testable import PiRuntime

/// What `NWPathMonitor` says (`path`) and whether anything answers (`internet`), set by the test. A VPN tunnel in
/// Airplane Mode is a path without internet.
final class FakeNetwork: NetworkStatus {
    private let state: OSAllocatedUnfairLock<(path: Bool, internet: Bool)>
    init(path: Bool, internet: Bool) { state = OSAllocatedUnfairLock(initialState: (path, internet)) }
    var online: Bool { state.withLock { $0.path } }
    var internet: Bool { state.withLock { $0.internet } }
    func set(path: Bool, internet: Bool) { state.withLock { $0 = (path, internet) } }
}

/// Apple's connectivity check (`probeUrl` in network.ts): answers while the fake has internet.
struct FakeProbe: LocalHTTPService {
    let network: FakeNetwork
    func respond(to request: LocalHTTPRequest, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async {
        guard network.internet else { return send(.error("A TLS error caused the secure connection to fail.")) }
        send(.response(status: 200, headers: [:]))
        send(.end)
    }
}

/// An OpenAI-compatible endpoint on Apple Intelligence's local host that fails as URLSession does without internet,
/// or for its first `failures` requests, and otherwise echoes the last message. Probes (HEAD) get an empty 200.
final class FlakyModelService: LocalHTTPService, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failures: Int
    let network: FakeNetwork

    init(network: FakeNetwork, failures: Int = 0) {
        self.network = network
        self.failures = failures
    }

    /// Model requests (POST), not probes.
    var requests: Int { lock.withLock { count } }

    func respond(to request: LocalHTTPRequest, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async {
        guard network.internet else { return send(.error("The Internet connection appears to be offline.")) }
        if request.method == "HEAD" {
            send(.response(status: 200, headers: [:]))
            return send(.end)
        }
        let fail = lock.withLock {
            count += 1
            guard failures > 0 else { return false }
            failures -= 1
            return true
        }
        if fail { return send(.error("The network connection was lost.")) }
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
            localHosts: [AppleIntelligence.host: service, "www.apple.com": FakeProbe(network: service.network)],
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

    @Test("Offline, a request waits without failing, and is sent again once the network is back", .timeLimit(.minutes(1)), arguments: [false, true])
    func waitsForNetwork(vpn: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        // With a VPN up, Airplane Mode leaves a network path on which nothing answers.
        let service = FlakyModelService(network: FakeNetwork(path: vpn, internet: false))
        let harness = try await open(log, service: service, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["apple", "on-device"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello", "r1"])

        try await until { log.networkWaits.last == 1 }
        // A few polls later: still one request, still busy, nothing committed as a failed attempt.
        try await Task.sleep(for: .seconds(3))
        #expect(service.requests == 0, "no request got through")
        #expect(log.busy(meta.id))
        #expect(errors(log, meta.id).isEmpty)

        service.network.set(path: true, internet: true)
        try await until { log.last(meta.id, kind: "assistant")?["text"] as? String == "Echo: hello" && !log.busy(meta.id) }
        #expect(service.requests == 1)
        #expect(log.networkWaits == [1, 0])
        #expect(errors(log, meta.id).isEmpty)
        try await harness.close()
    }

    @Test("Online, a transport failure goes to Pi's retry as before", .timeLimit(.minutes(1)))
    func onlineFailureRetries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let service = FlakyModelService(network: FakeNetwork(path: true, internet: true), failures: 1)
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
        let service = FlakyModelService(network: FakeNetwork(path: false, internet: false))
        let harness = try await open(log, service: service, db: directory.appendingPathComponent("chat.sqlite").path)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["apple", "on-device"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello", "r1"])
        try await until { log.networkWaits.last == 1 }

        try await harness.perform("PiRuntime.abort", [meta.id])
        try await until { !log.busy(meta.id) && log.networkWaits.last == 0 }
        #expect(service.requests == 0)
        try await harness.close()
    }
}
