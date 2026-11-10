import Foundation

/// The photo index's data: one entry and one unit vector per indexed asset, kept in
/// Application Support as `entries.json` and `vectors.bin` (Float16, in entry order).
public struct PhotoVectors: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        /// `PHAsset.localIdentifier`.
        public let id: String
        public let created: Date?
        /// When the asset last changed; a newer one is embedded again.
        public let modified: Date?
        public let favorite: Bool
        public let screenshot: Bool

        public init(id: String, created: Date?, modified: Date?, favorite: Bool, screenshot: Bool) {
            self.id = id
            self.created = created
            self.modified = modified
            self.favorite = favorite
            self.screenshot = screenshot
        }
    }

    public struct Filter: Sendable {
        public var from: Date?
        public var to: Date?
        public var favoritesOnly = false
        public var screenshotsOnly = false

        public init(from: Date? = nil, to: Date? = nil, favoritesOnly: Bool = false, screenshotsOnly: Bool = false) {
            self.from = from
            self.to = to
            self.favoritesOnly = favoritesOnly
            self.screenshotsOnly = screenshotsOnly
        }

        func matches(_ entry: Entry) -> Bool {
            if favoritesOnly, !entry.favorite { return false }
            if screenshotsOnly, !entry.screenshot { return false }
            if let from, (entry.created ?? .distantPast) < from { return false }
            if let to, (entry.created ?? .distantFuture) >= to { return false }
            return true
        }
    }

    /// Which encoder made the vectors; another one's vectors are thrown away.
    public var model: String
    public private(set) var entries: [Entry] = []
    private var vectors: [Float16] = []
    private var positions: [String: Int] = [:]

    public init(model: String) { self.model = model }

    public var count: Int { entries.count }

    public func entry(_ id: String) -> Entry? { positions[id].map { entries[$0] } }

    public mutating func upsert(_ entry: Entry, vector: [Float]) {
        precondition(vector.count == ClipEncoder.dimensions)
        let half = vector.map(Float16.init)
        if let position = positions[entry.id] {
            entries[position] = entry
            vectors.replaceSubrange(position * ClipEncoder.dimensions ..< (position + 1) * ClipEncoder.dimensions, with: half)
        } else {
            positions[entry.id] = entries.count
            entries.append(entry)
            vectors.append(contentsOf: half)
        }
    }

    /// Drops every entry whose ID is not in `keep` (assets deleted, or no longer shared under limited access).
    public mutating func retain(_ keep: Set<String>) {
        guard entries.contains(where: { !keep.contains($0.id) }) else { return }
        var newEntries: [Entry] = []
        var newVectors: [Float16] = []
        for (position, entry) in entries.enumerated() where keep.contains(entry.id) {
            newEntries.append(entry)
            newVectors.append(contentsOf: vectors[position * ClipEncoder.dimensions ..< (position + 1) * ClipEncoder.dimensions])
        }
        entries = newEntries
        vectors = newVectors
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
    }

    /// The `limit` entries most similar to `query` (a unit vector) that pass `filter`, best first.
    public func search(_ query: [Float], filter: Filter = Filter(), limit: Int) -> [(entry: Entry, score: Float)] {
        let d = ClipEncoder.dimensions
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(entries.count)
        vectors.withUnsafeBufferPointer { buffer in
            for (position, entry) in entries.enumerated() where filter.matches(entry) {
                var dot: Float = 0
                let base = position * d
                for i in 0 ..< d { dot += Float(buffer[base + i]) * query[i] }
                scored.append((position, dot))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (entries[$0.0], $0.1) }
    }

    // MARK: Files

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = Header(model: model, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(header).write(to: directory.appendingPathComponent("entries.json"), options: .atomic)
        try vectors.withUnsafeBytes { Data($0) }.write(to: directory.appendingPathComponent("vectors.bin"), options: .atomic)
    }

    /// The saved index, or an empty one when there is none, it is damaged, or another model made it.
    public static func load(from directory: URL, model: String) -> PhotoVectors {
        var index = PhotoVectors(model: model)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let headerData = try? Data(contentsOf: directory.appendingPathComponent("entries.json")),
              let header = try? decoder.decode(Header.self, from: headerData), header.model == model,
              let data = try? Data(contentsOf: directory.appendingPathComponent("vectors.bin")),
              data.count == header.entries.count * ClipEncoder.dimensions * MemoryLayout<Float16>.size
        else { return index }
        index.entries = header.entries
        index.vectors = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        index.positions = Dictionary(header.entries.enumerated().map { ($1.id, $0) }) { first, _ in first }
        return index
    }

    private struct Header: Codable {
        let model: String
        let entries: [Entry]
    }
}
