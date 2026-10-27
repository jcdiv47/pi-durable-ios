import Foundation

/// Values for a spec's bindings: native sources the app or widget read (`health.stepsToday` → 6012), and the
/// agent's `$doc` values. A missing value renders as a placeholder, never as an error.
public struct SurfaceData: Sendable, Hashable {
    public var native: [String: JSONValue]
    public var doc: [String: JSONValue]
    /// The timeline entry's time; `$time.now` and countdowns use it.
    public var now: Date

    public init(native: [String: JSONValue] = [:], doc: [String: JSONValue] = [:], now: Date = .now) {
        self.native = native
        self.doc = doc
        self.now = now
    }

    public static let empty = SurfaceData()

    /// A literal as is; a binding looked up (and walked into, for `$calendar.next.title`); nil when missing.
    public func resolve(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        guard let text = value.string, let binding = DataSources.binding(text) else { return value }
        var current: JSONValue?
        if binding.isDoc {
            current = doc[String(binding.source.dropFirst(4))]
        } else if binding.source == "time.now" {
            current = .string(DateParsing.format(now))
        } else if binding.source == "time.endOfDay" {
            let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
            current = .string(DateParsing.format(midnight))
        } else {
            current = native[binding.source]
        }
        for key in binding.path {
            current = current?[key] ?? current?[0]?[key]
        }
        if case .null = current { return nil }
        return current
    }

    public func number(_ value: JSONValue?) -> Double? { resolve(value)?.number }

    public func text(_ value: JSONValue?) -> String? {
        guard let resolved = resolve(value) else { return nil }
        if case let .number(number) = resolved { return Self.formatNumber(number) }
        let text = resolved.display
        return text.isEmpty ? nil : text
    }

    public func date(_ value: JSONValue?) -> Date? { resolve(value)?.string.flatMap(DateParsing.parse) }

    public func bool(_ value: JSONValue?) -> Bool? { resolve(value)?.bool }

    public func series(_ value: JSONValue?) -> (values: [Double], labels: [String]) {
        guard let resolved = resolve(value) else { return ([], []) }
        let values = (resolved.array ?? resolved["values"]?.array ?? []).compactMap(\.number)
        let labels = (resolved["labels"]?.array ?? []).compactMap(\.string)
        return (values, labels)
    }

    public func items(_ value: JSONValue?) -> [SurfaceItem] {
        guard let resolved = resolve(value) else { return [] }
        let list = resolved.array ?? (resolved.object != nil ? [resolved] : [])
        return list.enumerated().compactMap { position, item in
            guard let title = item["title"]?.display, !title.isEmpty else { return nil }
            var resolved = SurfaceItem(
                title: title,
                subtitle: item["subtitle"]?.string,
                date: item["date"]?.string.flatMap(DateParsing.parse),
                end: item["end"]?.string.flatMap(DateParsing.parse),
                done: item["done"]?.bool ?? false,
                symbol: item["symbol"]?.string,
                id: item["id"]?.string
            )
            resolved.position = position
            return resolved
        }
    }

    /// 6012 → "6,012"; 7.25 → "7.3"; 12500 stays exact (widgets have room for it).
    public static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e12 { return Int(value).formatted(.number.grouping(.automatic)) }
        return value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}

public struct SurfaceItem: Sendable, Hashable, Identifiable {
    public let title: String
    public let subtitle: String?
    public let date: Date?
    public let end: Date?
    public let done: Bool
    public let symbol: String?
    /// The native item behind it, for actions: a reminder's EventKit identifier.
    public let nativeId: String?
    /// Where the item sits in its source list, counting items without a title: a checklist toggle names it.
    public var position = 0

    public var id: String { "\(title)|\(date?.timeIntervalSince1970 ?? 0)|\(position)" }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["title": .string(title), "done": .bool(done)]
        if let subtitle { fields["subtitle"] = .string(subtitle) }
        if let date { fields["date"] = .string(DateParsing.format(date)) }
        if let end { fields["end"] = .string(DateParsing.format(end)) }
        if let symbol { fields["symbol"] = .string(symbol) }
        if let nativeId { fields["id"] = .string(nativeId) }
        return .object(fields)
    }

    public init(title: String, subtitle: String? = nil, date: Date? = nil, end: Date? = nil, done: Bool = false, symbol: String? = nil, id: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.end = end
        self.done = done
        self.symbol = symbol
        nativeId = id
    }
}
