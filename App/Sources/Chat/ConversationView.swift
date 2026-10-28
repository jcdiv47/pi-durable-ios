import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var store: ChatStore
    let conversationId: Int
    @Binding var path: [Route]
    @State private var draft = ""
    /// Photos, pasted things and files for the next message.
    @State private var attachments: [Attachment] = []
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    /// Attachments being read and downscaled.
    @State private var attaching = 0
    @FocusState private var composing: Bool
    /// Queued messages with a withdraw or steer in flight.
    @State private var queueActions: Set<Int> = []

    private var state: ConversationState { store.state(conversationId) }
    private var meta: ConversationMeta? { store.conversations.first { $0.id == conversationId } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a LazyVStack's estimated row heights put the bottom anchor short of the end on open.
                VStack(alignment: .leading, spacing: 12) {
                    if let fork = meta?.forkOf {
                        Label("Forked from \(store.conversations.first { $0.id == fork.conversationId }?.title ?? "a conversation")", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(TranscriptRow.rows(state.items)) { row in
                        switch row {
                        case let .item(item, resent):
                            TranscriptItemView(item: item, state: state, store: store, resent: resent)
                                .contextMenu { itemMenu(item) }
                        case let .work(_, steps):
                            WorkRow(steps: steps, state: state, store: store)
                        }
                    }
                    LiveView(state: state, store: store)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: state.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: state.live.generation?.text.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) {
                // Queued messages and longer drafts grow the composer; once laid out, keep the newest entry above it.
                composer.onGeometryChange(for: CGFloat.self, of: \.size.height) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .overlay {
            if state.loaded && state.items.isEmpty && !state.live.busy {
                ContentUnavailableView("Ask Pi anything", systemImage: "sparkles", description: Text(store.modelName(state.model)))
            }
        }
        .navigationTitle(meta?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
        }
        .onAppear { store.watch(conversationId) }
        .onChange(of: store.drafts[conversationId], initial: true) { takeDraft() }
    }

    /// A share sheet item opened to edit: its text goes ahead of anything typed, its attachments after the ones here.
    private func takeDraft() {
        guard let shared = store.takeDraft(conversationId) else { return }
        draft = [shared.text, draft].filter { !$0.isEmpty }.joined(separator: "\n")
        attachments += shared.attachments
        composing = true
    }

    /// The title, and under it the model, or while a run goes how long it has been working, or that it waits for you.
    private var header: some View {
        VStack(spacing: 0) {
            Text(meta?.title ?? "Conversation").font(.headline).lineLimit(1)
            Group {
                if store.approvals.contains(where: { $0.conversationId == conversationId }) {
                    Text("Waiting for you").foregroundStyle(.orange)
                } else if state.live.busy, let since = state.busySince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Working · \(WorkRow.elapsed(context.date.timeIntervalSince(since)))").monospacedDigit()
                    }
                } else {
                    Text(store.modelName(state.model))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.header")
    }

    @ViewBuilder private func itemMenu(_ item: DisplayItem) -> some View {
        if let text = item.text, !text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
        if item.kind == .assistant || item.kind == .user {
            Button("Fork from here", systemImage: "arrow.triangle.branch") {
                Task {
                    if let fork = await store.fork(conversationId, at: item.id) { path.append(.conversation(fork.id)) }
                }
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(Dictionary(grouping: store.models, by: \.providerName).sorted { $0.key < $1.key }, id: \.key) { provider, models in
                Section(provider) {
                    ForEach(models.prefix(40)) { model in
                        Button {
                            Task { await store.setModel(model.ref, for: conversationId) }
                        } label: {
                            if model.ref == state.model { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                        }
                    }
                }
            }
        } label: {
            Label(store.modelName(state.model), systemImage: "cpu")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("model.menu")
    }

    /// How hard the model thinks, from the levels it supports; hidden for models without reasoning.
    @ViewBuilder private var effortMenu: some View {
        let levels = store.model(state.model)?.thinkingLevels ?? []
        if levels.count > 1 {
            Menu {
                Picker("Effort", selection: Binding(
                    get: { state.thinkingLevel },
                    set: { level in Task { await store.setThinking(level, for: conversationId) } }
                )) {
                    ForEach(levels, id: \.self) { level in
                        Label(ThinkingLevel.name(level), systemImage: ThinkingLevel.symbol(level)).tag(level)
                    }
                }
            } label: {
                Label(ThinkingLevel.name(state.thinkingLevel), systemImage: ThinkingLevel.symbol(state.thinkingLevel))
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Effort: \(ThinkingLevel.name(state.thinkingLevel))")
            .accessibilityIdentifier("effort.menu")
        }
    }

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    private var imagesUnseen: Bool {
        store.model(state.model)?.images == false && attachments.contains { if case .image = $0.content { true } else { false } }
    }

    /// Photos, Paste (images, links and text from the clipboard) and Files (images, PDFs, text files).
    private var attachMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button("Paste", systemImage: "doc.on.clipboard") { paste() }
            Button("Files", systemImage: "folder") { importingFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("attach.menu")
    }

    private func attach(_ work: @escaping @Sendable () async -> [Attachment]) {
        attaching += 1
        Task {
            let loaded = await Task.detached(operation: work).value
            attachments += loaded
            attaching -= 1
        }
    }

    private func paste() {
        // Not Sendable; only the loading task touches them from here on.
        nonisolated(unsafe) let providers = UIPasteboard.general.itemProviders
        attach { await Attachments.load(providers) }
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        attach {
            var loaded: [Attachment] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = Attachments.saveImage(data) { loaded.append(image) }
            }
            return loaded
        }
    }

    private func attachFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        attach {
            urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Attachments.file(url)
            }
        }
    }

    /// The field, and under it the model, the effort and Send/Stop, in one glass panel.
    private var composer: some View {
        VStack(spacing: 8) {
            if !state.queue.isEmpty { queue }
            VStack(alignment: .leading, spacing: 10) {
                if !attachments.isEmpty || attaching > 0 {
                    HStack(spacing: 8) {
                        AttachmentStrip(attachments: attachments) { removed in attachments.removeAll { $0.id == removed.id } }
                        if attaching > 0 { ProgressView().controlSize(.small) }
                    }
                    if imagesUnseen {
                        Label("This model can't see images", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField(state.live.busy ? "Queue a message" : "Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .accessibilityIdentifier("composer")
                GlassEffectContainer {
                    HStack(spacing: 8) {
                        attachMenu
                        modelMenu
                        effortMenu
                        Spacer(minLength: 0)
                        primaryButton
                    }
                }
                .controlSize(.small)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.snappy, value: state.queue)
        .animation(.snappy, value: attachments)
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { attachPhotos(photoItems) }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image, .pdf, .text, .json, .sourceCode], allowsMultipleSelection: true) {
            attachFiles($0)
        }
    }

    /// Send, or Stop while an answer runs and the field is empty. Text typed during an answer is queued.
    private var primaryButton: some View {
        let stops = state.live.busy && !hasDraft
        return Button {
            if stops {
                Task { await store.abort(conversationId) }
            } else {
                let text = draft
                let sent = attachments
                draft = ""
                attachments = []
                Task { await store.send(text, attachments: sent, to: conversationId) }
            }
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(!stops && (!hasDraft || attaching > 0))
        .animation(.snappy, value: stops)
        .accessibilityLabel(stops ? "Stop" : state.live.busy ? "Queue" : "Send")
        .accessibilityIdentifier(stops ? "stop" : "send")
    }

    /// Messages waiting for the answer to finish. Each can steer the answer, go back to the composer, or be removed.
    private var queue: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.queue.enumerated()), id: \.element.id) { index, message in
                if index > 0 { Divider().padding(.leading, 40) }
                QueuedRow(
                    message: message,
                    working: queueActions.contains(message.id),
                    steer: { act(on: message) { await store.steer(message, in: conversationId) } },
                    edit: { edit(message) },
                    remove: { act(on: message) { _ = await store.withdraw(message, from: conversationId) } }
                )
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func act(on message: QueuedMessage, _ action: @escaping () async -> Void) {
        guard queueActions.insert(message.id).inserted else { return }
        Task {
            await action()
            queueActions.remove(message.id)
        }
    }

    /// Withdraws a queued message into the composer, its text and attachments ahead of what is already there.
    private func edit(_ message: QueuedMessage) {
        act(on: message) {
            guard let taken = await store.takeBack(message, from: conversationId) else { return }
            draft = [taken.text, draft].filter { !$0.isEmpty }.joined(separator: "\n")
            attachments = taken.attachments + attachments
            composing = true
        }
    }
}

private struct QueuedRow: View {
    let message: QueuedMessage
    let working: Bool
    let steer: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.steering ? "arrow.turn.down.right" : "clock")
                .font(.footnote)
                .foregroundStyle(message.steering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.text)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(message.steering ? "Sent when the running tools finish" : "Sent when this answer finishes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture(perform: edit)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Edits the message")
            if working {
                ProgressView().controlSize(.small)
            } else {
                if !message.steering {
                    Button("Steer", systemImage: "arrow.turn.down.right", action: steer)
                        .labelStyle(.titleOnly)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityHint("Sends it now: after the running tools, or by stopping the answer")
                        .accessibilityIdentifier("queue.steer")
                }
                Button("Remove", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue.remove")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contextMenu {
            if !message.steering { Button("Steer", systemImage: "arrow.turn.down.right", action: steer) }
            Button("Edit", systemImage: "pencil", action: edit)
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            Button("Remove", systemImage: "xmark", role: .destructive, action: remove)
        }
        .disabled(working)
    }
}
