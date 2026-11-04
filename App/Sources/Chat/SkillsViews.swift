import PiRuntime
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Instructions: the user's AGENTS.md. Saved as it is typed (after a pause) and when the screen closes;
/// each conversation's next request has it.
struct InstructionsView: View {
    @Bindable var store: ChatStore
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 320)
                    .accessibilityIdentifier("instructions.editor")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Markdown, as in an AGENTS.md. Pi reads it at the start of every conversation and follows it; what you ask in a conversation comes first. Only you can change it.")
                    if text.count > InstructionsFile.promptLimit {
                        Text("Pi gets the first \(InstructionsFile.promptLimit.formatted()) characters of \(text.count.formatted()).")
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(text.count.formatted()) of \(InstructionsFile.promptLimit.formatted()) characters").monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            text = store.instructions
            loaded = true
        }
        .task(id: text) {
            guard loaded else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await store.setInstructions(text)
        }
        .onDisappear {
            let text = text
            Task { await store.setInstructions(text) }
        }
    }
}

/// Settings › Skills: the installed skills, buttons to write or import one, and each skill's page.
struct SkillsView: View {
    @Bindable var store: ChatStore
    @State private var importing = false
    @State private var creating = false
    /// A picked skill whose name is already installed, waiting for Replace.
    @State private var replacing: (url: URL, name: String)?
    @State private var failure: String?
    @State private var imported: SkillLibrary.Skill?

    var body: some View {
        List {
            Section {
                ForEach(store.skills) { skill in
                    NavigationLink {
                        SkillDetailView(store: store, skill: skill)
                    } label: {
                        SkillRow(skill: skill)
                    }
                }
                .onDelete { offsets in
                    let names = offsets.map { store.skills[$0].name }
                    Task { for name in names { await store.removeSkill(name) } }
                }
                Button("New Skill", systemImage: "square.and.pencil") { creating = true }
                    .accessibilityIdentifier("skills.new")
                Button("Import Skill…", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("skills.import")
            } footer: {
                Text("A skill is a folder with a SKILL.md: instructions, and files they refer to. Pi reads one when a task matches its description, or you run it by typing / in a message. Write one here, or import one from Files. Scripts in a skill don't run on iPhone. Unzip a .zip or .skill file in Files first. Only you can add or change skills.")
            }
        }
        .navigationTitle("Skills")
        .overlay {
            if store.skills.isEmpty {
                ContentUnavailableView("No Skills", systemImage: "book.closed", description: Text("Write a skill, or import a skill folder or a SKILL.md from Files."))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { SkillEditorView(store: store, original: nil) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types) { result in
            guard case let .success(url) = result else { return }
            pick(url)
        }
        .confirmationDialog(
            "Replace “\(replacing?.name ?? "")”?",
            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let replacing { run(replacing.url, replace: true) }
                replacing = nil
            }
        } message: {
            Text("A skill with this name is installed. Messages that already ran it keep what they sent.")
        }
        .alert("Can't import the skill", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .alert(
            "Imported “\(imported?.name ?? "")”",
            isPresented: Binding(get: { imported.map { !$0.warnings.isEmpty } ?? false }, set: { if !$0 { imported = nil } })
        ) {
            Button("OK") { imported = nil }
        } message: {
            Text(imported?.warnings.joined(separator: "\n\n") ?? "")
        }
    }

    /// Folders, and Markdown files (a lone SKILL.md).
    static let types: [UTType] = [.folder, UTType(filenameExtension: "md") ?? .plainText, .plainText]

    private func pick(_ url: URL) {
        do {
            let skill = try SkillLibrary.preview(url)
            if store.skills.contains(where: { $0.name == skill.name }) {
                replacing = (url, skill.name)
            } else {
                run(url, replace: false)
            }
        } catch {
            failure = String(describing: error)
        }
    }

    private func run(_ url: URL, replace: Bool) {
        Task {
            do { imported = try await store.importSkill(from: url, replace: replace) } catch { failure = String(describing: error) }
        }
    }
}

private struct SkillRow: View {
    let skill: SkillLibrary.Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(skill.name).font(.body.monospaced())
                if !skill.modelInvocable {
                    Text("/ only").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: .capsule)
                }
                if !skill.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// One skill: what the model sees, how it runs, its files, and its SKILL.md as written. Edit opens the editor; a
/// rename there keeps this page on the skill.
struct SkillDetailView: View {
    @Bindable var store: ChatStore
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var removing = false
    /// The skill as it was when Edit was tapped, so a rename doesn't empty the sheet before it closes.
    @State private var editing: SkillLibrary.Skill?

    init(store: ChatStore, skill: SkillLibrary.Skill) {
        self.store = store
        _name = State(initialValue: skill.name)
    }

    private var skill: SkillLibrary.Skill? { store.skills.first { $0.name == name } }

    var body: some View {
        Group {
            if let skill { form(skill) } else { ContentUnavailableView("Skill Removed", systemImage: "book.closed") }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let skill {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = skill }
                        .accessibilityIdentifier("skill.edit")
                }
            }
        }
        .sheet(item: $editing) { skill in
            NavigationStack {
                SkillEditorView(store: store, original: skill) { saved in
                    // `Skill` holds no body, so an instructions-only edit leaves it equal: reload here.
                    name = saved.name
                    source = (try? store.skillLibrary.source(saved.name)) ?? ""
                }
            }
        }
        .task(id: skill) { source = (try? store.skillLibrary.source(name)) ?? "" }
    }

    private func form(_ skill: SkillLibrary.Skill) -> some View {
        Form {
            Section("Description") {
                Text(skill.description)
            }
            Section {
                LabeledContent("Pi reads it when it fits", value: skill.modelInvocable ? "Yes" : "No")
                LabeledContent("In the / menu", value: skill.userInvocable ? "Yes" : "No")
                if let license = skill.license { LabeledContent("License", value: license) }
                if let compatibility = skill.compatibility { LabeledContent("Compatibility", value: compatibility) }
            } footer: {
                Text("Set with disable-model-invocation and user-invocable in its frontmatter.")
            }
            if !skill.warnings.isEmpty {
                Section("Notes") {
                    ForEach(skill.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            if !skill.files.isEmpty {
                Section("Files") {
                    ForEach(skill.files, id: \.self) { file in
                        Text(file).font(.footnote.monospaced())
                    }
                }
            }
            Section("SKILL.md") {
                Text(source)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Section {
                Button("Remove Skill", role: .destructive) { removing = true }
            }
        }
        .confirmationDialog("Remove “\(skill.name)”?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await store.removeSkill(skill.name)
                    dismiss()
                }
            }
        } message: {
            Text("Messages that already ran it keep what they sent.")
        }
    }
}

/// Writes a new skill or edits one: its name, description, how it runs, and its instructions (the SKILL.md body).
/// Saving composes the SKILL.md (`SkillLibrary.compose`, keeping other frontmatter fields of an edited skill) and checks
/// it like an import; an edited skill keeps its other files.
struct SkillEditorView: View {
    @Bindable var store: ChatStore
    /// The skill being edited; nil for a new one.
    let original: SkillLibrary.Skill?
    var saved: (SkillLibrary.Skill) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var modelInvocable = true
    @State private var userInvocable = true
    @State private var instructions = ""
    /// The SKILL.md being edited, as read when the editor opened.
    @State private var source: String?
    @State private var initial: [String] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: String?

    private var fields: [String] { [name, summary, String(modelInvocable), String(userInvocable), instructions] }
    private var changed: Bool { loaded && fields != initial }
    private var trimmedSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameProblem: String? {
        if name.isEmpty { return nil }
        if !SkillLibrary.validName(name) {
            return "Lowercase letters, digits and single hyphens, not at the start or end, at most \(SkillLibrary.maxNameLength) characters."
        }
        if name != original?.name, store.skills.contains(where: { $0.name == name }) { return "A skill named “\(name)” is installed." }
        return nil
    }

    private var canSave: Bool {
        !saving && changed && !name.isEmpty && nameProblem == nil && !trimmedSummary.isEmpty
            && trimmedSummary.count <= SkillLibrary.maxDescriptionLength
    }

    var body: some View {
        Form {
            Section {
                TextField("name", text: $name)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("skill.editor.name")
            } header: {
                Text("Name")
            } footer: {
                if let nameProblem {
                    Text(nameProblem).foregroundStyle(.orange)
                } else if let original, name != original.name, !name.isEmpty {
                    Text("Renames “\(original.name)”. Type /\(name) to run it.")
                } else {
                    Text("You run it by typing /\(name.isEmpty ? "name" : name).")
                }
            }
            Section {
                TextField("What it does, and when Pi should use it", text: $summary, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("skill.editor.description")
            } header: {
                Text("Description")
            } footer: {
                if trimmedSummary.count > SkillLibrary.maxDescriptionLength {
                    Text("\(trimmedSummary.count.formatted()) of \(SkillLibrary.maxDescriptionLength.formatted()) characters").foregroundStyle(.orange)
                } else {
                    Text("Every conversation's prompt lists it, so Pi knows when the skill fits.")
                }
            }
            Section {
                Toggle("Pi reads it when it fits", isOn: $modelInvocable)
                Toggle("In the / menu", isOn: $userInvocable)
            } footer: {
                Text(modelInvocable ? "Pi may read the skill on its own when a task matches the description." : "Only you run it, with /; the prompt doesn't list it.")
            }
            Section {
                TextEditor(text: $instructions)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 280)
                    .overlay(alignment: .topLeading) {
                        if instructions.isEmpty {
                            Text("Markdown: the steps to follow. $ARGUMENTS is replaced with what you type after /\(name.isEmpty ? "name" : name).")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("skill.editor.instructions")
            } header: {
                Text("Instructions")
            } footer: {
                let lines = instructions.isEmpty ? 0 : instructions.components(separatedBy: "\n").count
                if lines > SkillLibrary.suggestedBodyLines {
                    Text("\(lines.formatted()) lines; skills over \(SkillLibrary.suggestedBodyLines) lines are cut when read.").foregroundStyle(.orange)
                } else if let original, !original.files.isEmpty {
                    Text("Its other files (\(original.files.count.formatted())) are kept. Messages that already ran the skill keep what they sent.")
                } else if original != nil {
                    Text("Messages that already ran the skill keep what they sent.")
                }
            }
        }
        .navigationTitle(original == nil ? "New Skill" : "Edit Skill")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(changed)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
                    .accessibilityIdentifier("skill.editor.save")
            }
        }
        .onChange(of: name) {
            // Names are folder names and "/" commands: lowercase, hyphens for spaces.
            let normalized = name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
            if normalized != name { name = normalized }
        }
        .onAppear(perform: load)
        .alert("Can't save the skill", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func load() {
        guard !loaded else { return }
        if let original {
            let text = (try? store.skillLibrary.source(original.name)) ?? ""
            source = text
            name = original.name
            summary = original.description
            modelInvocable = original.modelInvocable
            userInvocable = original.userInvocable
            instructions = SkillLibrary.parse(text)?.body ?? ""
        }
        initial = fields
        loaded = true
    }

    private func save() {
        let text = SkillLibrary.compose(
            name: name, description: trimmedSummary, modelInvocable: modelInvocable, userInvocable: userInvocable,
            body: instructions, keeping: source
        )
        saving = true
        Task {
            defer { saving = false }
            do {
                let skill = try await store.saveSkill(text, replacing: original?.name)
                saved(skill)
                dismiss()
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

/// The composer's "/" menu: skills whose name starts with (or contains) what follows the slash.
struct SkillSuggestions: View {
    let skills: [SkillLibrary.Skill]
    let pick: (SkillLibrary.Skill) -> Void

    /// The query when the draft is a "/" command being typed: "/" and name characters, nothing else yet.
    static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return rest.lowercased()
    }

    static func matches(_ skills: [SkillLibrary.Skill], _ query: String) -> [SkillLibrary.Skill] {
        let starts = skills.filter { $0.name.hasPrefix(query) }
        let contains = skills.filter { !$0.name.hasPrefix(query) && $0.name.contains(query) }
        return Array((starts + contains).prefix(6))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                if index > 0 { Divider().padding(.leading, 16) }
                Button { pick(skill) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(skill.name)").font(.body.monospaced())
                        Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("skill.suggestion.\(skill.name)")
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The skill a message will run, in the composer over the text; × takes it off.
struct SkillChip: View {
    let name: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "book.closed.fill").font(.caption)
            Text("/\(name)").font(.subheadline.monospaced())
            Button("Remove skill", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityIdentifier("skill.chip.remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.15), in: .capsule)
        .foregroundStyle(.tint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill.chip")
    }
}

/// The skill a sent message ran, above its bubble; a tap shows the skill if it is still installed.
struct SentSkillChip: View {
    let store: ChatStore
    let name: String
    @State private var showing = false

    private var skill: SkillLibrary.Skill? { store.skills.first { $0.name == name } }

    var body: some View {
        Button { showing = true } label: {
            Label("/\(name)", systemImage: "book.closed.fill")
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(skill == nil)
        .sheet(isPresented: $showing) {
            if let skill {
                NavigationStack {
                    SkillDetailView(store: store, skill: skill)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showing = false } } }
                }
            }
        }
        .accessibilityIdentifier("sent.skill")
    }
}
