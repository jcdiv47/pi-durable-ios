import Foundation
import FoundationModels

/// Explicit diagnostic only: attempts generation even when the public availability check says no.
/// Uses synthetic prompts, never conversation data or Pi storage.
@MainActor
enum IntelligenceProbe {
    static func run(_ app: AppModel) async throws {
        var report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "preferredLanguages": Locale.preferredLanguages,
            "availabilityBefore": String(describing: SystemLanguageModel.default.availability),
            "state": "running",
        ]
        var attempts: [[String: Any]] = []
        try M0Files.writeJSON("intelligence-probe.json", report)
        for (label, prompt) in [("english", "Reply with just the word Hello."),
                                 ("chinese", "请只回复：你好")] {
            app.status = "Testing Foundation Models: \(label)"
            let model = SystemLanguageModel(useCase: .general)
            var attempt: [String: Any] = [
                "label": label,
                "availability": String(describing: model.availability),
            ]
            let start = Date()
            do {
                let session = LanguageModelSession(model: model)
                let response = try await session.respond(
                    to: prompt, options: GenerationOptions(maximumResponseTokens: 32)
                )
                attempt["response"] = response.content
                attempt["success"] = true
            } catch {
                let nsError = error as NSError
                attempt["success"] = false
                attempt["errorType"] = String(reflecting: type(of: error))
                attempt["error"] = String(reflecting: error)
                attempt["localizedDescription"] = nsError.localizedDescription
                attempt["domain"] = nsError.domain
                attempt["code"] = nsError.code
            }
            attempt["elapsedSeconds"] = Date().timeIntervalSince(start)
            attempts.append(attempt)
            report["attempts"] = attempts
            try M0Files.writeJSON("intelligence-probe.json", report)
        }
        report["availabilityAfter"] = String(describing: SystemLanguageModel.default.availability)
        report["state"] = "complete"
        try M0Files.writeJSON("intelligence-probe.json", report)
        app.status = "Foundation Models probe complete"
    }
}
