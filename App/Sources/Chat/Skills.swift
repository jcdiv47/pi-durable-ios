import Foundation
import PiRuntime

/// Settings › Instructions: the user's AGENTS.md, in Application Support. Only the user writes it, in Settings.
enum InstructionsFile {
    /// Longer text is kept but cut in the prompt (`MAX_INSTRUCTIONS_CHARS` in instructions.ts).
    static let promptLimit = 16_000

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AGENTS.md")
    }

    static func load() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func save(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension SkillLibrary {
    /// Application Support `skills/`: one folder per skill, named for it.
    static var appRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("skills", isDirectory: true)
    }
}
