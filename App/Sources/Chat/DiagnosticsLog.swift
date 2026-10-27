import Foundation
import Observation
import os

/// A persistent diagnostics log: Pi's `onReport` and `onWake`, host-call failures and app events. Kept in
/// `Library/Application Support/diagnostics.jsonl` (the newest ~1000 entries) and mirrored to OSLog.
@MainActor
@Observable
final class DiagnosticsLog {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        let date: Date
        let level: String
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private static let limit = 1000
    private let logger = Logger(subsystem: "dev.pi.durable", category: "diagnostics")
    private let url: URL = {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("diagnostics.jsonl")
    }()

    init() {
        let decoder = JSONDecoder()
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            entries = text.split(separator: "\n").suffix(Self.limit).compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
        }
        // Rewrite once at launch so the file stays bounded.
        persistAll()
    }

    func record(_ level: String, _ category: String, _ message: String) {
        let entry = Entry(date: .now, level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        switch level {
        case "error": logger.error("\(category, privacy: .public): \(message, privacy: .public)")
        case "warn": logger.warning("\(category, privacy: .public): \(message, privacy: .public)")
        default: logger.info("\(category, privacy: .public): \(message, privacy: .public)")
        }
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    func clear() {
        entries.removeAll()
        persistAll()
    }

    private func persistAll() {
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }
}
