import Foundation
import Observation
import os
import PiRuntime
import PiUI

@MainActor
@Observable
final class AppModel {
    let mode = LaunchMode.current
    let modelId = UserDefaults.standard.string(forKey: "PiModel") ?? "claude-sonnet-5-5"
    let keys = KeychainKeys()

    var status = "Starting…"
    var ready = false
    var busy = false
    var hasKey = false
    var streamed = ""
    var lastResult: String?

    /// Kept alive for the life of the process (the kill test waits here to be terminated).
    private(set) var harness: PiHarness?
    private let launchedAt = ProcessMetrics.msSinceProcessStart()

    nonisolated static let logger = Logger(subsystem: "dev.pi.durable", category: "app")

    static var bundleURL: URL {
        get throws {
            guard let url = Bundle.main.url(forResource: "pi-runtime", withExtension: "js") else {
                throw JSRuntimeError("pi-runtime.js is missing from the app bundle; run `bun build.ts` in js/")
            }
            return url
        }
    }

    func start() async {
        for name in mode.reports + ["\(mode.rawValue)-error.json"] {
            try? FileManager.default.removeItem(at: M0Files.url(name))
        }
        importKeyIfRequested()
        hasKey = keys.hasKey(for: "anthropic")
        do {
            switch mode {
            case .chat: try await openChat()
            case .capabilities: try await M0Runner.capabilities(self)
            case .conformance: try await M0Runner.conformance(self)
            case .killTestStart: try await M0Runner.killTestStart(self)
            case .killTestResume: try await M0Runner.killTestResume(self)
            case .measure: try await M0Runner.measure(self, launchedAtMs: launchedAt)
            }
        } catch {
            status = "Failed: \(error)"
            Self.logger.error("\(self.mode.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            try? M0Files.writeJSON("\(mode.rawValue)-error.json", ["error": String(describing: error)])
        }
    }

    func adopt(_ harness: PiHarness) { self.harness = harness }

    // MARK: Chat (the bare streaming view)

    private func openChat() async throws {
        let directory = try SharedContainer.directory("pi")
        let harness = try await PiHarness.load(bundle: Self.bundleURL, options: .init(
            keys: keys,
            onEvent: { [weak self] json in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(json) } }
            },
            onLog: Self.forwardLog
        ))
        let opened = try await harness.open(.init(
            dbPath: directory.appendingPathComponent("session.sqlite").path,
            provider: "anthropic",
            modelId: modelId,
            keyedProviders: ["anthropic"]
        ))
        self.harness = harness
        ready = true
        status = "Ready · \(modelId) · open \(Int(opened.openMs)) ms"
        if let prompt = UserDefaults.standard.string(forKey: "PiPrompt") { await send(prompt) }
    }

    func send(_ prompt: String) async {
        guard let harness, !busy else { return }
        busy = true
        streamed = ""
        lastResult = nil
        defer { busy = false }
        do {
            let json = try await harness.runtime.callAsync("PiRuntime.ask", [prompt, UUID().uuidString])
            let result = try JSONDecoder().decode(PiHarness.AskResult.self, from: Data(json.utf8))
            if let text = result.text, result.status == "done" { streamed = text }
            lastResult = [
                "status \(result.status)",
                result.firstDeltaMs.map { "first delta \(Int($0)) ms" },
                result.outputTokens.map { "\($0) output tokens" },
                result.msPerToken.map { String(format: "%.1f ms/token", $0) },
                "total \(Int(result.totalMs)) ms",
            ].compactMap(\.self).joined(separator: " · ")
            try? Data(json.utf8).write(to: M0Files.url("stream.json"), options: .atomic)
        } catch {
            lastResult = "Error: \(error)"
        }
    }

    private func handle(_ json: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        if event["type"] as? String == "delta", let text = event["text"] as? String { streamed += text }
    }

    // MARK: Keys

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keys.setKey(trimmed, for: "anthropic")
            hasKey = true
        } catch {
            status = "Could not save key: \(error)"
        }
    }

    func removeKey() {
        try? keys.removeKey(for: "anthropic")
        hasKey = false
    }

    /// Debug builds only: `PI_ANTHROPIC_KEY_FILE=<path>` (simulator: `SIMCTL_CHILD_PI_ANTHROPIC_KEY_FILE`)
    /// moves a key from a file on the Mac into the Keychain, so scripts never pass it as an argument.
    private func importKeyIfRequested() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["PI_ANTHROPIC_KEY_FILE"],
              let key = try? String(contentsOfFile: path, encoding: .utf8)
        else { return }
        saveKey(key)
        Self.logger.info("Imported the Anthropic key into the Keychain")
        #endif
    }

    nonisolated static func forwardLog(_ level: String, _ message: String) {
        switch level {
        case "error": logger.error("js: \(message, privacy: .public)")
        case "warn": logger.warning("js: \(message, privacy: .public)")
        default: logger.debug("js: \(message, privacy: .public)")
        }
    }
}
