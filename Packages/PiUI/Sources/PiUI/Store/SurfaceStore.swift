import Foundation
import WidgetKit

/// Published specs and `$doc` values in the App Group container. PiApp writes them after the commit that
/// made them; the widget only reads. Files are replaced atomically, so a reader never sees half a spec.
public struct SurfaceStore: Sendable {
    public static let widgetKind = "PiWidget"

    let surfaces: URL
    let snapshots: URL

    public init(root: URL) {
        surfaces = root.appendingPathComponent("surfaces", isDirectory: true)
        snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// The App Group's store; nil when the entitlement is missing.
    public static var shared: SurfaceStore? { SharedContainer.url.map(SurfaceStore.init(root:)) }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func publish(_ surface: PublishedSurface) throws {
        try FileManager.default.createDirectory(at: surfaces, withIntermediateDirectories: true)
        try Self.encoder.encode(surface).write(to: url(surface.publishedId), options: .atomic)
    }

    public func unpublish(_ publishedId: String) throws {
        let url = url(publishedId)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func surface(_ publishedId: String) -> PublishedSurface? {
        guard let data = try? Data(contentsOf: url(publishedId)) else { return nil }
        return try? Self.decoder.decode(PublishedSurface.self, from: data)
    }

    /// Newest first.
    public func published() -> [PublishedSurface] {
        let files = (try? FileManager.default.contentsOfDirectory(at: surfaces, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(PublishedSurface.self, from: Data(contentsOf: $0)) }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    public func writeValues(_ values: [String: JSONValue]) throws {
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try JSONValue.object(["values": .object(values), "updatedAt": .string(DateParsing.format(.now))]).data(pretty: true)
            .write(to: snapshots.appendingPathComponent("values.json"), options: .atomic)
    }

    public func values() -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: snapshots.appendingPathComponent("values.json")) else { return [:] }
        return (try? JSONValue(json: data))?["values"]?.object ?? [:]
    }

    public static func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    private func url(_ publishedId: String) -> URL {
        // IDs are `c<n>-<surfaceId>`; anything path-like is flattened so it cannot leave the directory.
        let safe = publishedId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return surfaces.appendingPathComponent(String(safe) + ".json")
    }
}
