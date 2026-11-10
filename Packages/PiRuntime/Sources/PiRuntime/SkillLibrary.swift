import Foundation

/// Agent skills (the SKILL.md folder format, agentskills.io) the user imports or writes in Settings › Skills, one folder each
/// under `root` (Application Support `skills/` in the app). Swift owns the files: JS gets the parsed list and reads a
/// skill's text through host calls (`skills.read`, `skills.file`), and every path stays inside the skill's folder.
///
/// What is enforced: a SKILL.md with frontmatter, a `name` that is safe as a
/// folder name and a tool argument, and a `description` short enough for every prompt; no symlinks, no paths out of the
/// folder, and caps on size and file count. Everything else is a warning or ignored: other tools' frontmatter fields
/// are kept but unused, and scripts are kept but never run.
public struct SkillLibrary: Sendable {
    public struct Skill: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var description: String
        /// False with `disable-model-invocation: true`: only "/" runs it, and the prompt does not list it.
        public var modelInvocable: Bool
        /// False with `user-invocable: false`: the "/" menu leaves it out.
        public var userInvocable: Bool
        /// Paths besides SKILL.md, relative to the skill's folder, sorted.
        public var files: [String]
        public var license: String?
        public var compatibility: String?
        /// What the import screen shows: things the spec asks for that this skill doesn't do, and what won't work here.
        public var warnings: [String]

        public var id: String { name }
    }

    /// The parts of SKILL.md: its frontmatter fields (top-level scalars only) and the body after it.
    public struct Document: Sendable, Equatable {
        public var fields: [String: String]
        public var body: String
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static let maxNameLength = 64
    public static let maxDescriptionLength = 1024
    public static let maxTotalBytes = 5 * 1024 * 1024
    public static let maxFiles = 200
    /// The spec suggests a SKILL.md under 500 lines; longer ones get a warning (JS cuts what the model reads).
    public static let suggestedBodyLines = 500
    /// A file read for the model; JS cuts the text further.
    public static let maxReadBytes = 1024 * 1024

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: Parsing

    /// Splits SKILL.md into frontmatter and body. Nil without a `---` frontmatter block at the top.
    public static func parse(_ text: String) -> Document? {
        guard let (front, rest) = split(text) else { return nil }
        let body = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Document(fields: frontmatter(front), body: body)
    }

    /// The frontmatter's lines (between the `---` lines) and the lines after it.
    private static func split(_ text: String) -> (front: [String], rest: [String])? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        return (Array(lines[1..<end]), Array(lines[(end + 1)...]))
    }

    /// The fields the skill editor writes; `compose` replaces them and keeps every other frontmatter line.
    static let editedFields: Set<String> = ["name", "description", "disable-model-invocation", "user-invocable"]

    /// A SKILL.md from the editor's fields. With `original` (the SKILL.md being edited), its other frontmatter fields
    /// (`license`, `metadata`, `allowed-tools`, comments, …) are kept as written, after the edited ones.
    public static func compose(
        name: String, description: String, modelInvocable: Bool, userInvocable: Bool, body: String, keeping original: String? = nil
    ) -> String {
        var lines = ["---", "name: \(name)", "description: \(scalar(description.trimmingCharacters(in: .whitespacesAndNewlines)))"]
        if !modelInvocable { lines.append("disable-model-invocation: true") }
        if !userInvocable { lines.append("user-invocable: false") }
        if let original, let (front, _) = split(original) {
            // Drop the edited keys with their indented continuation lines; keep the rest in order.
            var dropping = false
            for line in front {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let indented = line.first == " " || line.first == "\t"
                if !indented, !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                    dropping = editedFields.contains(line[..<colon].trimmingCharacters(in: .whitespaces))
                } else if !indented, !trimmed.isEmpty {
                    dropping = false
                }
                if !dropping { lines.append(line) }
            }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        }
        lines.append("---")
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n" + (body.isEmpty ? "" : "\n" + body + "\n")
    }

    /// A frontmatter value that `frontmatter` (and YAML) reads back as written: plain when that is safe, a `|` block
    /// over several lines, otherwise single-quoted.
    static func scalar(_ value: String) -> String {
        if value.contains("\n") {
            return "|\n" + value.components(separatedBy: "\n").map { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                return line.isEmpty ? "" : "  " + line
            }.joined(separator: "\n")
        }
        let special = "'\"|>[]{}&*!%@`#-?:,"
        let plain = !value.isEmpty && !special.contains(value.first!) && !value.contains(": ") && !value.contains(" #")
            && !value.hasSuffix(":") && value == value.trimmingCharacters(in: .whitespaces)
            && !["true", "false", "yes", "no", "on", "off", "null", "~"].contains(value.lowercased())
        return plain ? value : "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The YAML that skills use: `key: value` with plain or quoted scalars, `|` and `>` block scalars, plain scalars
    /// continued on indented lines. Nested maps and lists are skipped (their key maps to "").
    static func frontmatter(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var index = 0
        func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard indent(line) == 0, !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // The indented lines that belong to this key.
            var continuation: [String] = []
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty || indent(lines[index]) > 0 {
                continuation.append(lines[index])
                index += 1
            }
            while continuation.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continuation.removeLast() }
            if let style = value.first, style == "|" || style == ">" {
                let block = continuation.map { $0.trimmingCharacters(in: .whitespaces) }
                value = style == "|" ? block.joined(separator: "\n") : folded(block)
            } else if value.isEmpty {
                // A nested map or list (`metadata:`), or nothing.
                value = ""
            } else {
                if !continuation.isEmpty, value.first != "\"", value.first != "'" {
                    value = ([value] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).filter { !$0.isEmpty }.joined(separator: " ")
                } else if !continuation.isEmpty {
                    value = ([value] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
                }
                value = unquoted(value)
            }
            fields[key] = value
        }
        return fields
    }

    private static func folded(_ lines: [String]) -> String {
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.isEmpty { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(line) }
        }
        return paragraphs.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // A trailing comment on a plain scalar.
        if let hash = value.range(of: " #") { return value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
        return value
    }

    /// Lowercase letters, digits and single hyphens, not at either end; at most 64 characters.
    public static func validName(_ name: String) -> Bool {
        guard (1...maxNameLength).contains(name.count), !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    private static func flag(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }

    /// Checks a skill folder and describes it. `folderName`: the name it came under, for the warning when it differs.
    public static func inspect(folder: URL, folderName: String? = nil) throws -> Skill {
        let manager = FileManager.default
        let skillFile = folder.appendingPathComponent("SKILL.md")
        guard manager.fileExists(atPath: skillFile.path) else { throw Failure("There is no SKILL.md in “\(folder.lastPathComponent)”.") }
        let files = try contents(of: folder)
        guard let text = String(data: try Data(contentsOf: skillFile), encoding: .utf8) else { throw Failure("SKILL.md is not UTF-8 text.") }
        guard let document = parse(text) else { throw Failure("SKILL.md has no frontmatter: it must start with a --- block holding name and description.") }
        let name = document.fields["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { throw Failure("SKILL.md's frontmatter has no name.") }
        guard validName(name) else {
            throw Failure("The name “\(name)” must be lowercase letters, digits and single hyphens, not at the start or end, at most \(maxNameLength) characters.")
        }
        let description = document.fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !description.isEmpty else { throw Failure("SKILL.md's frontmatter has no description.") }
        guard description.count <= maxDescriptionLength else {
            throw Failure("The description has \(description.count) characters; at most \(maxDescriptionLength) fit.")
        }
        var warnings: [String] = []
        let folderName = folderName ?? folder.lastPathComponent
        if folderName != name { warnings.append("The folder is named “\(folderName)”, not “\(name)”; it is kept as “\(name)”.") }
        let lines = document.body.components(separatedBy: "\n").count
        if lines > suggestedBodyLines { warnings.append("SKILL.md has \(lines) lines (the spec suggests under \(suggestedBodyLines)); long skills are cut when read.") }
        if files.contains(where: { $0.hasPrefix("scripts/") }) || document.fields["allowed-tools"] != nil {
            warnings.append("Its scripts and allowed-tools are kept but won't run on iPhone; the model can read scripts as text.")
        }
        return Skill(
            name: name,
            description: description,
            modelInvocable: flag(document.fields["disable-model-invocation"]) != true,
            userInvocable: flag(document.fields["user-invocable"]) != false,
            files: files.filter { $0 != "SKILL.md" },
            license: document.fields["license"].flatMap { $0.isEmpty ? nil : $0 },
            compatibility: document.fields["compatibility"].flatMap { $0.isEmpty ? nil : $0 },
            warnings: warnings
        )
    }

    /// Every regular file under `folder`, relative and sorted; hidden files are left out. Throws on a symlink, or when
    /// the folder is over the size or file caps.
    static func contents(of folder: URL) throws -> [String] {
        let manager = FileManager.default
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = manager.enumerator(
            at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { throw Failure("Can't read “\(folder.lastPathComponent)”.") }
        var files: [String] = []
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw Failure("“\(url.lastPathComponent)” is a symbolic link; skills can't have links.") }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { throw Failure("“\(url.lastPathComponent)” is outside the skill's folder.") }
            files.append(String(path.dropFirst(base.count + 1)))
            total += values.fileSize ?? 0
            if files.count > maxFiles { throw Failure("The skill has more than \(maxFiles) files.") }
            if total > maxTotalBytes { throw Failure("The skill is over \(maxTotalBytes / 1024 / 1024) MB.") }
        }
        return files.sorted()
    }

    // MARK: The library

    /// The imported skills, by name. A folder that no longer passes the checks, or isn't named for its skill, is left out.
    public func list() -> [Skill] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return folders
            .compactMap { folder in
                guard let skill = try? Self.inspect(folder: folder), skill.name == folder.lastPathComponent else { return nil }
                return skill
            }
            .sorted { $0.name < $1.name }
    }

    /// Checks a folder (or a single SKILL.md, or any `.md` file with the frontmatter) without importing it.
    public static func preview(_ source: URL) throws -> Skill {
        try withFolder(source) { folder, folderName in try inspect(folder: folder, folderName: folderName) }
    }

    /// Copies a checked skill to `root/<name>/`. With `replace` false, a skill of the same name is an error.
    @discardableResult
    public func importSkill(from source: URL, replace: Bool = false) throws -> Skill {
        try Self.withFolder(source) { folder, folderName in
            let skill = try Self.inspect(folder: folder, folderName: folderName)
            let manager = FileManager.default
            let target = root.appendingPathComponent(skill.name, isDirectory: true)
            if manager.fileExists(atPath: target.path), !replace { throw Failure("A skill named “\(skill.name)” is already installed.") }
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: staging) }
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for path in ["SKILL.md"] + skill.files {
                let destination = staging.appendingPathComponent(path)
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: folder.appendingPathComponent(path), to: destination)
            }
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: target)
            }
            return try Self.inspect(folder: target, folderName: skill.name)
        }
    }

    /// Writes a SKILL.md the user wrote or edited in Settings. With `original`, that skill's folder is the starting
    /// point: its other files are kept, and a new `name` in the text renames it. Checked like an import; a name that
    /// belongs to another installed skill is an error.
    @discardableResult
    public func save(_ source: String, replacing original: String? = nil) throws -> Skill {
        let manager = FileManager.default
        let name = Self.parse(source)?.fields["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        if let original {
            try manager.copyItem(at: try folder(original), to: staging)
        } else {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        try Data(source.utf8).write(to: staging.appendingPathComponent("SKILL.md"), options: .atomic)
        let skill = try Self.inspect(folder: staging, folderName: name)
        let target = root.appendingPathComponent(skill.name, isDirectory: true)
        if skill.name != original, manager.fileExists(atPath: target.path) {
            throw Failure("A skill named “\(skill.name)” is already installed.")
        }
        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: target)
            if let original { try? manager.removeItem(at: root.appendingPathComponent(original, isDirectory: true)) }
        }
        return try Self.inspect(folder: target, folderName: skill.name)
    }

    public func remove(_ name: String) throws {
        guard Self.validName(name) else { throw Failure("No skill named “\(name)”.") }
        try FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
    }

    /// A folder as it is, or a lone Markdown file put in a temporary folder as its SKILL.md.
    private static func withFolder<T>(_ source: URL, _ body: (URL, String) throws -> T) throws -> T {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw Failure("“\(source.lastPathComponent)” is gone.") }
        if isDirectory.boolValue { return try body(source, source.lastPathComponent) }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw Failure("“\(source.lastPathComponent)” is a symbolic link.") }
        guard source.pathExtension.lowercased() == "md" else {
            throw Failure("Pick a skill folder or its SKILL.md. A .zip or .skill file has to be unzipped first (tap it in Files).")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: temporary.appendingPathComponent("SKILL.md"))
        let name = source.deletingPathExtension().lastPathComponent
        return try body(temporary, name == "SKILL" ? source.deletingLastPathComponent().lastPathComponent : name)
    }

    // MARK: Reading, for the host calls

    private func folder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard Self.validName(name), FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else {
            throw Failure("No skill named “\(name)”.")
        }
        return folder
    }

    /// The SKILL.md source, for the Settings page.
    public func source(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: try folder(name).appendingPathComponent("SKILL.md")), as: UTF8.self)
    }

    /// `skills.read`: the body after the frontmatter, and the other files.
    public func read(_ name: String) throws -> (body: String, files: [String]) {
        let folder = try folder(name)
        let text = String(decoding: try Data(contentsOf: folder.appendingPathComponent("SKILL.md")), as: UTF8.self)
        guard let document = Self.parse(text) else { throw Failure("The skill “\(name)” has no frontmatter.") }
        return (document.body, try Self.contents(of: folder).filter { $0 != "SKILL.md" })
    }

    /// `skills.file`: a text file inside the skill's folder, by its relative path.
    public func file(_ name: String, path: String) throws -> String {
        let folder = try folder(name)
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") }) else {
            throw Failure("“\(path)” is not a file of the skill “\(name)”.")
        }
        let url = folder.appendingPathComponent(relative).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(base + "/") else { throw Failure("“\(path)” is outside the skill “\(name)”.") }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            let files = (try? Self.contents(of: folder)) ?? []
            throw Failure("The skill “\(name)” has no file “\(path)”. Its files: \(files.joined(separator: ", ")).")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxReadBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data.dropLast(3), encoding: .utf8) else {
            throw Failure("“\(path)” is not a text file.")
        }
        let cut = (values?.fileSize ?? 0) > Self.maxReadBytes
        return cut ? text + "\n… (the file is longer; the rest is not shown)" : text
    }

    // MARK: Host calls

    public static let handlers: Set<String> = ["skills.read", "skills.file"]

    /// Answers `skills.read` (`{name}` → `{name, body, files}`) and `skills.file` (`{name, path}` → `{text}`).
    public func handle(_ name: String, _ json: String) throws -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let skill = args["name"] as? String ?? ""
        let result: [String: Any]
        switch name {
        case "skills.read":
            let (body, files) = try read(skill)
            result = ["name": skill, "body": body, "files": files]
        case "skills.file":
            result = ["text": try file(skill, path: args["path"] as? String ?? "")]
        default:
            throw Failure("Unknown skill call \(name)")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }
}
