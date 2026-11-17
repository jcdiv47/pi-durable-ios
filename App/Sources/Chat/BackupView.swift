import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup & Export: a backup archive of everything Pi keeps (`Backup`), to share or save in Files, and a
/// restore from one.
struct BackupView: View {
    @Bindable var store: ChatStore
    @State private var archive: URL?
    @State private var working: String?
    @State private var failure: String?
    @State private var importing = false
    @State private var staged: Backup.Manifest?
    @State private var restoring = false

    private static let archiveType = UTType(filenameExtension: "aar") ?? .data

    private var lastBackup: Date? { UserDefaults.standard.object(forKey: Backup.lastBackupKey) as? Date }

    var body: some View {
        Form {
            Section {
                if let archive {
                    ShareLink(item: archive) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Share or Save \(archive.lastPathComponent)")
                                if let size = try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                    Text(Int64(size).formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                Button {
                    Task { await makeBackup() }
                } label: {
                    HStack {
                        Label(archive == nil ? "Create Backup" : "Create Another Backup", systemImage: "externaldrive.badge.plus")
                        Spacer()
                        if working == "backup" { ProgressView() }
                    }
                }
                .disabled(working != nil || store.phase != .ready)
                .accessibilityIdentifier("backup.create")
            } header: {
                Text("Back Up")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One file with every conversation (archived ones too, and each as Markdown to read anywhere), attachments, voice recordings, widgets, your instructions, skills, MCP servers, SSH hosts and settings. Save it in Files or on a Mac before you reinstall Pi or its profile runs out.")
                    Text("API keys, tokens, SSH passwords and keys stay in this iPhone's Keychain and are not in the backup: enter them again after a restore.")
                    if let lastBackup {
                        Text("Last backup \(lastBackup.formatted(date: .abbreviated, time: .shortened)).")
                    }
                }
            }

            Section {
                Button {
                    importing = true
                } label: {
                    HStack {
                        Label("Restore from Backup…", systemImage: "arrow.counterclockwise")
                        Spacer()
                        if working == "restore" { ProgressView() }
                    }
                }
                .disabled(working != nil)
                .accessibilityIdentifier("backup.restore")
            } header: {
                Text("Restore")
            } footer: {
                Text("Replaces the conversations on this iPhone with the backup's. Pi closes to restore it; open Pi again to finish.")
            }
        }
        .navigationTitle("Backup & Export")
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.archiveType]) { result in
            switch result {
            case let .success(url): Task { await stage(url) }
            case let .failure(error): failure = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { staged != nil }, set: { if !$0, !restoring { staged = nil; Backup.discardStaged() } }),
            titleVisibility: .visible,
            presenting: staged
        ) { _ in
            Button("Restore and Close Pi", role: .destructive) { Task { await restore() } }
            Button("Cancel", role: .cancel) {
                staged = nil
                Backup.discardStaged()
            }
        } message: { manifest in
            Text("From \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened)): \(manifest.conversations) conversations and \(manifest.archived) archived. They replace every conversation on this iPhone. Pi closes now; open it again to finish.")
        }
        .alert("Backup", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func makeBackup() async {
        working = "backup"
        defer { working = nil }
        do {
            archive = try await Backup.export(store)
            store.diagnostics.record("info", "backup", "Created \(archive!.lastPathComponent)")
        } catch {
            failure = "Couldn't create the backup: \(error.localizedDescription)"
            store.diagnostics.record("error", "backup", "Backup failed: \(error)")
        }
    }

    private func stage(_ url: URL) async {
        working = "restore"
        defer { working = nil }
        do {
            staged = try await Backup.stage(url)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func restore() async {
        restoring = true
        do {
            try Backup.commitStaged()
        } catch {
            restoring = false
            staged = nil
            failure = "Couldn't restore: \(error.localizedDescription)"
            return
        }
        store.diagnostics.record("info", "backup", "Restore staged; closing Pi")
        await store.closeForRestore()
        // The restore runs at the next launch, before Pi opens its storage.
        exit(0)
    }
}

/// A conversation as a Markdown file for `ShareLink`; the file is written when the share sheet asks for it.
struct ConversationMarkdown: Transferable {
    let id: Int
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType("net.daringfireball.markdown") ?? .plainText) { export in
            SentTransferredFile(try await ChatStore.ready().markdownFile(export.id))
        }
        .suggestedFileName { "\($0.title).md" }
    }
}

extension View {
    /// Asks before deleting `meta`'s conversation; `deleted` runs once it is gone (a conversation's own view pops itself).
    func deleteConversationDialog(_ meta: Binding<ConversationMeta?>, store: ChatStore, deleted: @escaping () -> Void = {}) -> some View {
        // An alert, not a confirmation dialog: these views attach it to a whole list, and iOS 26 draws a confirmation
        // dialog there as a popover pointing at the list's middle, whichever row was swiped, with no Cancel.
        alert(
            "Delete “\(meta.wrappedValue?.title ?? "")”?",
            isPresented: Binding(get: { meta.wrappedValue != nil }, set: { if !$0 { meta.wrappedValue = nil } }),
            presenting: meta.wrappedValue
        ) { target in
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(target.id)
                    deleted()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Pi stops its work and scheduled tasks, takes its widgets off the Home Screen, and removes its attachments and voice recordings. This can't be undone; archive it instead to keep it.")
        }
    }
}
