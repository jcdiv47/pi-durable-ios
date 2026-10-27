/// How much the agent generates per family (spec "Generativity dial"). The dial changes validation rules and
/// what `list_components` tells the model, never the renderer.
public enum DialLevel: Int, CaseIterable, Codable, Sendable, Hashable, Comparable {
    /// Pick a preset arrangement and fill in data and text.
    case template = 0
    /// Arrange Layer 1 components in the family's slots.
    case compose = 1
    /// Compose, plus `Custom` slots within a small node budget.
    case composePlus = 2
    /// `Custom` trees within a large node budget.
    case freeform = 3

    public static func < (a: DialLevel, b: DialLevel) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .template: "Template"
        case .compose: "Compose"
        case .composePlus: "Compose+"
        case .freeform: "Freeform"
        }
    }

    /// Primitive nodes one `Custom` slot may use; 0 means `Custom` is not allowed.
    public var customNodeBudget: Int {
        switch self {
        case .template, .compose: 0
        case .composePlus: 24
        case .freeform: 80
        }
    }

    public var rule: String {
        switch self {
        case .template: "use one of the presets below, in order; fill in data and text"
        case .compose: "arrange any components this family supports; no Custom"
        case .composePlus: "components, plus Custom slots of at most \(customNodeBudget) nodes each"
        case .freeform: "components or Custom slots of at most \(customNodeBudget) nodes each"
        }
    }
}

public struct GenerativityDial: Codable, Sendable, Hashable {
    /// Level per family raw value; families not listed use `defaults`.
    public var levels: [String: Int]

    public init(levels: [String: Int] = [:]) { self.levels = levels }

    public static let defaults: [SurfaceFamily: DialLevel] = [
        .accessoryInline: .template,
        .accessoryCircular: .template,
        .accessoryRectangular: .compose,
        .systemSmall: .compose,
        .systemMedium: .compose,
        .systemLarge: .composePlus,
        .card: .freeform,
    ]

    public func level(_ family: SurfaceFamily) -> DialLevel {
        levels[family.rawValue].flatMap(DialLevel.init(rawValue:)) ?? Self.defaults[family] ?? .compose
    }

    public mutating func set(_ level: DialLevel, for family: SurfaceFamily) {
        levels[family.rawValue] = level == Self.defaults[family] ? nil : level.rawValue
    }

    /// The level of each family, as recorded with a published spec.
    public func record(_ families: [SurfaceFamily]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: families.map { ($0.rawValue, level($0).rawValue) })
    }

    /// Level 0 arrangements: the component of each visible slot, in order.
    public static let presets: [SurfaceFamily: [[String]]] = [
        .systemSmall: [["Ring"], ["MetricTile"], ["NextUp"], ["Countdown"], ["Quote"]],
        .systemMedium: [["Ring", "NextUp"], ["MetricTile", "Sparkline"], ["Header", "Quote"], ["Ring", "MetricTile", "Quote"]],
        .systemLarge: [["Header", "StatGrid", "Timeline"], ["Header", "NextUp", "Checklist"], ["Header", "BarStrip", "Quote"]],
        .accessoryCircular: [["Ring"], ["MetricTile"], ["Countdown"]],
        .accessoryRectangular: [["MetricTile"], ["Ring"], ["NextUp"], ["Countdown"], ["Quote"]],
        .accessoryInline: [["Quote"], ["Countdown"], ["MetricTile"], ["NextUp"]],
        .card: [["Header", "Quote"], ["StatGrid"], ["Timeline"]],
    ]
}
