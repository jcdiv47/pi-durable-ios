import AppIntents
import CryptoKit
import Foundation
import PiUI
import SwiftUI

// App Intents, Siri phrases and snippets (spec "Apple integrations"). They are declared in the app target, so they run
// in PiApp's process, launched in the background when needed; that process is the only one that opens Pi storage.

/// Request IDs for intents (spec: "derive the id from the intent invocation and payload"). App Intents expose no
/// invocation ID, so it is the intent, its payload and the minute it ran in: Siri or Shortcuts delivering the same
/// request twice finds the first submission instead of asking twice.
enum IntentRequest {
    static func id(_ intent: String, _ payload: String...) -> String {
        let digest = SHA256.hash(data: Data(payload.joined(separator: "\u{1F}").utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "intent:\(intent):\(hex):\(Int(Date.now.timeIntervalSince1970 / 60))"
    }
}

// MARK: Entities

struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pi Conversation"
    static let defaultQuery = ConversationQuery()

    let id: Int
    let title: String
    let updatedAt: Date
    /// The messages' text, for Spotlight (`SpotlightIndex`); nil elsewhere.
    var text: String?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ meta: ConversationMeta) {
        id = meta.id
        title = meta.title
        updatedAt = Date(timeIntervalSince1970: meta.updatedAt / 1000)
    }
}

struct ConversationQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [Int]) async throws -> [ConversationEntity] {
        await ChatStore.ready().conversations.filter { identifiers.contains($0.id) }.map(ConversationEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ConversationEntity] {
        await ChatStore.ready().startedConversations.prefix(12).map(ConversationEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [ConversationEntity] {
        await ChatStore.ready().startedConversations.filter { $0.title.localizedCaseInsensitiveContains(string) }.map(ConversationEntity.init)
    }
}

struct ScheduleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pi Task"
    static let defaultQuery = ScheduleQuery()

    /// The task's name; `RunPiTask` runs the newest schedule with it.
    let id: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct ScheduleQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ScheduleEntity] {
        let names = Set(await ChatStore.ready().scheduleList().map(\.name))
        return identifiers.filter(names.contains).map(ScheduleEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ScheduleEntity] {
        var seen = Set<String>()
        return await ChatStore.ready().scheduleList().map(\.name).filter { seen.insert($0).inserted }.map(ScheduleEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [ScheduleEntity] {
        try await suggestedEntities().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }
}

struct PublishedSurfaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pi Widget"
    static let defaultQuery = PublishedSurfaceQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct PublishedSurfaceQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PublishedSurfaceEntity] {
        identifiers.compactMap { SurfaceStore.shared?.surface($0) }.map { PublishedSurfaceEntity(id: $0.publishedId, title: $0.parsed.title) }
    }

    func suggestedEntities() async throws -> [PublishedSurfaceEntity] {
        (SurfaceStore.shared?.published() ?? []).map { PublishedSurfaceEntity(id: $0.publishedId, title: $0.parsed.title) }
    }

    func entities(matching string: String) async throws -> [PublishedSurfaceEntity] {
        try await suggestedEntities().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
}

// MARK: Intents

struct AskPiIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Pi"
    static let description = IntentDescription("Ask Pi something. The answer shows here; the conversation stays in the app.")

    @Parameter(title: "Prompt", requestValueDialog: "What should I ask Pi?")
    var prompt: String

    static var parameterSummary: some ParameterSummary { Summary("Ask Pi \(\.$prompt)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let store = await ChatStore.ready()
        let answer = try await store.askFromOutside(prompt, conversationId: nil, requestId: IntentRequest.id("ask", prompt), origin: "Siri & Shortcuts")
        return AnswerResult.make(answer, store: store)
    }
}

struct ContinueConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Pi Conversation"
    static let description = IntentDescription("Send a message to one of your Pi conversations.")

    @Parameter(title: "Conversation") var conversation: ConversationEntity
    @Parameter(title: "Message", requestValueDialog: "What should I tell Pi?") var message: String

    static var parameterSummary: some ParameterSummary { Summary("Tell \(\.$conversation) \(\.$message)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let store = await ChatStore.ready()
        let answer = try await store.askFromOutside(
            message, conversationId: conversation.id, requestId: IntentRequest.id("continue", String(conversation.id), message), origin: "Siri & Shortcuts"
        )
        return AnswerResult.make(answer, store: store)
    }
}

struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Pi Conversation"

    @Parameter(title: "Conversation") var target: ConversationEntity

    @MainActor func perform() async throws -> some IntentResult {
        ChatStore.shared.open(.conversation(target.id))
        return .result()
    }
}

/// Opens a published widget's screen in the app; how a Spotlight result for one opens.
struct OpenSurfaceIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Pi Widget"
    static let isDiscoverable = false

    @Parameter(title: "Widget") var target: PublishedSurfaceEntity

    @MainActor func perform() async throws -> some IntentResult {
        ChatStore.shared.open(.surface(target.id))
        return .result()
    }
}

struct RunPiTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Pi Task"
    static let description = IntentDescription("Run one of Pi's scheduled tasks now. Its schedule stays as it is.")

    @Parameter(title: "Task") var task: ScheduleEntity

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$task)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let store = await ChatStore.ready()
        let answer = try await store.runSchedule(task.id, requestId: IntentRequest.id("task", task.id))
        return AnswerResult.make(answer, store: store)
    }
}

struct GetSurfaceValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pi Value"
    static let description = IntentDescription("A value Pi keeps for its widgets ($doc), such as a nudge or a goal.")

    @Parameter(title: "Key", optionsProvider: ValueKeys()) var key: String

    struct ValueKeys: DynamicOptionsProvider {
        func results() async throws -> [String] { (SurfaceStore.shared?.values().keys).map { $0.sorted() } ?? [] }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let value = SurfaceStore.shared?.values()[key]?.display
        return .result(value: value ?? "", dialog: IntentDialog(stringLiteral: value ?? "Pi has no value named \(key)."))
    }
}

struct ShowSurfaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Pi Widget"
    static let description = IntentDescription("Shows one of Pi's published widgets with current data.")

    @Parameter(title: "Widget") var surface: PublishedSurfaceEntity

    @MainActor func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard let published = SurfaceStore.shared?.surface(surface.id) else { throw PiIntentError("That widget is no longer published.") }
        let spec = published.parsed
        let family = [.systemMedium, .systemSmall, .systemLarge].first(where: spec.families.contains) ?? spec.families.first ?? .systemMedium
        let sources = SurfaceValidator().validate(published.spec).sources
        let data = SurfaceData(native: await NativeData().read(Set(sources)), doc: SurfaceStore.shared?.values() ?? [:])
        return .result(view: SurfaceSnippet(spec: spec, family: family, data: data))
    }
}

struct PiIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// What AskPi, ContinueConversation and RunPiTask return: the answer as dialog and value, drawn as a snippet with
/// the card the run made, if any.
enum AnswerResult {
    @MainActor static func make(_ answer: OutsideAnswer, store: ChatStore) -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let text: String = switch answer.status {
        case "done": answer.text ?? ""
        case "running": "Pi is still working on it. You'll get a notification with the answer."
        default: "Pi could not answer. Open the conversation in Pi to see why."
        }
        let title = store.meta(answer.conversationId)?.title ?? "Pi"
        let dialog = String(text.prefix(280))
        // The dialog already shows (and speaks) a short answer; the snippet repeats only what it adds.
        let snippet = AnswerSnippet(title: title, text: dialog.count < text.count ? text : nil, surface: answer.surface?.parsed, data: store.surfaceData)
        return .result(value: answer.text ?? "", dialog: IntentDialog(stringLiteral: dialog), view: snippet)
    }
}

// MARK: Snippets

struct AnswerSnippet: View {
    let title: String
    /// The whole answer, when the dialog had to cut it short.
    let text: String?
    let surface: SurfaceSpec?
    let data: SurfaceData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "sparkle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let text { Text(LocalizedStringKey(String(text.prefix(1200)))).font(.callout) }
            if let surface {
                SurfaceView(spec: surface, family: .card, data: data)
                    .padding(SurfaceFamily.card.contentPadding)
                    .background { SurfaceBackground().clipShape(.rect(cornerRadius: 16)) }
            }
        }
        .padding()
    }
}

struct SurfaceSnippet: View {
    let spec: SurfaceSpec
    let family: SurfaceFamily
    let data: SurfaceData

    var body: some View {
        SurfaceView(spec: spec, family: family, data: data)
            .padding(family.contentPadding)
            .frame(height: family.isAccessory ? nil : family.size.height)
            .background { SurfaceBackground().clipShape(.rect(cornerRadius: 20)) }
            .padding()
    }
}

// MARK: Siri phrases

struct PiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPiIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something"],
            shortTitle: "Ask Pi",
            systemImageName: "sparkle"
        )
        AppShortcut(
            intent: TalkToPiIntent(),
            phrases: ["Talk to \(.applicationName)", "Start talking to \(.applicationName)"],
            shortTitle: "Talk to Pi",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: RunPiTaskIntent(),
            phrases: ["Run \(\.$task) in \(.applicationName)", "Run my \(.applicationName) task"],
            shortTitle: "Run Pi Task",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: ShowSurfaceIntent(),
            phrases: ["Show \(\.$surface) in \(.applicationName)", "Show my \(.applicationName) widget"],
            shortTitle: "Show Pi Widget",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: ["Open \(\.$target) in \(.applicationName)"],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left.and.bubble.right"
        )
    }
}
