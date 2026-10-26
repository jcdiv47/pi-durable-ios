import Foundation

/// The App Group container shared by PiApp and its extensions. Only PiApp opens `pi/`; extensions
/// read the JSON PiApp exports to `surfaces/` and `snapshots/`.
public enum SharedContainer {
    public static let groupIdentifier = "group.dev.jcdiv47.pidurable"

    /// nil when the App Group entitlement is missing from the signed binary.
    public static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    public static func directory(_ name: String) throws -> URL {
        guard let url else { throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "App Group \(groupIdentifier) is unavailable"]) }
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
