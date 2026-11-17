import AppleArchive
import Foundation
import PiRuntime
import PiUI
import System

/// Settings › Backup & Export: the whole of Pi in one Apple Archive (`.aar`), to keep in Files or on a Mac for when the
/// app is reinstalled or its sideload profile runs out, and a restore from one.
///
/// The archive holds a consistent copy of Pi's storage (`SQLiteSnapshot`, taken while Pi stays open), the attachment
/// images, the widgets' files, the voice recordings, the user's instructions, skills, MCP servers and SSH hosts, the
/// settings, and every conversation as Markdown to read without the app. Never a secret: API keys, MCP tokens and SSH
/// passwords and keys stay in this iPhone's Keychain and are entered again after a restore.
///
/// A restore replaces Pi's storage, so it cannot happen while the Harness is open: `stage` unpacks and checks the
/// archive in the App Group, `commitStaged` marks it pending and the app closes, and the next launch applies it
/// (`applyPendingRestore`) before anything reads the files it replaces. The storage it replaced is kept in
/// `restore/previous/` until the next restore.
enum Backup {
    /// Bumped when the layout changes; a newer archive than this build reads is refused.
    static let format = 1

    struct Manifest: Codable, Sendable {
        let format: Int
        let createdAt: Date
        let appVersion: String
        let conversations: Int
        let archived: Int
    }

    struct Outcome {
        let message: String
        let failed: Bool
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// UserDefaults carried over: the user's choices, not this install's bookkeeping.
    static let settingsKeys = [
        "defaultModel", "defaultThinking", "searchProvider", "openLinksInApp", "intelligenceTitles", "intelligenceSummaries",
        "customProvider", "toolPolicies", ChatStore.dialKey, VoiceRecordings.keepKey,
    ]

    static let lastBackupKey = "lastBackupAt"

    private static var files: FileManager { .default }

    /// What is copied as it is: its path in the archive, and where it lives.
    private static func places() throws -> [(path: String, url: URL)] {
        guard let group = SharedContainer.url else { throw Failure("The App Group container is missing.") }
        return [
            ("attachments", group.appending(path: "attachments", directoryHint: .isDirectory)),
            ("surfaces", group.appending(path: "surfaces", directoryHint: .isDirectory)),
            ("voice", URL.applicationSupportDirectory.appending(path: "voice", directoryHint: .isDirectory)),
            ("support/AGENTS.md", InstructionsFile.url),
            ("support/skills", SkillLibrary.appRoot),
            ("support/mcp-servers.json", MCPServerFile.url),
            ("support/ssh-hosts.json", SSHHostFile.url),
        ]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Export

    /// Builds the archive in the temporary directory and returns it; an earlier one there is removed.
    @MainActor
    static func export(_ store: ChatStore) async throws -> URL {
        let conversations = try await store.allMarkdown()
        let now = Date()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let name = "Pi Backup \(stamp.string(from: now))"
        let root = files.temporaryDirectory.appending(path: "backup", directoryHint: .isDirectory)
        let staging = root.appending(path: name, directoryHint: .isDirectory)
        let archive = root.appending(path: "\(name).aar")
        let database = try SharedContainer.directory("pi").appending(path: "session.sqlite")
        let manifest = Manifest(
            format: format,
            createdAt: now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            conversations: conversations.count { $0.meta.archivedAt == nil },
            archived: conversations.count { $0.meta.archivedAt != nil }
        )
        let settings = try settingsSnapshot()
        let markdown = conversations.map { (folder: $0.meta.archivedAt == nil ? "conversations" : "conversations/Archived", name: "\($0.meta.id) \($0.export.fileName)", text: $0.export.markdown) }
        try await Task.detached(priority: .userInitiated) {
            try? files.removeItem(at: root)
            defer { try? files.removeItem(at: staging) }
            try files.createDirectory(at: staging.appending(path: "pi", directoryHint: .isDirectory), withIntermediateDirectories: true)
            try SQLiteSnapshot.copy(database, to: staging.appending(path: "pi/session.sqlite"))
            for place in try places() where files.fileExists(atPath: place.url.path) {
                let target = staging.appending(path: place.path)
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: place.url, to: target)
            }
            for file in markdown {
                let folder = staging.appending(path: file.folder, directoryHint: .isDirectory)
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(file.text.utf8).write(to: folder.appending(path: file.name))
            }
            try settings.write(to: staging.appending(path: "settings.plist"))
            try encoder.encode(manifest).write(to: staging.appending(path: "manifest.json"))
            try compress(staging, to: archive)
        }.value
        UserDefaults.standard.set(now, forKey: lastBackupKey)
        return archive
    }

    private static func settingsSnapshot() throws -> Data {
        var values: [String: Any] = [:]
        for key in settingsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = value }
        }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    private static func compress(_ directory: URL, to archive: URL) throws {
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(archive.path), mode: .writeOnly, options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644)
        ) else { throw Failure("Couldn't create the archive file.") }
        guard let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file) else {
            try? file.close()
            throw Failure("Couldn't start compressing.")
        }
        guard let encoder = ArchiveStream.encodeStream(writingTo: compressed) else {
            try? compressed.close()
            try? file.close()
            throw Failure("Couldn't start the archive.")
        }
        // No owners: they mean nothing on another install.
        guard let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,FLG,MTM,CTM") else { throw Failure("Bad archive fields.") }
        do {
            try encoder.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keys)
            try encoder.close()
            try compressed.close()
            try file.close()
        } catch {
            try? encoder.close()
            try? compressed.close()
            try? file.close()
            throw error
        }
    }

    // MARK: Restore

    private static func restoreDirectory() throws -> URL { try SharedContainer.directory("restore") }

    /// Unpacks `archive` (picked in Files) into the App Group and checks it: its manifest, a format this build reads, and an
    /// intact database. Nothing of Pi's changes yet.
    static func stage(_ archive: URL) async throws -> Manifest {
        let incoming = try restoreDirectory().appending(path: "incoming", directoryHint: .isDirectory)
        return try await Task.detached(priority: .userInitiated) {
            let scoped = archive.startAccessingSecurityScopedResource()
            defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
            try? files.removeItem(at: incoming)
            try files.createDirectory(at: incoming, withIntermediateDirectories: true)
            do {
                try extract(archive, to: incoming)
                try rejectLinks(in: incoming)
                guard let data = try? Data(contentsOf: incoming.appending(path: "manifest.json")),
                      let manifest = try? decoder.decode(Manifest.self, from: data)
                else { throw Failure("This isn't a Pi backup.") }
                guard manifest.format <= format else { throw Failure("This backup is from a newer Pi. Update Pi, then restore it.") }
                guard SQLiteSnapshot.isIntact(incoming.appending(path: "pi/session.sqlite")) else {
                    throw Failure("The backup's conversations are damaged.")
                }
                return manifest
            } catch {
                try? files.removeItem(at: incoming)
                throw error
            }
        }.value
    }

    /// The staged backup is applied at the next launch.
    static func commitStaged() throws {
        let restore = try restoreDirectory()
        let pending = restore.appending(path: "pending", directoryHint: .isDirectory)
        try? files.removeItem(at: pending)
        try files.moveItem(at: restore.appending(path: "incoming", directoryHint: .isDirectory), to: pending)
    }

    static func discardStaged() {
        guard let restore = try? restoreDirectory() else { return }
        try? files.removeItem(at: restore.appending(path: "incoming", directoryHint: .isDirectory))
    }

    private static func extract(_ archive: URL, to directory: URL) throws {
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)
        ) else { throw Failure("Couldn't open the backup.") }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw Failure("This isn't a Pi backup.") }
        defer { try? decompressed.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw Failure("This isn't a Pi backup.") }
        defer { try? decoder.close() }
        // Only paths inside the destination.
        guard let extractor = ArchiveStream.extractStream(
            extractingTo: FilePath(directory.path),
            selectUsing: { _, path, _ in
                path.isAbsolute || path.components.contains { $0.kind == .parentDirectory } ? .skip : .ok
            },
            flags: [.ignoreOperationNotPermitted]
        ) else { throw Failure("Couldn't unpack the backup.") }
        defer { try? extractor.close() }
        _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
    }

    /// A backup is files and folders; a symbolic link could point a restore at anything.
    private static func rejectLinks(in directory: URL) throws {
        let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure("This backup has links in it.") }
        }
    }

    /// At launch, before Pi opens: applies a pending restore, if there is one. Pi's storage is replaced (the old one kept
    /// in `restore/previous/`), attachment images and recordings are added to those here, and the widgets' files, the
    /// user's files and the settings are replaced.
    static func applyPendingRestore() -> Outcome? {
        guard let restore = try? restoreDirectory() else { return nil }
        let pending = restore.appending(path: "pending", directoryHint: .isDirectory)
        guard files.fileExists(atPath: pending.path) else { return nil }
        defer { try? files.removeItem(at: pending) }
        let previous = restore.appending(path: "previous", directoryHint: .isDirectory)
        let sqliteFiles = ["session.sqlite", "session.sqlite-wal", "session.sqlite-shm"]
        guard let pi = try? SharedContainer.directory("pi") else { return Outcome(message: "Restore failed: no App Group container.", failed: true) }
        do {
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: pending.appending(path: "manifest.json")))
            try? files.removeItem(at: previous)
            try files.createDirectory(at: previous, withIntermediateDirectories: true)
            for name in sqliteFiles where files.fileExists(atPath: pi.appending(path: name).path) {
                try files.moveItem(at: pi.appending(path: name), to: previous.appending(path: name))
            }
            try files.moveItem(at: pending.appending(path: "pi/session.sqlite"), to: pi.appending(path: "session.sqlite"))

            let places = Dictionary(uniqueKeysWithValues: try places().map { ($0.path, $0.url) })
            try merge(pending.appending(path: "attachments"), into: places["attachments"]!)
            try merge(pending.appending(path: "voice"), into: VoiceRecordings.directory)
            for path in ["surfaces", "support/AGENTS.md", "support/skills", "support/mcp-servers.json", "support/ssh-hosts.json"] {
                try replace(places[path]!, with: pending.appending(path: path))
            }
            if let data = try? Data(contentsOf: pending.appending(path: "settings.plist")),
               let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                // A setting the backup lacks was at its default then.
                for key in settingsKeys { UserDefaults.standard.removeObject(forKey: key) }
                for (key, value) in values where settingsKeys.contains(key) { UserDefaults.standard.set(value, forKey: key) }
            }
            let date = manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
            return Outcome(message: "Restored the backup from \(date): \(manifest.conversations) conversations, \(manifest.archived) archived", failed: false)
        } catch {
            // Without a database Pi would start empty: the one it had goes back.
            if !files.fileExists(atPath: pi.appending(path: "session.sqlite").path) {
                for name in sqliteFiles { try? files.moveItem(at: previous.appending(path: name), to: pi.appending(path: name)) }
            }
            return Outcome(message: "Restore failed: \(error.localizedDescription)", failed: true)
        }
    }

    /// Moves what `source` has that `destination` lacks into it.
    private static func merge(_ source: URL, into destination: URL) throws {
        guard let items = try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items where !files.fileExists(atPath: destination.appending(path: item.lastPathComponent).path) {
            try files.moveItem(at: item, to: destination.appending(path: item.lastPathComponent))
        }
    }

    /// `destination` becomes `source`; when the backup lacks it, there was none then, so it goes.
    private static func replace(_ destination: URL, with source: URL) throws {
        try? files.removeItem(at: destination)
        guard files.fileExists(atPath: source.path) else { return }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: source, to: destination)
    }
}
