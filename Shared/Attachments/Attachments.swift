import Foundation
import ImageIO
import PDFKit
import PiUI
import UniformTypeIdentifiers

// Context attached to a message, compiled into PiApp and PiShare. Both prepare attachments the same way: images are
// downscaled to JPEG in the App Group's `attachments/` (the transcript's thumbnails read them there too), file text
// is read out. Only PiApp turns them into the JS `InputAttachment`s (js/src/app/attachments.ts).

struct Attachment: Codable, Hashable, Identifiable, Sendable {
    enum Content: Codable, Hashable, Sendable {
        /// A JPEG in `Attachments.directory`.
        case image(file: String)
        case text(String)
        case link(URL)
    }

    var id = UUID()
    var content: Content
    /// A file's name, a link's page title.
    var name: String?
}

enum Attachments {
    /// Anthropic scales larger images down to this long edge anyway; others take it as is.
    static let maxPixelSize = 1568
    /// Text files and PDFs above this are not read (JS also cuts each text at 100,000 characters for the model).
    static let maxFileBytes = 20_000_000

    static var directory: URL? { try? SharedContainer.directory("attachments") }

    static func imageURL(_ file: String) -> URL? { directory?.appendingPathComponent(file) }

    /// Image files younger than this are never swept: the share sheet saves its images before it writes the inbox item,
    /// and the composer holds new ones only in memory.
    static let sweepGrace: TimeInterval = 24 * 60 * 60

    /// Deletes the image files not in `kept` and older than `sweepGrace`; returns how many it deleted.
    static func sweep(keeping kept: Set<String>, now: Date = Date()) -> Int {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        var removed = 0
        for url in files where !kept.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(modified) > sweepGrace else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Restarts a file's grace period: an image back in the composer is held only in memory again.
    static func touch(_ file: String) {
        guard let url = imageURL(file) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// The image files `attachments` point at.
    static func files(_ attachments: [Attachment]) -> [String] {
        attachments.compactMap { if case let .image(file) = $0.content { file } else { nil } }
    }

    /// Downscales and re-encodes an image (turned upright) as a JPEG file; nil when it does not decode.
    static func saveImage(_ data: Data, name: String? = nil) -> Attachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary),
              let directory
        else { return nil }
        let file = "\(UUID().uuidString).jpg"
        let url = directory.appendingPathComponent(file)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Attachment(content: .image(file: file), name: name)
    }

    /// A file the user picked or shared: an image, a PDF's text or a text file; nil for anything else.
    static func file(_ url: URL) -> Attachment? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let name = url.lastPathComponent
        if type.conforms(to: .image) {
            return (try? Data(contentsOf: url)).flatMap { saveImage($0, name: name) }
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { return nil }
        if type.conforms(to: .pdf) {
            guard let text = PDFDocument(url: url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Attachment(content: .text(text), name: name)
        }
        guard type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return Attachment(content: .text(text), name: name)
    }

    /// What another app shares: each provider becomes at most one attachment, the richest it offers.
    static func load(_ providers: [NSItemProvider], title: String? = nil) async -> [Attachment] {
        var result: [Attachment] = []
        for provider in providers {
            if let attachment = await load(provider, title: title) { result.append(attachment) }
        }
        return result
    }

    private static func load(_ provider: NSItemProvider, title: String?) async -> Attachment? {
        let name = provider.suggestedName
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let data = await data(provider, .image) { return saveImage(data, name: name) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            // A file (Files, Mail attachments): copied to a temporary URL that is valid only inside the callback.
            if let attachment = await fileRepresentation(provider) { return attachment }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await object(provider, URL.self) {
            return url.isFileURL ? file(url) : Attachment(content: .link(url), name: title)
        }
        // Copied or selected text comes as a string; only a named document (a shared .txt or .md) keeps its name.
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await object(provider, String.self),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Attachment(content: .text(text), name: provider.suggestedName)
        }
        for type in [UTType.pdf, .text, .json] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if var attachment = await fileRepresentation(provider, type: type) {
                // The file is a temporary copy with a made-up name.
                attachment.name = provider.suggestedName
                return attachment
            }
        }
        return nil
    }

    /// `loadItem` hands over whatever the source registered (often `Data`); this asks for the class itself.
    private static func object<T: _ObjectiveCBridgeable & Sendable>(_ provider: NSItemProvider, _ type: T.Type) async -> T?
        where T._ObjectiveCType: NSItemProviderReading
    {
        guard provider.canLoadObject(ofClass: type) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }

    private static func data(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    private static func fileRepresentation(_ provider: NSItemProvider, type: UTType? = nil) async -> Attachment? {
        let identifier = type?.identifier ?? provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                continuation.resume(returning: url.flatMap(file))
            }
        }
    }
}

/// A share sheet item waiting for PiApp in `<App Group>/inbox/shares/<id>.json`. `id` is made once per share, so it is
/// also the request ID (`share:<id>`): however often the app picks the item up, it is one message.
struct SharedInput: Codable, Sendable, Identifiable {
    let id: String
    var text: String
    var attachments: [Attachment]
    /// nil: a new conversation.
    var conversationId: Int?
    /// Opens in the composer instead of being sent.
    var draft: Bool
    var createdAt = Date()

    var requestId: String { "share:\(id)" }
}

enum ShareInbox {
    static var directory: URL? { try? SharedContainer.directory("inbox/shares") }

    static func write(_ input: SharedInput) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(input).write(to: directory.appendingPathComponent("\(input.id).json"), options: .atomic)
    }

    /// Oldest first. An item stays until `remove`, so a process that dies while sending sends it again (same request).
    static func pending() -> [SharedInput] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(SharedInput.self, from: $0) } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func remove(_ id: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }
}

/// The conversations the share sheet offers, newest first, written by PiApp whenever its list changes.
struct RecentConversation: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let title: String

    static var url: URL? { SharedContainer.url?.appendingPathComponent("inbox/conversations.json") }

    static func read() -> [RecentConversation] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RecentConversation].self, from: data)) ?? []
    }

    static func write(_ items: [RecentConversation]) {
        guard let url, items != read() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: url, options: .atomic)
    }
}
