/// The value a prop takes. Literal JSON, or (where `bindable`) a `$source` binding the widget resolves.
public indirect enum PropType: Sendable, Hashable {
    case number
    case string
    /// A number or a string, shown as text.
    case text
    case bool
    /// ISO 8601 date-time, with a UTC offset.
    case date
    /// A named color (`Palette.names`).
    case color
    /// An SF Symbol name.
    case symbol
    case url
    case oneOf([String])
    /// An array of numbers, or `{ "values": [numbers], "labels": [strings] }`.
    case series
    /// An array of `{ title, subtitle?, date?, end?, done?, symbol? }`.
    case items
    case stringList
    /// An array of objects with these fields.
    case list([PropDef], min: Int, max: Int)
    /// A Layer 0 primitive tree (`Custom` only).
    case node

    var summary: String {
        switch self {
        case .number: "number"
        case .string: "string"
        case .text: "number or string"
        case .bool: "boolean"
        case .date: "ISO 8601 date-time"
        case .color: "color name"
        case .symbol: "SF Symbol name"
        case .url: "URL"
        case let .oneOf(values): values.map { "\"\($0)\"" }.joined(separator: " | ")
        case .series: "array of numbers, or {values, labels}"
        case .items: "array of {title, subtitle?, date?, end?, done?, symbol?}"
        case .stringList: "array of strings"
        case let .list(fields, min, max): "\(min)–\(max) × {\(fields.map { $0.required ? $0.name : "\($0.name)?" }.joined(separator: ", "))}"
        case .node: "Layer 0 node"
        }
    }
}

public struct PropDef: Sendable, Hashable {
    public let name: String
    public let type: PropType
    public let required: Bool
    /// Whether a `$source` binding may stand in for a literal.
    public let bindable: Bool
    public let help: String

    init(_ name: String, _ type: PropType, required: Bool = false, bindable: Bool = true, _ help: String = "") {
        self.name = name
        self.type = type
        self.required = required
        self.bindable = bindable
        self.help = help
    }
}

/// A Layer 1 component: what it is for, its props, and the families it can adapt to.
public struct ComponentDef: Sendable, Hashable {
    public let name: String
    public let purpose: String
    public let props: [PropDef]
    public let families: Set<SurfaceFamily>
    /// Soft text budget per family; longer text gets a truncation warning.
    let textBudget: [SurfaceFamily: Int]

    public func prop(_ name: String) -> PropDef? { props.first { $0.name == name } }
}

public enum Catalog {
    static let all = Set(SurfaceFamily.allCases)
    static let system: Set<SurfaceFamily> = [.systemSmall, .systemMedium, .systemLarge, .card]
    static let tint = PropDef("tint", .color, bindable: false, "Accent color")
    static let symbol = PropDef("symbol", .symbol, bindable: false, "SF Symbol shown with it")

    public static let components: [ComponentDef] = [
        ComponentDef(
            name: "MetricTile",
            purpose: "One big number with a label and an optional trend.",
            props: [
                PropDef("value", .text, required: true), PropDef("label", .string, required: true), PropDef("unit", .string),
                PropDef("trend", .oneOf(["up", "down", "flat"]), bindable: false), PropDef("delta", .text, "Change shown next to the trend, e.g. \"+12%\""),
                symbol, tint,
            ],
            families: all,
            textBudget: [.systemSmall: 18, .accessoryCircular: 6, .accessoryRectangular: 24, .accessoryInline: 30]
        ),
        ComponentDef(
            name: "Ring",
            purpose: "Progress toward a goal as a ring.",
            props: [PropDef("value", .number, required: true), PropDef("goal", .number, required: true), PropDef("label", .string), PropDef("unit", .string), symbol, tint],
            families: all.subtracting([.accessoryInline]),
            textBudget: [.accessoryRectangular: 24]
        ),
        ComponentDef(
            name: "Sparkline",
            purpose: "A small trend line.",
            props: [
                PropDef("series", .series, required: true), PropDef("label", .string), PropDef("unit", .string),
                PropDef("highlight", .oneOf(["last", "max", "min", "none"]), bindable: false, "Which point to mark and print (default last)"), tint,
            ],
            families: system.union([.accessoryRectangular]),
            textBudget: [:]
        ),
        ComponentDef(
            name: "BarStrip",
            purpose: "A small bar chart, e.g. the last 7 days.",
            props: [PropDef("series", .series, required: true), PropDef("labels", .stringList, "One per bar; series labels are used when omitted"), PropDef("label", .string), tint],
            families: system.union([.accessoryRectangular]),
            textBudget: [:]
        ),
        ComponentDef(
            name: "NextUp",
            purpose: "The next calendar events or reminders, with an optional countdown.",
            props: [
                PropDef("source", .items, required: true, "Usually $calendar.next, $calendar.today or $reminders.open"),
                PropDef("title", .string), PropDef("showCountdown", .bool, bindable: false), PropDef("maxItems", .number, bindable: false), tint,
            ],
            families: all,
            textBudget: [.accessoryInline: 30]
        ),
        ComponentDef(
            name: "Countdown",
            purpose: "Time until (or since) a date; ticks live in the widget.",
            props: [
                PropDef("date", .date, required: true), PropDef("label", .string),
                PropDef("style", .oneOf(["timer", "relative", "date", "time"]), bindable: false, "Default relative"), symbol, tint,
            ],
            families: all,
            textBudget: [.accessoryInline: 24, .accessoryCircular: 8]
        ),
        ComponentDef(
            name: "Checklist",
            purpose: "Reminders or to-dos with check marks (toggling them comes with M3).",
            props: [PropDef("items", .items, required: true, "Usually $reminders.open"), PropDef("title", .string), PropDef("maxItems", .number, bindable: false), tint],
            families: system.union([.accessoryRectangular]),
            textBudget: [:]
        ),
        ComponentDef(
            name: "Timeline",
            purpose: "An ordered list of time-stamped items.",
            props: [PropDef("items", .items, required: true), PropDef("title", .string), PropDef("maxItems", .number, bindable: false), tint],
            families: system.union([.accessoryRectangular]),
            textBudget: [:]
        ),
        ComponentDef(
            name: "Quote",
            purpose: "Short text you write: a nudge, a summary, a quote.",
            props: [
                PropDef("text", .text, required: true), PropDef("attribution", .string),
                PropDef("emphasis", .oneOf(["primary", "secondary", "accent"]), bindable: false), symbol,
            ],
            families: all.subtracting([.accessoryCircular]),
            textBudget: [.systemSmall: 90, .systemMedium: 140, .systemLarge: 320, .accessoryRectangular: 60, .accessoryInline: 30]
        ),
        ComponentDef(
            name: "StatGrid",
            purpose: "Two to four compact metrics in a grid.",
            props: [
                PropDef("items", .list([PropDef("label", .string, required: true), PropDef("value", .text, required: true), PropDef("unit", .string), PropDef("symbol", .symbol, bindable: false)], min: 2, max: 4), required: true, bindable: false),
                tint,
            ],
            families: system.union([.accessoryRectangular]),
            textBudget: [:]
        ),
        ComponentDef(
            name: "Header",
            purpose: "A title with a symbol and an optional updated time.",
            props: [PropDef("title", .string, required: true), PropDef("subtitle", .string), PropDef("updatedAt", .date), symbol, tint],
            families: system.union([.accessoryRectangular, .accessoryInline]),
            textBudget: [.systemSmall: 18, .accessoryInline: 30]
        ),
        ComponentDef(
            name: "Badge",
            purpose: "A status pill.",
            props: [PropDef("text", .text, required: true), PropDef("tone", .oneOf(["neutral", "positive", "warning", "critical", "info"]), bindable: false), symbol],
            families: all,
            textBudget: [.accessoryCircular: 5, .systemSmall: 16]
        ),
        ComponentDef(
            name: "ActionRow",
            purpose: "One to three buttons that open a link (in-widget actions come with M3).",
            props: [
                PropDef("actions", .list([PropDef("title", .string, required: true), PropDef("url", .url, required: true, bindable: false), PropDef("symbol", .symbol, bindable: false)], min: 1, max: 3), required: true, bindable: false),
                tint,
            ],
            families: [.systemMedium, .systemLarge, .card],
            textBudget: [:]
        ),
        ComponentDef(
            name: "ImageCard",
            purpose: "A large SF Symbol with a caption (photos come later).",
            props: [PropDef("symbol", .symbol, required: true, bindable: false), PropDef("caption", .text), tint],
            families: all.subtracting([.accessoryInline]),
            textBudget: [.systemSmall: 40]
        ),
        ComponentDef(
            name: "Custom",
            purpose: "A Layer 0 primitive tree, for layouts no component covers. Allowed only where the surface's level permits it.",
            props: [PropDef("tree", .node, required: true, bindable: false)],
            families: all.subtracting([.accessoryInline]),
            textBudget: [:]
        ),
    ]

    public static func component(_ name: String) -> ComponentDef? { components.first { $0.name == name } }

    /// Slot arrangements; `split` puts the first slot on the left and stacks the rest on the right.
    public static let layouts = ["stack", "row", "split", "grid"]
}

/// Layer 0: the primitive nodes a `Custom` slot is built from. Every node is `{ "t": type, ...props }`.
public enum Primitives {
    public struct NodeDef: Sendable, Hashable {
        public let type: String
        public let props: [PropDef]
        public let hasChildren: Bool
    }

    static let font = PropDef("font", .oneOf(["largeTitle", "title", "title2", "title3", "headline", "body", "callout", "subheadline", "footnote", "caption", "caption2"]), bindable: false)
    static let align = PropDef("align", .oneOf(["leading", "center", "trailing", "top", "bottom"]), bindable: false)
    static let spacing = PropDef("spacing", .number, bindable: false)
    static let color = PropDef("color", .color, bindable: false)

    public static let nodes: [NodeDef] = [
        NodeDef(type: "VStack", props: [spacing, align], hasChildren: true),
        NodeDef(type: "HStack", props: [spacing, align], hasChildren: true),
        NodeDef(type: "ZStack", props: [align], hasChildren: true),
        NodeDef(type: "Text", props: [
            PropDef("text", .text, required: true), font,
            PropDef("weight", .oneOf(["regular", "medium", "semibold", "bold", "heavy"]), bindable: false),
            PropDef("design", .oneOf(["default", "rounded", "monospaced", "serif"]), bindable: false),
            PropDef("dateStyle", .oneOf(["timer", "relative", "date", "time"]), bindable: false, "Treat `text` as an ISO date and format it live"),
            PropDef("lineLimit", .number, bindable: false), color,
        ], hasChildren: false),
        NodeDef(type: "Image", props: [PropDef("symbol", .symbol, required: true, bindable: false), PropDef("size", .number, bindable: false), color], hasChildren: false),
        NodeDef(type: "Spacer", props: [PropDef("minLength", .number, bindable: false)], hasChildren: false),
        NodeDef(type: "Divider", props: [], hasChildren: false),
        NodeDef(type: "Gauge", props: [
            PropDef("value", .number, required: true), PropDef("min", .number), PropDef("max", .number), PropDef("label", .string),
            PropDef("style", .oneOf(["circular", "linear"]), bindable: false), color,
        ], hasChildren: false),
        NodeDef(type: "Progress", props: [PropDef("value", .number, required: true), PropDef("total", .number), color], hasChildren: false),
        NodeDef(type: "Chart", props: [
            PropDef("kind", .oneOf(["line", "bar", "area", "point", "sector"]), required: true, bindable: false),
            PropDef("series", .series, required: true), color,
        ], hasChildren: false),
        NodeDef(type: "Link", props: [PropDef("url", .url, required: true, bindable: false)], hasChildren: true),
    ]

    /// Allowed on every node.
    public static let modifiers: [PropDef] = [
        PropDef("padding", .number, bindable: false),
        PropDef("background", .color, bindable: false),
        PropDef("cornerRadius", .number, bindable: false),
        PropDef("opacity", .number, bindable: false),
        PropDef("fill", .bool, bindable: false, "Take all available width and height"),
    ]

    public static func node(_ type: String) -> NodeDef? { nodes.first { $0.type == type } }
}
