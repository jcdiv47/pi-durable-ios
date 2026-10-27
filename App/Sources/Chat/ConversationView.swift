import SwiftUI

struct ConversationView: View {
    @Bindable var store: ChatStore
    let conversationId: Int
    @Binding var path: [Route]
    @State private var draft = ""
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
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        TranscriptItemView(item: item, state: state, store: store, resent: resent(at: index))
                            .contextMenu { itemMenu(item) }
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
            ToolbarItem(placement: .topBarTrailing) { modelMenu }
        }
        .onAppear { store.watch(conversationId) }
    }

    /// An answer cut off by a crash or eviction, which Pi then asked for again: the next entry is another answer.
    private func resent(at index: Int) -> Bool {
        let items = state.items
        return items[index].stopReason == "aborted" && index + 1 < items.count && items[index + 1].kind == .assistant
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
                .labelStyle(.titleOnly)
                .font(.footnote)
                .lineLimit(1)
        }
        .accessibilityIdentifier("model.menu")
    }

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        VStack(spacing: 8) {
            if !state.queue.isEmpty { queue }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(state.live.busy ? "Queue a message" : "Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .accessibilityIdentifier("composer")
                primaryButton
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.snappy, value: state.queue)
    }

    /// Send, or Stop while an answer runs and the field is empty. Text typed during an answer is queued.
    private var primaryButton: some View {
        let stops = state.live.busy && !hasDraft
        return Button {
            if stops {
                Task { await store.abort(conversationId) }
            } else {
                let text = draft
                draft = ""
                Task { await store.send(text, to: conversationId) }
            }
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(!stops && !hasDraft)
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

    /// Withdraws a queued message into the composer, ahead of anything already typed.
    private func edit(_ message: QueuedMessage) {
        act(on: message) {
            guard await store.withdraw(message, from: conversationId) else { return }
            draft = draft.isEmpty ? message.text : "\(message.text)\n\(draft)"
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
