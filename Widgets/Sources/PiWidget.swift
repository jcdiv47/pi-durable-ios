import AppIntents
import PiUI
import SwiftUI
import WidgetKit

/// The configurable "Pi" widget: shows one published surface (`surfaces/<id>.json`), chosen in the widget's
/// settings. It resolves `$health`, `$calendar` and `$reminders` bindings itself on its timeline and reads
/// `$doc` values from `snapshots/values.json`; it never opens Pi storage or loads JS.
struct PiWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SurfaceStore.widgetKind, intent: SelectSurfaceIntent.self, provider: SurfaceTimeline()) { entry in
            PiWidgetView(entry: entry)
        }
        .configurationDisplayName("Pi")
        .description("A widget Pi designed for you. Ask Pi for one, then choose it here.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SurfaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pi surface"
    static let defaultQuery = SurfaceQuery()

    let id: String
    let title: String
    let families: [String]

    var displayRepresentation: DisplayRepresentation {
        let sizes = families.compactMap(SurfaceFamily.init(rawValue:)).map(\.displayName).joined(separator: ", ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(sizes)")
    }

    init(_ surface: PublishedSurface) {
        id = surface.publishedId
        title = surface.parsed.title
        families = surface.parsed.families.map(\.rawValue)
    }
}

/// Lists published surfaces, newest first; the newest is the default.
struct SurfaceQuery: EntityQuery {
    func entities(for identifiers: [SurfaceEntity.ID]) async throws -> [SurfaceEntity] {
        let store = SurfaceStore.shared
        return identifiers.compactMap { store?.surface($0) }.map(SurfaceEntity.init)
    }

    func suggestedEntities() async throws -> [SurfaceEntity] {
        (SurfaceStore.shared?.published() ?? []).map(SurfaceEntity.init)
    }

    func defaultResult() async -> SurfaceEntity? {
        SurfaceStore.shared?.published().first.map(SurfaceEntity.init)
    }
}

struct SelectSurfaceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a surface"
    static let description = IntentDescription("Which of Pi's published surfaces this widget shows.")

    @Parameter(title: "Surface")
    var surface: SurfaceEntity?
}

struct SurfaceEntry: TimelineEntry {
    let date: Date
    let surface: PublishedSurface?
    let data: SurfaceData
    /// The gallery preview, before anything is published.
    var sample = false
}

struct SurfaceTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SurfaceEntry {
        SurfaceEntry(date: .now, surface: Self.sample, data: Self.sampleData, sample: true)
    }

    func snapshot(for configuration: SelectSurfaceIntent, in context: Context) async -> SurfaceEntry {
        if context.isPreview, SurfaceStore.shared?.published().isEmpty ?? true { return placeholder(in: context) }
        return await entry(for: configuration)
    }

    func timeline(for configuration: SelectSurfaceIntent, in context: Context) async -> Timeline<SurfaceEntry> {
        let entry = await entry(for: configuration)
        let minutes = entry.surface?.parsed.refreshMinutes ?? 60
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Double(minutes) * 60)))
    }

    private func entry(for configuration: SelectSurfaceIntent) async -> SurfaceEntry {
        let store = SurfaceStore.shared
        let surface = configuration.surface.flatMap { store?.surface($0.id) } ?? store?.published().first
        guard let surface else { return SurfaceEntry(date: .now, surface: nil, data: .empty) }
        let sources = SurfaceValidator().validate(surface.spec).sources
        let native = await NativeData().read(Set(sources))
        return SurfaceEntry(date: .now, surface: surface, data: SurfaceData(native: native, doc: store?.values() ?? [:]))
    }

    static let sample = PublishedSurface(
        publishedId: "sample", conversationId: 0, surfaceId: "sample", version: 1, publishedAt: .now, dial: [:],
        spec: [
            "title": "Pi", "surface": "widget",
            "families": ["systemSmall", "systemMedium", "systemLarge", "accessoryCircular", "accessoryRectangular", "accessoryInline"],
            "slots": [
                ["c": "Ring", "value": 6400, "goal": 10000, "symbol": "figure.walk", "label": "Steps"],
                ["c": "NextUp", "source": [["title": "Design review", "subtitle": "Room 4"]]],
                ["c": "Quote", "text": "Ask Pi to design this widget.", "emphasis": "secondary"],
            ],
        ]
    )

    static let sampleData = SurfaceData()
}

struct PiWidgetView: View {
    let entry: SurfaceEntry
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        content
            .containerBackground(for: .widget) { SurfaceBackground() }
    }

    @ViewBuilder private var content: some View {
        let family = SurfaceFamily(widgetFamily)
        if let surface = entry.surface, let family, surface.parsed.families.contains(family) {
            SurfaceView(spec: surface.parsed, family: family, data: entry.data, tinted: renderingMode != .fullColor, inWidget: true)
                .environment(\.surfaceActions, entry.sample ? nil : actions(surface))
                .widgetURL(tapURL(surface))
        } else if let surface = entry.surface {
            message("\(surface.parsed.title) has no \(family?.displayName ?? "layout for this size"). Ask Pi to add it, or choose another surface.")
        } else {
            message("Ask Pi to design a widget, then choose it here.")
        }
    }

    /// Buttons and checklist rows run `RunWidgetActionIntent` in the app; the entry date makes a repeated delivery
    /// of the same tap one request.
    private func actions(_ surface: PublishedSurface) -> SurfaceActionHandler {
        let publishedId = surface.publishedId
        let renderedAt = entry.date
        return SurfaceActionHandler { actionId, label in
            AnyView(
                Button(intent: RunWidgetActionIntent(publishedId: publishedId, actionId: actionId, renderedAt: renderedAt)) { label }
                    .buttonStyle(.plain)
            )
        }
    }

    private func tapURL(_ surface: PublishedSurface) -> URL? {
        if entry.sample { return nil }
        return surface.parsed.tapURL ?? URL(string: "pidurable://conversation/\(surface.conversationId)")
    }

    @ViewBuilder private func message(_ text: String) -> some View {
        switch widgetFamily {
        case .accessoryInline:
            Label("Pi", systemImage: "sparkle")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkle")
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                PiLogo().frame(height: 20)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "pidurable://widgets"))
        }
    }
}

extension SurfaceFamily {
    init?(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .systemSmall
        case .systemMedium: self = .systemMedium
        case .systemLarge: self = .systemLarge
        case .accessoryCircular: self = .accessoryCircular
        case .accessoryRectangular: self = .accessoryRectangular
        case .accessoryInline: self = .accessoryInline
        default: return nil
        }
    }
}
