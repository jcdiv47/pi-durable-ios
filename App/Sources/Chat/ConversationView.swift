import SwiftUI

struct ConversationView: View {
    @Bindable var store: ChatStore
    let conversationId: Int
    @Binding var path: [Route]
    @State private var draft = ""
    @FocusState private var composing: Bool

    private var state: ConversationState { store.state(conversationId) }
    private var meta: ConversationMeta? { store.conversations.first { $0.id == conversationId } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
        }
        .overlay {
            if state.loaded && state.items.isEmpty && !state.live.busy {
                ContentUnavailableView("Ask Pi anything", systemImage: "sparkles", description: Text(store.modelName(state.model)))
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
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

    private var composer: some View {
        VStack(spacing: 4) {
            if state.queued > 0 {
                Text("\(state.queued) queued — sent when the current answer finishes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .accessibilityIdentifier("composer")
                if state.live.busy {
                    Button {
                        Task { await store.abort(conversationId) }
                    } label: {
                        Image(systemName: "stop.fill").font(.body).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("stop")
                }
                Button {
                    let text = draft
                    draft = ""
                    Task { await store.send(text, to: conversationId) }
                } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
