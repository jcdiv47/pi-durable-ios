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

    /// Entry points carry a request ID derived from the invocation and its payload (spec "Durability on iOS"):
    /// the same tap on the same timeline entry is one request, however often iOS delivers it.
    var requestId: String {
        switch self {
        case let .widgetAction(publishedId, actionId, renderedAt): "widget:\(publishedId):\(actionId):\(Int(renderedAt.timeIntervalSince1970))"
        case let .answerApproval(id, allow): "approval:\(id):\(allow ? "allow" : "deny")"
        case let .stopRun(conversationId): "stop:\(conversationId)"
        }
    }
}

enum SharedIntents {
    /// Set by PiApp at launch.
    @MainActor static var perform: ((SharedIntentRequest) async throws -> Void)?

    @MainActor static func run(_ request: SharedIntentRequest) async throws {
        if let perform { try await perform(request) } else { PendingIntents.append(request) }
    }
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
