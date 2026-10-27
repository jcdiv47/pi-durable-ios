import Foundation

/// One entry of the tuning log (spec "Generativity dial": log every `Custom` subtree and every validation failure,
/// review them, turn repeated `Custom` layouts into components or presets, raise or lower levels per surface).
/// Every validation is logged, passing or not, so a family's failure rate can be read off the log.
public struct TuningEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case validated, published
    }

    public var date: Date
    public var kind: Kind
    /// The spec's families (raw values).
    public var families: [String]
    /// Each family's dial level when it happened.
    public var levels: [String: Int]
    /// `path: message` for each error; empty when the spec was valid.
    public var errors: [String] = []
    /// `Custom` trees as JSON.
    public var customTrees: [String] = []
    /// Families that show a `Custom` slot (a slot may be limited to some families); nil means all of `families`.
    public var customFamilies: [String]?
    /// What was published (`c3-s1 v2`).
    public var detail: String?

    public init(date: Date = .now, kind: Kind, families: [String], levels: [String: Int], errors: [String] = [], customTrees: [String] = [], customFamilies: [String]? = nil, detail: String? = nil) {
        self.date = date
        self.kind = kind
        self.families = families
        self.levels = levels
        self.errors = errors
        self.customTrees = customTrees
        self.customFamilies = customFamilies
        self.detail = detail
    }
}

/// The tuning log as a JSON-lines file, newest `limit` events kept. PiApp writes it from `SurfaceHost` and reads it in
/// the Design Tuning screen; nothing else does, so appends need no locking beyond the caller's.
public final class TuningLog: @unchecked Sendable {
    public let url: URL
    let limit: Int
    private let lock = NSLock()

    public init(url: URL, limit: Int = 2000) {
        self.url = url
        self.limit = limit
    }

    /// In the app's Application Support directory.
    public static let shared: TuningLog = {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return TuningLog(url: directory.appendingPathComponent("tuning.jsonl"))
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func append(_ event: TuningEvent) {
        guard var line = try? Self.encoder.encode(event) else { return }
        line.append(0x0A)
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    /// All kept events, oldest first. Trims the file to `limit` when it has grown past twice that.
    public func read() -> [TuningEvent] {
        lock.withLock {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let lines = text.split(separator: "\n")
            let events = lines.suffix(limit).compactMap { try? Self.decoder.decode(TuningEvent.self, from: Data($0.utf8)) }
            if lines.count > 2 * limit { rewrite(events) }
            return events
        }
    }

    public func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }

    /// The raw file, for sharing.
    public func export() -> String {
        lock.withLock { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    private func rewrite(_ events: [TuningEvent]) {
        var data = Data()
        for event in events {
            guard let line = try? Self.encoder.encode(event) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// What the tuning log says: per-family failure rates, repeated `Custom` layouts and recurring errors, with
/// suggestions. Suggestions only point; the dial changes only in Settings.
public struct TuningSummary: Sendable, Hashable {
    public struct FamilyStats: Sendable, Hashable, Identifiable {
        public let family: SurfaceFamily
        public var validations = 0
        public var failures = 0
        /// Validations that included a `Custom` slot.
        public var custom = 0
        /// Errors because `Custom` was not allowed or over its node budget.
        public var customRejected = 0
        public var publishes = 0
        public var id: String { family.rawValue }
        public var failureRate: Double { validations == 0 ? 0 : Double(failures) / Double(validations) }
        /// Enough validations to judge, and too many of them failed.
        public var failingOften: Bool { validations >= TuningSummary.minimumValidations && failureRate >= TuningSummary.highFailureRate }
    }

    /// A `Custom` layout by its shape (node types and nesting, without text or values).
    public struct Shape: Sendable, Hashable, Identifiable {
        public let signature: String
        public var count: Int
        public var families: Set<String>
        /// The newest tree with this shape.
        public var example: String
        public var id: String { signature }
    }

    /// An error message with its specifics (numbers, quoted values, slot indexes) blanked out.
    public struct Failure: Sendable, Hashable, Identifiable {
        public let pattern: String
        public var count: Int
        public var example: String
        public var id: String { pattern }
    }

    public var events = 0
    public var since: Date?
    public var families: [FamilyStats] = []
    public var shapes: [Shape] = []
    public var failures: [Failure] = []
    public var suggestions: [String] = []

    /// Thresholds: a suggestion needs at least this many validations, or repeats.
    static let minimumValidations = 5
    static let repeatedShape = 3
    static let highFailureRate = 0.4

    public init(_ events: [TuningEvent], dial: GenerativityDial) {
        self.events = events.count
        since = events.first?.date
        var stats: [SurfaceFamily: FamilyStats] = [:]
        var observed: Set<SurfaceFamily> = []
        var shapes: [String: Shape] = [:]
        var failures: [String: Failure] = [:]
        for event in events {
            let families = event.families.compactMap(SurfaceFamily.init(rawValue:))
            observed.formUnion(families)
            // Per-family numbers count only events at the family's current level: suggestions are about that level.
            for family in families where event.levels[family.rawValue] ?? dial.level(family).rawValue == dial.level(family).rawValue {
                var entry = stats[family] ?? FamilyStats(family: family)
                switch event.kind {
                case .published:
                    entry.publishes += 1
                case .validated:
                    entry.validations += 1
                    let errors = event.errors.filter { Self.applies($0, to: family) }
                    if !errors.isEmpty { entry.failures += 1 }
                    if !event.customTrees.isEmpty, (event.customFamilies ?? event.families).contains(family.rawValue) { entry.custom += 1 }
                    entry.customRejected += errors.filter { Self.isCustomRejection($0, family: family) }.count
                }
                stats[family] = entry
            }
            for tree in event.customTrees {
                let signature = Self.signature(tree)
                var shape = shapes[signature] ?? Shape(signature: signature, count: 0, families: [], example: tree)
                shape.count += 1
                shape.families.formUnion(event.families)
                shape.example = tree
                shapes[signature] = shape
            }
            for error in event.errors {
                let pattern = Self.pattern(error)
                var failure = failures[pattern] ?? Failure(pattern: pattern, count: 0, example: error)
                failure.count += 1
                failure.example = error
                failures[pattern] = failure
            }
        }
        // A family keeps its row (and its level picker) after a level change, with zero counts until new designs come.
        families = SurfaceFamily.allCases.filter(observed.contains).map { stats[$0] ?? FamilyStats(family: $0) }
        self.shapes = shapes.values.sorted { ($0.count, $1.signature) > ($1.count, $0.signature) }
        self.failures = failures.values.sorted { ($0.count, $1.pattern) > ($1.count, $0.pattern) }
        suggestions = Self.suggest(families: families, shapes: self.shapes, dial: dial)
    }

    static func suggest(families: [FamilyStats], shapes: [Shape], dial: GenerativityDial) -> [String] {
        var suggestions: [String] = []
        for stats in families {
            let level = dial.level(stats.family)
            let name = stats.family.displayName
            if stats.customRejected >= repeatedShape, level < .freeform {
                let next = DialLevel(rawValue: max(level.rawValue + 1, DialLevel.composePlus.rawValue))!
                suggestions.append(
                    "Pi reached for Custom in \(name) \(stats.customRejected) times and was refused at level \(level.rawValue) (\(level.name)). " +
                        "Raise it to \(next.rawValue) (\(next.name)), or add a component for what it was building."
                )
            }
            if stats.failingOften, level > .template {
                let lower = DialLevel(rawValue: level.rawValue - 1)!
                suggestions.append(
                    "\(Int((stats.failureRate * 100).rounded()))% of \(name) designs failed validation at level \(level.rawValue) (\(level.name)). " +
                        "If the errors below are about the level's freedom, lower it to \(lower.rawValue) (\(lower.name))."
                )
            }
            if stats.validations >= minimumValidations, stats.failures == 0, stats.custom == 0, level >= .composePlus {
                suggestions.append("\(name) is at level \(level.rawValue) (\(level.name)) but Pi never used Custom there in \(stats.validations) designs; level 1 (Compose) would do.")
            }
        }
        for shape in shapes where shape.count >= repeatedShape {
            suggestions.append("A Custom layout came up \(shape.count) times: \(shape.signature). Make it a Layer 1 component or a preset.")
        }
        return suggestions
    }

    /// The validator's per-family errors (`checkFamily`) are that family's; any other error is the whole spec's, even
    /// if it mentions families (`surface must be "widget" or "card"`, `… it supports systemSmall, …`).
    static func applies(_ error: String, to family: SurfaceFamily) -> Bool {
        guard let owner = SurfaceFamily.allCases.first(where: { owns(error, $0) }) else { return true }
        return owner == family
    }

    /// `/slots: systemMedium allows 3 slots, got 4`, `… is not allowed in systemMedium at level 1 …`,
    /// `…; systemLarge at level 2 (Compose+) allows 24`.
    static func owns(_ error: String, _ family: SurfaceFamily) -> Bool {
        let message = error.split(separator: ": ", maxSplits: 1).last.map(String.init) ?? error
        let name = family.rawValue
        return ["\(name) would show nothing:", "\(name) allows ", "\(name) is at level "].contains(where: message.hasPrefix)
            || message.contains(" in \(name) at level") || message.contains("; \(name) at level")
    }

    static func isCustomRejection(_ error: String, family: SurfaceFamily) -> Bool {
        error.contains(family.rawValue) && (error.contains("Custom is not allowed") || error.contains("This Custom tree has"))
    }

    /// `HStack[Image, VStack[Text, Text, Progress]]`: node types and nesting only.
    public static func signature(_ tree: String) -> String {
        guard let data = tree.data(using: .utf8), let node = try? JSONValue(json: data) else { return "?" }
        return signature(node)
    }

    static func signature(_ node: JSONValue) -> String {
        let type = node["t"]?.string ?? "?"
        guard let children = node["children"]?.array, !children.isEmpty else { return type }
        return "\(type)[\(children.map(signature).joined(separator: ", "))]"
    }

    /// `/slots/2: This Custom tree has 31 nodes; …` → `/slots/#: This Custom tree has # nodes; …`; quoted text → `"…"`.
    public static func pattern(_ error: String) -> String {
        var text = error.replacingOccurrences(of: #""[^"]*""#, with: "\"…\"", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\d+(\.\d+)?"#, with: "#", options: .regularExpression)
        return text
    }
}
