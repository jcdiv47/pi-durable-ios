import Foundation
import PiRuntime
import PiUI

/// Kill test for a model answer cut off mid-stream (scripts/stream-kill.sh). Phase 1 starts a long answer
/// in a chat conversation and logs how much text has been committed; the script kills the app once some
/// has. Phase 2 reopens the storage and checks that Pi resent the request and finished the turn.
/// `PI_MODEL` picks the model (`provider/modelId`, default the offline `scripted/assistant`).
@MainActor
enum StreamKill {
    static let requestId = "streamkill-1"

    static var model: (provider: String, modelId: String) {
        let parts = (ProcessInfo.processInfo.environment["PI_MODEL"] ?? "scripted/assistant").split(separator: "/", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    static var prompt: String {
        model.provider == "scripted"
            ? "slow"
            : "Count from 1 to 400 in English words, one number per line, with no other text."
    }

    static func database() throws -> URL {
        try SharedContainer.directory("pi").appendingPathComponent("streamkill.sqlite")
    }

    private static func open(_ appModel: AppModel, log: LineLog) async throws -> PiHarness {
        let keyed = ChatStore.providers.map(\.id).filter { appModel.keys.hasKey(for: $0) }
        let harness = try await PiHarness.load(bundle: AppModel.bundleURL, options: .init(
            keys: appModel.keys,
            onEvent: { json in
                // Frames are large; log only how far the streamed answer got.
                guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
                if event["type"] as? String == "frame", let frame = event["frame"] as? [String: Any], let live = frame["live"] as? [String: Any] {
                    let chars = ((live["generation"] as? [String: Any])?["text"] as? String)?.count ?? 0
                    log.append(#"{"type":"progress","busy":\#(live["busy"] as? Bool ?? false),"chars":\#(chars)}"#)
                } else if event["type"] as? String == "report" {
                    log.append(json)
                }
            },
            onLog: AppModel.forwardLog
        ))
        _ = try await harness.open(.init(dbPath: try database().path, provider: model.provider, modelId: model.modelId, keyedProviders: keyed))
        appModel.adopt(harness)
        return harness
    }

    struct Meta: Decodable { let id: Int }

    static func start(_ appModel: AppModel) async throws {
        M0Files.removeDatabase(try database())
        let log = try LineLog(M0Files.url("streamkill-start.jsonl"))
        log.append(#"{"type":"launched","runId":"\#(M0Files.runId)"}"#)
        let harness = try await open(appModel, log: log)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", [model.provider, model.modelId])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, prompt, requestId])
        log.append(#"{"type":"submitted","conversationId":\#(meta.id)}"#)
        appModel.status = "Stream kill test: answer streaming; waiting to be terminated."
    }

    struct Transcript: Decodable {
        struct Item: Decodable {
            let kind: String
            let text: String?
            let stopReason: String?
            let error: String?
        }

        struct Live: Decodable { let busy: Bool }

        let items: [Item]
        let live: Live
    }

    static func resume(_ appModel: AppModel) async throws {
        guard FileManager.default.fileExists(atPath: try database().path) else {
            throw JSRuntimeError("No stream-kill database; run -PiMode streamkill-start first")
        }
        let log = try LineLog(M0Files.url("streamkill-resume.jsonl"))
        let started = ContinuousClock.now
        let harness = try await open(appModel, log: log)
        appModel.status = "Stream kill test: resuming…"
        let conversations: [Meta] = try await harness.call("PiRuntime.conversations")
        guard let id = conversations.first?.id else { throw JSRuntimeError("The killed run left no conversation") }
        // Re-sending the same requestId finds the admitted message instead of sending it again.
        try await harness.perform("PiRuntime.send", [id, prompt, requestId])
        var transcript: Transcript = try await harness.call("PiRuntime.transcript", [id])
        while transcript.live.busy || transcript.items.last?.kind != "assistant" {
            guard ContinuousClock.now - started < .seconds(240) else { throw JSRuntimeError("The resumed turn did not finish in 240 s") }
            try await Task.sleep(for: .milliseconds(250))
            transcript = try await harness.call("PiRuntime.transcript", [id])
        }
        let answers = transcript.items.filter { $0.kind == "assistant" }
        let final = answers.last
        let checks: [String: Bool] = [
            "one user message (requestId deduplicated)": transcript.items.filter { $0.kind == "user" }.count == 1,
            "turn finished with a complete answer": final?.stopReason == "stop",
            "answer is not empty": (final?.text?.count ?? 0) > 0,
        ]
        let pass = checks.values.allSatisfy(\.self)
        try M0Files.writeJSON("streamkill-result.json", [
            "pass": pass,
            "checks": checks,
            "model": "\(model.provider)/\(model.modelId)",
            "resumeMs": (ContinuousClock.now - started).milliseconds,
            "entries": transcript.items.map(\.kind),
            "assistantStopReasons": answers.map { $0.stopReason ?? "?" },
            "answerChars": final?.text?.count ?? 0,
            "answerHead": String((final?.text ?? "").prefix(120)),
            "errors": answers.compactMap(\.error),
        ])
        appModel.status = pass ? "Stream kill test passed" : "Stream kill test FAILED: \(checks.filter { !$0.value }.keys.sorted())"
    }
}
