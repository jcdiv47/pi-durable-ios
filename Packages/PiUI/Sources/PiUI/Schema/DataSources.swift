/// Native data sources (`$health.*`, `$calendar.*`, `$reminders.*`, `$time.*`): the widget resolves them itself on
/// its timeline, with no model call. `$doc.<key>` reads a value the agent stored with `set_value`.
public enum DataSources {
    public enum Kind: String, Sendable, Hashable {
        case number, string, date, series, items, item, any

        /// Whether a value of this kind may stand in for a prop of `type`.
        func fits(_ type: PropType) -> Bool {
            switch (self, type) {
            case (.any, _): true
            case (.number, .number), (.number, .text), (.number, .string): true
            case (.string, .string), (.string, .text): true
            case (.date, .date), (.date, .text): true
            case (.series, .series): true
            case (.items, .items), (.item, .items): true
            default: false
            }
        }
    }

    public enum Permission: String, Sendable, Hashable {
        case none, health, calendar, reminders
    }

    public struct Source: Sendable, Hashable {
        public let name: String
        public let kind: Kind
        public let permission: Permission
        public let help: String
    }

    public static let sources: [Source] = [
        Source(name: "health.stepsToday", kind: .number, permission: .health, help: "Steps since midnight"),
        Source(name: "health.activeEnergyToday", kind: .number, permission: .health, help: "Active energy since midnight, kcal"),
        Source(name: "health.distanceToday", kind: .number, permission: .health, help: "Walking + running distance since midnight, km"),
        Source(name: "health.flightsToday", kind: .number, permission: .health, help: "Flights climbed since midnight"),
        Source(name: "health.restingHeartRate", kind: .number, permission: .health, help: "Latest daily resting heart rate, bpm"),
        Source(name: "health.sleepLastNight", kind: .number, permission: .health, help: "Hours asleep from 18:00 yesterday to now"),
        Source(name: "health.stepsWeek", kind: .series, permission: .health, help: "Steps per day, the last 7 days, labelled by weekday"),
        Source(name: "health.activeEnergyWeek", kind: .series, permission: .health, help: "Active kcal per day, the last 7 days"),
        Source(name: "health.sleepWeek", kind: .series, permission: .health, help: "Hours asleep per night, the last 7 nights"),
        Source(name: "calendar.next", kind: .item, permission: .calendar, help: "The next event in the coming 7 days; fields title, subtitle (location), date (start), end"),
        Source(name: "calendar.today", kind: .items, permission: .calendar, help: "Today's events that have not ended"),
        Source(name: "calendar.countToday", kind: .number, permission: .calendar, help: "How many events today has left"),
        Source(name: "reminders.open", kind: .items, permission: .reminders, help: "Incomplete reminders, soonest due first; date is the due date"),
        Source(name: "reminders.dueToday", kind: .items, permission: .reminders, help: "Incomplete reminders due by the end of today"),
        Source(name: "reminders.countOpen", kind: .number, permission: .reminders, help: "How many reminders are incomplete"),
        Source(name: "time.now", kind: .date, permission: .none, help: "The time of the widget's timeline entry"),
        Source(name: "time.endOfDay", kind: .date, permission: .none, help: "Midnight tonight"),
    ]

    /// Fields of an item (`calendar.next`, an element of `calendar.today`, …) and their kinds.
    static let itemFields: [String: Kind] = ["title": .string, "subtitle": .string, "date": .date, "end": .date, "done": .any, "symbol": .string]

    public static func source(_ name: String) -> Source? { sources.first { $0.name == name } }

    /// A parsed `$source[.field]` binding.
    public struct Binding: Sendable, Hashable {
        /// `health.stepsToday`, `calendar.next`, or `doc.<key>`.
        public let source: String
        /// Path into the value, e.g. `["title"]` for `$calendar.next.title`.
        public let path: [String]
        public var isDoc: Bool { source.hasPrefix("doc.") }
    }

    /// Parses `"$calendar.next.title"`; nil for any string that is not a binding.
    public static func binding(_ text: String) -> Binding? {
        guard text.hasPrefix("$"), text.count > 1 else { return nil }
        let parts = text.dropFirst().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        if parts[0] == "doc" { return Binding(source: "doc.\(parts[1])", path: Array(parts.dropFirst(2))) }
        return Binding(source: "\(parts[0]).\(parts[1])", path: Array(parts.dropFirst(2)))
    }

    /// The kind a binding yields, or an error message for the model.
    static func kind(of binding: Binding) -> Result<Kind, BindingError> {
        if binding.isDoc { return .success(.any) }
        guard let source = source(binding.source) else {
            return .failure(BindingError("Unknown data source $\(binding.source). Known: \(sources.map { "$\($0.name)" }.joined(separator: ", ")), or $doc.<key>"))
        }
        guard let field = binding.path.first else { return .success(source.kind) }
        guard source.kind == .item, binding.path.count == 1, let kind = itemFields[field] else {
            return .failure(BindingError("$\(binding.source) has no field \(binding.path.joined(separator: ".")); item fields are \(itemFields.keys.sorted().joined(separator: ", "))"))
        }
        return .success(kind)
    }

    struct BindingError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
