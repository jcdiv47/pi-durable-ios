import SwiftUI

enum Route: Hashable {
    case conversation(Int)
    case settings
    case diagnostics
}

struct ChatRootView: View {
    @Bindable var store: ChatStore
    @State private var path: [Route] = []
    @State private var approvalDismissed: Set<Int> = []

    var body: some View {
        NavigationStack(path: $path) {
            ConversationListView(store: store, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .conversation(id): ConversationView(store: store, conversationId: id, path: $path)
                    case .settings: SettingsView(store: store)
                    case .diagnostics: DiagnosticsView(store: store)
                    }
                }
        }
        .sheet(item: pendingApproval) { request in
            ApprovalSheet(store: store, request: request) {
                approvalDismissed.insert(request.id)
            }
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled(false)
        }
    }

    /// The oldest request the user has not set aside; the sheet comes back for the next one.
    private var pendingApproval: Binding<ApprovalRequest?> {
        Binding(
            get: { store.approvals.first { !approvalDismissed.contains($0.id) } },
            set: { value in
                if value == nil, let current = store.approvals.first(where: { !approvalDismissed.contains($0.id) }) {
                    approvalDismissed.insert(current.id)
                }
            }
        )
    }
}

struct ConversationListView: View {
    @Bindable var store: ChatStore
    @Binding var path: [Route]
    @State private var renaming: ConversationMeta?
    @State private var newTitle = ""

    var body: some View {
        Group {
            switch store.phase {
            case .starting:
                ProgressView("Opening Pi…")
            case let .failed(message):
                ContentUnavailableView("Pi could not start", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                list
            }
        }
        .navigationTitle("Pi")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Settings", systemImage: "gearshape") { path.append(.settings) }
                    Button("Diagnostics", systemImage: "stethoscope") { path.append(.diagnostics) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if let meta = await store.newConversation() { path.append(.conversation(meta.id)) }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New conversation")
                .disabled(store.phase != .ready)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                if let renaming { Task { await store.rename(renaming.id, to: newTitle) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var list: some View {
        if store.conversations.isEmpty {
            ContentUnavailableView {
                Label("No conversations", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(store.models.count <= 1 ? "Add an API key in Settings, or try the offline demo model." : "Start one with the compose button.")
            } actions: {
                Button("New conversation") {
                    Task { if let meta = await store.newConversation() { path.append(.conversation(meta.id)) } }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                if !store.approvals.isEmpty {
                    Section {
                        ForEach(store.approvals) { request in
                            Button {
                                path.append(.conversation(request.conversationId))
                            } label: {
                                Label("\(request.tool) is waiting for your approval", systemImage: "hand.raised.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                ForEach(store.conversations) { meta in
                    NavigationLink(value: Route.conversation(meta.id)) {
                        ConversationRow(meta: meta, state: store.states[meta.id])
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await store.remove(meta.id) }
                        }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            newTitle = meta.title
                            renaming = meta
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await store.remove(meta.id) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

struct ConversationRow: View {
    let meta: ConversationMeta
    let state: ConversationState?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if meta.forkOf != nil {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).font(.caption)
                }
                Text(meta.title).font(.headline).lineLimit(1)
                Spacer()
                if state?.live.busy == true {
                    ProgressView().controlSize(.small)
                }
            }
            Text(meta.updated, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ApprovalSheet: View {
    let store: ChatStore
    let request: ApprovalRequest
    let later: () -> Void
    @State private var answering = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Pi wants to run **\(request.tool)**")
                    } icon: {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    }
                    Text(store.conversations.first { $0.id == request.conversationId }?.title ?? "Conversation \(request.conversationId)")
                        .foregroundStyle(.secondary)
                }
                Section("Details") {
                    ForEach(request.arguments.fields, id: \.0) { key, value in
                        LabeledContent(key) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
                    }
                }
                Section {
                    Text("The conversation waits for your answer, even if Pi is closed in the meantime.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        answer(false)
                    } label: {
                        Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("approval.deny")
                    Button {
                        answer(true)
                    } label: {
                        Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    .accessibilityIdentifier("approval.allow")
                }
                .disabled(answering)
                .padding()
            }
            .navigationTitle("Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later", action: later) }
            }
        }
    }

    private func answer(_ allow: Bool) {
        answering = true
        Task { await store.answer(request, allow: allow) }
    }
}
