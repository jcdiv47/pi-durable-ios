import Foundation
import Testing
@testable import PiRuntime

/// Writes a skill folder: `files` maps relative paths to contents.
func writeSkill(_ files: [String: String], in directory: URL, folder: String) throws -> URL {
    let root = directory.appendingPathComponent(folder, isDirectory: true)
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

let groceriesSkill = """
---
name: groceries
description: >
  Plan the week's groceries
  from the calendar.
license: MIT
metadata:
  author: me
  version: "1.0"
---
# Groceries

Check the calendar for dinners at home, then list what to buy.
"""

@Suite("Skills: parsing, checks and the library")
struct SkillLibraryTests {
    @Test("Frontmatter: plain, quoted and block scalars, flags, nested maps skipped")
    func frontmatter() throws {
        let document = try #require(SkillLibrary.parse("""
        ---
        name: "code-review"
        description: |
          Review a diff.
          Look for bugs.
        disable-model-invocation: true
        user-invocable: no
        compatibility: 'Needs ''git'''
        allowed-tools:
          - Bash
        argument-hint: [file] # a comment
        ---

        Body text.
        """))
        #expect(document.fields["name"] == "code-review")
        #expect(document.fields["description"] == "Review a diff.\nLook for bugs.")
        #expect(document.fields["compatibility"] == "Needs 'git'")
        #expect(document.fields["allowed-tools"] == "")
        #expect(document.fields["argument-hint"] == "[file]")
        #expect(document.body == "Body text.")
        #expect(SkillLibrary.parse("# No frontmatter\n") == nil)
        #expect(SkillLibrary.parse("---\nname: x\n") == nil, "an unclosed block is not frontmatter")
    }

    @Test("Names: lowercase letters, digits and single hyphens")
    func names() {
        for good in ["a", "pdf-tools", "x2", String(repeating: "a", count: 64)] { #expect(SkillLibrary.validName(good), "\(good)") }
        for bad in ["", "-a", "a-", "a--b", "PDF", "a_b", "a b", "../x", String(repeating: "a", count: 65)] {
            #expect(!SkillLibrary.validName(bad), "\(bad)")
        }
    }

    @Test("Import: required fields rejected, the rest warned about or kept; replacing asks")
    func importChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SkillLibrary(root: directory.appendingPathComponent("skills"))

        let source = try writeSkill(
            ["SKILL.md": groceriesSkill, "references/stores.md": "Aldi, Lidl", "scripts/sum.py": "print(1)", ".DS_Store": "x"],
            in: directory, folder: "Groceries-main"
        )
        let preview = try SkillLibrary.preview(source)
        #expect(preview.name == "groceries")
        #expect(preview.description == "Plan the week's groceries from the calendar.")
        #expect(preview.license == "MIT")
        #expect(preview.files == ["references/stores.md", "scripts/sum.py"], "hidden files are left out")
        #expect(preview.modelInvocable && preview.userInvocable)
        #expect(preview.warnings.count == 2, "folder name and scripts: \(preview.warnings)")

        let skill = try library.importSkill(from: source)
        #expect(skill.warnings.count == 1, "kept under its own name, so only the scripts warning stays")
        #expect(library.list().map(\.name) == ["groceries"])
        #expect(throws: SkillLibrary.Failure.self) { try library.importSkill(from: source) }
        try library.importSkill(from: source, replace: true)

        func rejects(_ files: [String: String], _ message: String) throws {
            let folder = try writeSkill(files, in: directory, folder: "bad-\(UUID().uuidString)")
            #expect(throws: SkillLibrary.Failure.self, "\(message)") { try SkillLibrary.preview(folder) }
        }
        try rejects(["README.md": "no skill"], "no SKILL.md")
        try rejects(["SKILL.md": "# Title only"], "no frontmatter")
        try rejects(["SKILL.md": "---\ndescription: d\n---\n"], "no name")
        try rejects(["SKILL.md": "---\nname: My Skill\ndescription: d\n---\n"], "bad name")
        try rejects(["SKILL.md": "---\nname: ok\n---\n"], "no description")
        try rejects(["SKILL.md": "---\nname: ok\ndescription: \(String(repeating: "d", count: 1025))\n---\n"], "long description")

        let linked = try writeSkill(["SKILL.md": "---\nname: linked\ndescription: d\n---\n"], in: directory, folder: "linked")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("secret"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: SkillLibrary.Failure.self) { try SkillLibrary.preview(linked) }

        // A lone Markdown file is a skill with no other files.
        let lone = directory.appendingPathComponent("tidy.md")
        try "---\nname: tidy\ndescription: Tidy a note.\ndisable-model-invocation: true\n---\nTidy it.".write(to: lone, atomically: true, encoding: .utf8)
        let tidy = try library.importSkill(from: lone)
        #expect(tidy.files.isEmpty && !tidy.modelInvocable && tidy.warnings.isEmpty)
        #expect(library.list().map(\.name) == ["groceries", "tidy"])
        try library.remove("tidy")
        #expect(library.list().map(\.name) == ["groceries"])
    }

    @Test("Reads stay inside the skill's folder")
    func reads() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SkillLibrary(root: directory.appendingPathComponent("skills"))
        try library.importSkill(from: try writeSkill(["SKILL.md": groceriesSkill, "references/stores.md": "Aldi, Lidl"], in: directory, folder: "groceries"))
        try "outside".write(to: directory.appendingPathComponent("skills/secret.txt"), atomically: true, encoding: .utf8)

        let (body, files) = try library.read("groceries")
        #expect(body.hasPrefix("# Groceries"))
        #expect(files == ["references/stores.md"])
        #expect(try library.file("groceries", path: "references/stores.md") == "Aldi, Lidl")
        #expect(try library.file("groceries", path: "/references/stores.md") == "Aldi, Lidl")
        for path in ["../secret.txt", "references/../../secret.txt", "", ".", "missing.md", "references"] {
            #expect(throws: SkillLibrary.Failure.self, "\(path)") { try library.file("groceries", path: path) }
        }
        #expect(throws: SkillLibrary.Failure.self) { try library.read("../skills") }
        #expect(throws: SkillLibrary.Failure.self) { try library.read("nope") }

        let json = try library.handle("skills.read", #"{"name":"groceries"}"#)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["files"] as? [String] == ["references/stores.md"])
    }
}

@Suite("Instructions and skills inside JavaScriptCore", .serialized)
struct SkillChatTests {
    func open(_ log: ChatLog, directory: URL, instructions: String) async throws -> (PiHarness, SkillLibrary) {
        let library = SkillLibrary(root: directory.appendingPathComponent("skills"))
        try library.importSkill(from: try writeSkill(["SKILL.md": groceriesSkill, "references/stores.md": "Aldi, Lidl"], in: directory, folder: "groceries"))
        try library.importSkill(from: try writeSkill([
            "SKILL.md": "---\nname: tidy\ndescription: Tidy a note.\ndisable-model-invocation: true\n---\nTidy this note: $ARGUMENTS",
        ], in: directory, folder: "tidy"))
        let (_, url) = try bundledScript("pi-runtime")
        let harness = try await PiHarness.load(bundle: url, options: .init(
            onEvent: { log.handle($0) },
            onLog: { level, message in if level == "error" || level == "warn" { print("[js \(level)] \(message)") } },
            hostCall: { name, json in
                log.record(name, json)
                if SkillLibrary.handlers.contains(name) { return try library.handle(name, json) }
                throw JSRuntimeError("unexpected host call \(name)")
            }
        ))
        _ = try await harness.open(.init(
            dbPath: directory.appendingPathComponent("chat.sqlite").path, provider: "faux", modelId: "killtest",
            instructions: instructions, skills: library.list()
        ))
        return (harness, library)
    }

    func answer(_ log: ChatLog, _ id: Int, after count: Int) async throws -> String {
        try await until { log.items(id).count >= count && !log.busy(id) && log.last(id, kind: "assistant") != nil }
        return log.last(id, kind: "assistant")?["text"] as? String ?? ""
    }

    @Test("Instructions are a prompt section; an edit applies from the next request", .timeLimit(.minutes(1)))
    func instructions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let (harness, _) = try await open(log, directory: directory, instructions: "Use metric units.")
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "section user_instructions", "r1"])
        #expect(try await answer(log, meta.id, after: 2).contains("Use metric units."))

        try await harness.perform("PiRuntime.setInstructions", ["Answer in French."])
        try await harness.perform("PiRuntime.send", [meta.id, "section user_instructions", "r2"])
        let edited = try await answer(log, meta.id, after: 4)
        #expect(edited.contains("Answer in French.") && !edited.contains("metric"))

        try await harness.perform("PiRuntime.setInstructions", ["  "])
        try await harness.perform("PiRuntime.send", [meta.id, "section user_instructions", "r3"])
        #expect(try await answer(log, meta.id, after: 6) == "Section user_instructions: (none)")
        try await harness.close()
    }

    @Test("The prompt lists skills the model may run; skill_read and skill_file go through Swift", .timeLimit(.minutes(1)))
    func modelReads() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let (harness, _) = try await open(log, directory: directory, instructions: "")
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "section skills", "r1"])
        let listed = try await answer(log, meta.id, after: 2)
        #expect(listed.contains("- groceries: Plan the week's groceries from the calendar."))
        #expect(!listed.contains("tidy"), "a skill with disable-model-invocation is not listed")

        try await harness.perform("PiRuntime.send", [meta.id, "skill groceries", "r2"])
        let read = try await answer(log, meta.id, after: 6)
        #expect(read.contains("skill_read: ok"), "\(read)")
        let result = try #require(log.last(meta.id, kind: "toolResult")?["text"] as? String)
        #expect(result.contains("# Groceries") && result.contains("references/stores.md"))

        try await harness.perform("PiRuntime.send", [meta.id, "skill tidy", "r3"])
        #expect(try await answer(log, meta.id, after: 10).contains("skill_read: error"), "only the user runs tidy")

        try await harness.perform("PiRuntime.send", [meta.id, "skillfile groceries references/stores.md", "r4"])
        #expect(try await answer(log, meta.id, after: 14).contains("Aldi, Lidl"))
        try await harness.perform("PiRuntime.send", [meta.id, "skillfile groceries ../../chat.sqlite", "r5"])
        #expect(try await answer(log, meta.id, after: 18).contains("skill_file: error"))
        try await harness.close()
    }

    @Test("A \"/\" run puts the skill's body in the message; the bubble shows its name; take back keeps it", .timeLimit(.minutes(1)))
    func slashRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let (harness, library) = try await open(log, directory: directory, instructions: "")
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])

        try await harness.perform("PiRuntime.send", [meta.id, "for Sunday", "r1", [] as [String], "groceries"])
        let echoed = try await answer(log, meta.id, after: 2)
        #expect(echoed.contains("<skill name=\"groceries\">") && echoed.contains("Check the calendar") && echoed.hasSuffix("for Sunday"))
        let user = try #require(log.last(meta.id, kind: "user"))
        #expect(user["text"] as? String == "for Sunday" && user["skill"] as? String == "groceries")
        #expect(log.titles == ["for Sunday"])

        // $ARGUMENTS takes the typed text in place, as written ("$&" is not a replacement pattern).
        try await harness.perform("PiRuntime.send", [meta.id, "milk $& eggs", "r2", [] as [String], "tidy"])
        let tidy = try await answer(log, meta.id, after: 4)
        #expect(tidy.contains("Tidy this note: milk $& eggs") && !tidy.contains("$ARGUMENTS"))

        // The message keeps the skill as it was sent, even after it is removed.
        try library.remove("tidy")
        try await harness.perform("PiRuntime.setSkills", [try library.list().map { try harness.jsonArgument($0) }])
        let frame = try await harness.runtime.callAsync("PiRuntime.transcript", [meta.id])
        #expect(frame.contains("\"skill\":\"tidy\""))

        // Queued behind a slow answer, a skill run comes back with its skill and attachments.
        try await harness.perform("PiRuntime.send", [meta.id, "slow please", "r3"])
        try await until { log.liveText(meta.id).count > 20 }
        let link: [[String: any Sendable]] = [["kind": "link", "url": "https://example.com", "title": "Example"]]
        try await harness.perform("PiRuntime.send", [meta.id, "", "r4", link, "groceries"])
        try await until { log.queue(meta.id).count == 1 }
        #expect(log.queue(meta.id)[0]["text"] as? String == "/groceries (📎 1 link)")
        let json = try await harness.runtime.callAsync("PiRuntime.takeBack", [meta.id, log.queue(meta.id)[0]["id"] as! Int])
        let taken = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(taken["skill"] as? String == "groceries" && taken["text"] as? String == "")
        #expect((taken["attachments"] as? [[String: Any]])?.first?["url"] as? String == "https://example.com")

        // A skill that is gone can't be run.
        await #expect(throws: (any Error).self) { try await harness.perform("PiRuntime.send", [meta.id, "x", "r5", [] as [String], "tidy"]) }
        try await harness.close()
    }
}
