import Foundation

/// A spec as the renderer reads it (schema 1). Decoding is lenient: whatever the validator would reject is
/// dropped or defaulted, so a published widget always draws something.
public struct SurfaceSpec: Sendable, Hashable {
    public struct Slot: Sendable, Hashable {
        public let component: String
        public let props: [String: JSONValue]
        /// Families this slot is limited to; nil shows it in every family that supports the component.
        public let families: Set<SurfaceFamily>?
        /// Its position in the spec's `slots`, which action IDs name.
        public var index = 0

        public subscript(prop: String) -> JSONValue? { props[prop] }
    }

    public static let schemaVersion = 1

    public let raw: JSONValue
    public let schema: Int
    public let title: String
    /// `widget` or `card`.
    public let surface: String
    public let families: [SurfaceFamily]
    public let layout: String?
    public let slots: [Slot]
    public let tint: String?
    public let tapURL: URL?
    /// How often the widget re-reads native data.
    public let refreshMinutes: Int

    public init(_ raw: JSONValue) {
        self.raw = raw
        schema = raw["schema"]?.number.map(Int.init) ?? Self.schemaVersion
        title = raw["title"]?.string ?? "Pi"
        surface = raw["surface"]?.string == "card" ? "card" : "widget"
        let families = (raw["families"]?.array ?? []).compactMap { $0.string.flatMap(SurfaceFamily.init(rawValue:)) }.filter { $0 != .card }
        self.families = surface == "card" ? [.card] : families
        layout = raw["layout"]?.string.flatMap { Catalog.layouts.contains($0) ? $0 : nil }
        slots = (raw["slots"]?.array ?? []).enumerated().compactMap { index, value in
            guard var props = value.object, let component = props.removeValue(forKey: "c")?.string else { return nil }
            let families = props.removeValue(forKey: "families")?.array.map { Set($0.compactMap { $0.string.flatMap(SurfaceFamily.init(rawValue:)) }) }
            return Slot(component: component, props: props, families: families, index: index)
        }
        tint = raw["tint"]?.string
        tapURL = raw["tapAction"]?["url"]?.string.flatMap(URL.init(string:))
        refreshMinutes = Self.minutes(raw["refresh"]?["native"]?.string) ?? 30
    }

    /// The slots a family shows: those meant for it whose component supports it, up to its slot limit.
    public func visibleSlots(_ family: SurfaceFamily) -> [Slot] {
        let fitting = slots.filter { slot in
            (slot.families?.contains(family) ?? true) && Catalog.component(slot.component)?.families.contains(family) == true
        }
        guard let limit = family.slotLimit else { return fitting }
        return Array(fitting.prefix(limit))
    }

    /// `"15m"`, `"2h"`; at least 5 minutes (WidgetKit refreshes no faster anyway).
    static func minutes(_ text: String?) -> Int? {
        guard let text, let unit = text.last, let count = Int(text.dropLast()), count > 0 else { return nil }
        switch unit {
        case "m": return max(5, count)
        case "h": return count * 60
        default: return nil
        }
    }
}

/// What PiApp writes to `surfaces/<publishedId>.json` and the widget reads.
public struct PublishedSurface: Codable, Sendable, Hashable, Identifiable {
    /// `c<conversationId>-<surfaceId>`: unique across forks that share a surface ID.
    public let publishedId: String
    public let conversationId: Int
    public let surfaceId: String
    public let version: Int
    public let publishedAt: Date
    /// The dial level of each family when it was published.
    public let dial: [String: Int]
    public let spec: JSONValue

    public var id: String { publishedId }
    public var parsed: SurfaceSpec { SurfaceSpec(spec) }

    public init(publishedId: String, conversationId: Int, surfaceId: String, version: Int, publishedAt: Date, dial: [String: Int], spec: JSONValue) {
        self.publishedId = publishedId
        self.conversationId = conversationId
        self.surfaceId = surfaceId
        self.version = version
        self.publishedAt = publishedAt
        self.dial = dial
        self.spec = spec
    }
}
