import AppIntents
import Foundation
import PiUI

// App Intents that both PiApp and PiWidgets compile: the widget's buttons and the Live Activity's Approve / Stop.
// They are `LiveActivityIntent`s, which iOS performs in the app's process (launching it in the background if
// needed), because only PiApp may open Pi storage. The app installs `SharedIntents.perform` at launch; should an
// intent ever run where it is missing (the widget's process), the request waits in the App Group for the app.

/// One request from a widget or Live Activity button.
enum SharedIntentRequest: Codable, Sendable, Hashable {
    /// `actionId` names the action in the published spec (`SurfaceSpec.action(_:)`); `renderedAt` is the widget
    /// timeline entry it was tapped on.
    case widgetAction(publishedId: String, actionId: String, renderedAt: Date)
    case answerApproval(id: Int, allow: Bool)
    case stopRun(conversationId: Int)
    /// Talk to Pi (`TalkToPiIntent`): starts a voice session, or ends the one going, as a second press of the
    /// Action button should.
    case toggleVoice
    /// End on the voice Live Activity.
    case endVoice

    /// Entry points carry a request ID derived from the invocation and its payload (spec "Durability on iOS"):
    /// the same tap on the same timeline entry is one request, however often iOS delivers it.
    var requestId: String {
        switch self {
        case let .widgetAction(publishedId, actionId, renderedAt): "widget:\(publishedId):\(actionId):\(Int(renderedAt.timeIntervalSince1970))"
        case let .answerApproval(id, allow): "approval:\(id):\(allow ? "allow" : "deny")"
        case let .stopRun(conversationId): "stop:\(conversationId)"
        // A voice session's requests carry their own IDs (`RealtimeVoice`); starting while one runs ends it.
        case .toggleVoice: "voice:toggle"
        case .endVoice: "voice:end"
        }
    }
}

enum SharedIntents {
    /// Set by PiApp at launch.
    @MainActor static var perform: ((SharedIntentRequest) async throws -> Void)?

    @MainActor static func run(_ request: SharedIntentRequest) async throws {
        if let perform { return try await perform(request) }
        switch request {
        // Listening later, when the app next opens, would surprise; ending a session that is not running is nothing.
        case .toggleVoice: throw SharedIntentError("Open Pi, then try again.")
        case .endVoice: return
        default: PendingIntents.append(request)
        }
    }
}

struct SharedIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Requests an intent could not hand to the app, kept in the App Group until PiApp drains them.
enum PendingIntents {
    static var url: URL? { SharedContainer.url?.appendingPathComponent("inbox/intents.json") }

    static func append(_ request: SharedIntentRequest) {
        guard let url else { return }
        var list = read()
        list.append(request)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: url, options: .atomic)
    }

    /// Returns and removes the waiting requests.
    static func drain() -> [SharedIntentRequest] {
        let list = read()
        if let url, !list.isEmpty { try? FileManager.default.removeItem(at: url) }
        return list
    }

    static func read() -> [SharedIntentRequest] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SharedIntentRequest].self, from: data)) ?? []
    }
}

/// `RunWidgetAction(surfaceId, actionId)`: a button or checklist row in a Pi widget.
struct RunWidgetActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run Widget Action"
    static let description = IntentDescription("Runs a button of a Pi widget.")
    static let isDiscoverable = false

    @Parameter(title: "Surface") var publishedId: String
    @Parameter(title: "Action") var actionId: String
    @Parameter(title: "Rendered At") var renderedAt: Date

    init() {}

    init(publishedId: String, actionId: String, renderedAt: Date) {
        self.publishedId = publishedId
        self.actionId = actionId
        self.renderedAt = renderedAt
    }

    @MainActor func perform() async throws -> some IntentResult {
        try await SharedIntents.run(.widgetAction(publishedId: publishedId, actionId: actionId, renderedAt: renderedAt))
        return .result()
    }
}

/// Allow or Deny on the run's Live Activity.
struct AnswerApprovalIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Pi Approval"
    static let isDiscoverable = false

    @Parameter(title: "Approval") var approvalId: Int
    @Parameter(title: "Allow") var allow: Bool

    init() {}

    init(approvalId: Int, allow: Bool) {
        self.approvalId = approvalId
        self.allow = allow
    }

    @MainActor func perform() async throws -> some IntentResult {
        try await SharedIntents.run(.answerApproval(id: approvalId, allow: allow))
        return .result()
    }
}

/// Stop on the run's Live Activity.
struct StopRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Pi"
    static let isDiscoverable = false

    @Parameter(title: "Conversation") var conversationId: Int

    init() {}

    init(conversationId: Int) {
        self.conversationId = conversationId
    }

    @MainActor func perform() async throws -> some IntentResult {
        try await SharedIntents.run(.stopRun(conversationId: conversationId))
        return .result()
    }
}

/// Talk to Pi: the Action button, a Control Center or Lock Screen control, Siri or a shortcut. Starts listening without
/// opening the app (an `AudioRecordingIntent` may record in the background while the voice Live Activity shows), or
/// hangs up when a session is going. iOS performs it in the app's process.
struct TalkToPiIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Talk to Pi"
    static let description = IntentDescription("Talk with Pi hands-free. Pi listens, does what you ask and answers aloud. Run it again to hang up.")

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        try await SharedIntents.run(.toggleVoice)
        return .result()
    }
}

/// End on the voice Live Activity.
struct EndVoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Talking to Pi"
    static let isDiscoverable = false

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        try await SharedIntents.run(.endVoice)
        return .result()
    }
}
