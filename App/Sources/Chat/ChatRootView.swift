import PiSSH
import PiUI
import SwiftUI

enum Route: Hashable {
    case conversation(Int)
    case settings
    case archived
    case diagnostics
    case surfaces
    case surface(String)
    case schedules
    case gallery
    case component(String)
    case tuning
    /// The chat's own components (`ChatComponentsGallery`), drawn with `PiDesign`.
    case chatComponents
    /// Settings › Alarms & Timers, also where a timer's Live Activity opens.
    case alarms
    /// A link, when links open in Pi (`BrowserView`).
    case browser(URL)
    /// Talk to Pi (`VoiceView`), `pidurable://voice`: in a new conversation, or `continuing` one.
    case voice(continuing: Int?)

    /// `pidurable://conversation/<id>` (widget and Live Activity taps), `pidurable://widgets`, `pidurable://tasks`,
    /// `pidurable://settings`, `pidurable://alarms`, `pidurable://voice`.
    /// `pidurable://share/<id>` is no route: the share extension's item goes through `ChatStore.receiveShares`.
    init?(url: URL) {
        guard url.scheme == "pidurable" else { return nil }
        switch url.host() {
        case "conversation": guard let id = Int(url.lastPathComponent) else { return nil }; self = .conversation(id)
        case "widgets": self = .surfaces
        case "tasks": self = .schedules
        case "settings": self = .settings
        case "alarms": self = .alarms
        case "voice": self = .voice(continuing: nil)
        default: return nil
        }
    }
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
                    // Identified by the conversation: a deep link from one conversation to another replaces the route
                    // in place, and without a new identity the old view (its draft, its watch) would stay on screen.
                    case let .conversation(id): ConversationView(store: store, conversationId: id, path: $path).id(id)
                    case .settings: SettingsView(store: store)
                    case .archived: ArchivedConversationsView(store: store)
                    case .diagnostics: DiagnosticsView(store: store)
                    case .surfaces: SurfacesView(store: store, path: $path)
                    case let .surface(publishedId): SurfaceDetailView(store: store, publishedId: publishedId, path: $path)
                    case .schedules: SchedulesView(store: store, path: $path)
                    case .gallery: GalleryView()
                    case let .component(name): ComponentDetailView(store: store, name: name)
                    case .tuning: TuningView(store: store)
                    case .chatComponents: ChatComponentsGallery()
                    case .alarms: AlarmsView()
                    case let .browser(url): BrowserView(url: url)
                    case let .voice(continuing): VoiceView(store: store, path: $path, continuing: continuing)
                    }
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            // Every link in the chat (Markdown, cards, attachments) comes through here.
            guard store.openLinksInApp, BrowserView.opens(url) else { return .systemAction }
            path.append(.browser(url))
            return .handled
        })
        .onOpenURL { url in
            if url.host() == "share" { Task { await store.receiveShares() } }
            if let route = Route(url: url) { path = [route] }
        }
        .onChange(of: store.pendingRoute, initial: true) {
            // From notifications and intents, which may arrive before this view exists.
            guard let route = store.pendingRoute else { return }
            store.pendingRoute = nil
            path = [route]
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
    @State private var deleting: ConversationMeta?
    @State private var newTitle = ""
    @State private var query = ""

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
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search conversations")
        .toolbar {
            ToolbarItem(placement: .principal) {
                PiLogo().frame(height: 24)
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Widgets", systemImage: "square.grid.2x2") { path.append(.surfaces) }
                    Button("Scheduled Tasks", systemImage: "clock.arrow.circlepath") { path.append(.schedules) }
                    Divider()
                    Button("Settings", systemImage: "gearshape") { path.append(.settings) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(.voice(continuing: nil)) } label: {
                    Image(systemName: "waveform")
                }
                .accessibilityLabel("Talk to Pi")
                .accessibilityIdentifier("voice.open")
                .disabled(store.phase != .ready)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: compose) {
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
        .deleteConversationDialog($deleting, store: store)
    }

    /// Opens the unused conversation if there is one; a new one stays out of the list until something is sent in it.
    private func compose() {
        Task {
            var meta = await store.openUnusedConversation()
            if meta == nil { meta = await store.newConversation() }
            if let meta { path.append(.conversation(meta.id)) }
        }
    }

    @ViewBuilder private var list: some View {
        if store.startedConversations.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No Conversations")
                } icon: {
                    PiLogo().frame(height: 44)
                }
            } description: {
                Text(store.models.count <= 1
                    ? "Add a model provider's key in Settings, or try Pi with the offline demo model."
                    : "Ask Pi about your day, set reminders, build widgets and more.")
            } actions: {
                Button("New Conversation", systemImage: "square.and.pencil", action: compose)
                    .buttonStyle(.glassProminent)
                if store.models.count <= 1 {
                    Button("Add a Key in Settings") { path.append(.settings) }
                }
            }
        } else {
            List {
                if !store.approvals.isEmpty && query.isEmpty {
                    Section {
                        ForEach(store.approvals) { request in
                            Button {
                                path.append(.conversation(request.conversationId))
                            } label: {
                                ApprovalListRow(request: request, conversation: store.meta(request.conversationId)?.title)
                            }
                            .tint(.primary)
                        }
                    } header: {
                        Text("Waiting for You")
                    }
                }
                if query.isEmpty {
                    ForEach(ConversationSections.group(shown)) { section in
                        Section(section.title) {
                            ForEach(section.items) { meta in row(meta, time: section.time) }
                        }
                    }
                } else {
                    // A search: the conversations with the text in their title, then the messages with it.
                    if !shown.isEmpty {
                        Section("Conversations") {
                            ForEach(shown) { meta in row(meta, time: Self.searchDate) }
                        }
                    }
                    if !store.search.hits.isEmpty {
                        Section("Messages") {
                            ForEach(store.search.hits) { hit in
                                Button {
                                    path.append(store.open(hit))
                                } label: {
                                    SearchHitRow(hit: hit, title: store.meta(hit.conversationId)?.title ?? hit.title, time: Self.searchDate)
                                }
                                .tint(.primary)
                            }
                        }
                    } else if store.search.searching {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching messages…").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if !query.isEmpty && shown.isEmpty && store.search.hits.isEmpty && !store.search.searching {
                    ContentUnavailableView.search(text: query)
                }
            }
            // Approvals are occasional; without this the rows below jump by a section's height.
            .animation(.snappy, value: store.approvals.map(\.id))
            .onChange(of: query) { searchMessages() }
            // A new or renamed conversation, or one with a new message, while the search is on screen.
            .onChange(of: store.startedConversations) { if !query.isEmpty { searchMessages() } }
        }
    }

    private static let searchDate = Date.FormatStyle.dateTime.day().month(.abbreviated)

    private func searchMessages() {
        store.search.update(query, store: store)
    }

    private func row(_ meta: ConversationMeta, time: Date.FormatStyle) -> some View {
        NavigationLink(value: Route.conversation(meta.id)) {
            ConversationRow(
                meta: meta,
                state: store.states[meta.id],
                unread: store.unreadConversations.contains(meta.id),
                waiting: store.approvals.contains { $0.conversationId == meta.id },
                time: time
            )
        }
        .swipeActions {
            Button {
                Task { await store.archive(meta.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
            Button {
                deleting = meta
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                newTitle = meta.title
                renaming = meta
            }
            ShareLink(item: ConversationMarkdown(id: meta.id, title: meta.title), preview: SharePreview(meta.title)) {
                Label("Export as Markdown", systemImage: "square.and.arrow.up")
            }
            Button("Archive", systemImage: "archivebox") {
                Task { await store.archive(meta.id) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleting = meta
            }
        }
    }

    /// The started conversations whose title has the search text, all of them while there is none.
    private var shown: [ConversationMeta] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return store.startedConversations }
        return store.startedConversations.filter { $0.title.localizedStandardContains(text) }
    }
}

/// A message the search found: its conversation and when it was said, then who said it and the text around the match.
private struct SearchHitRow: View {
    let hit: SearchHit
    /// The conversation's title now; the hit has it as it was when the search ran.
    let title: String
    let time: Date.FormatStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let date = hit.date {
                    Text(date, format: time)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(hit.fromPi ? "Pi" : "You"): \(hit.before)\(Text(hit.matched).bold().foregroundStyle(.primary))\(hit.after)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the conversation at this message")
    }
}

/// The conversation list's sections, as Notes groups notes: Today, Yesterday, Previous 7 Days, Previous 30 Days, then
/// each month. Each section also says how its rows show their time: a time of day today and yesterday, a weekday within
/// the week, a date before that.
enum ConversationSections {
    struct Group: Identifiable {
        let title: String
        let time: Date.FormatStyle
        var items: [ConversationMeta]
        var id: String { title }
    }

    static func group(_ conversations: [ConversationMeta], now: Date = .now, calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let week = calendar.date(byAdding: .day, value: -7, to: today)!
        let month = calendar.date(byAdding: .day, value: -30, to: today)!
        let clock = Date.FormatStyle.dateTime.hour().minute()
        var groups: [Group] = []
        for meta in conversations {
            let date = meta.updated
            let group: Group
            if date >= today {
                group = Group(title: "Today", time: clock, items: [])
            } else if date >= yesterday {
                group = Group(title: "Yesterday", time: clock, items: [])
            } else if date >= week {
                group = Group(title: "Previous 7 Days", time: .dateTime.weekday(.wide), items: [])
            } else if date >= month {
                group = Group(title: "Previous 30 Days", time: .dateTime.day().month(.abbreviated), items: [])
            } else {
                let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
                let title = sameYear ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.wide).year())
                group = Group(title: title, time: .dateTime.day().month(.abbreviated), items: [])
            }
            // Newest first already, so a section's rows arrive together.
            if groups.last?.title == group.title {
                groups[groups.count - 1].items.append(meta)
            } else {
                var started = group
                started.items = [meta]
                groups.append(started)
            }
        }
        return groups
    }
}

struct ConversationRow: View {
    let meta: ConversationMeta
    let state: ConversationState?
    var unread = false
    var waiting = false
    var time: Date.FormatStyle = .dateTime.hour().minute()

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the title gets the whole width, and the time goes under it, as Mail does.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            HStack(spacing: 8) {
                if meta.forkOf != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Fork")
                }
                Text(meta.title)
                    .fontWeight(unread ? .semibold : .regular)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            trailing
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unread ? "Unread" : "")
    }

    /// What the conversation is doing, or when it last changed; unread ones get a dot, as Mail marks unread mail.
    @ViewBuilder private var trailing: some View {
        if waiting {
            Label("Needs you", systemImage: "hand.raised.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.orange)
        } else if state?.live.busy == true {
            ConversationWorkingStatus()
        } else {
            HStack(spacing: 6) {
                if unread {
                    Circle().fill(.tint).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                Text(meta.updated, format: time)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(unread ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
    }
}

/// A call waiting for approval, in the list above the conversations: what Pi wants to do, and where.
private struct ApprovalListRow: View {
    let request: ApprovalRequest
    let conversation: String?

    var body: some View {
        let title = ToolTitles.title(for: request.tool)
        HStack(spacing: 12) {
            SettingsIcon(systemImage: title.symbol, tint: title.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.action).font(.body.weight(.medium)).lineLimit(1)
                Text(conversation ?? "A conversation").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Review")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the conversation to allow or deny it")
    }
}

private struct ConversationWorkingStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.89, green: 0.49, blue: 0.44))
                .frame(width: 7, height: 7)
                .phaseAnimator(reduceMotion ? [false] : [false, true]) { dot, dimmed in
                    dot.opacity(dimmed ? 0.35 : 1)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
                .accessibilityHidden(true)
            Text("Working")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct ApprovalSheet: View {
    let store: ChatStore
    let request: ApprovalRequest
    let later: () -> Void
    @State private var answering = false
    /// For publish_surface: the widget that would go on the Home Screen.
    @State private var surface: SurfaceRef?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
                if let surface {
                    Section("Widget") {
                        SurfaceStrip(surface: surface, store: store)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    }
                }
                if request.tool == "ssh_exec", let command = request.arguments["command"]?.string {
                    // The whole command, as it will run.
                    Section {
                        LabeledContent("Host", value: sshHostLabel)
                        Text(command)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("approval.command")
                    } header: {
                        Text("Command")
                    } footer: {
                        footer
                    }
                } else if !details.isEmpty {
                    Section {
                        ForEach(details, id: \.key) { row in
                            if row.value.count > 40 || row.value.contains("\n") {
                                // Long values (a prompt, notes, a link) read better on their own lines.
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.label).font(.subheadline).foregroundStyle(.secondary)
                                    Text(row.value).textSelection(.enabled)
                                }
                                .padding(.vertical, 2)
                            } else {
                                LabeledContent(row.label) { Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled) }
                            }
                        }
                    } header: {
                        Text("Details")
                    } footer: {
                        footer
                    }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
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
                    .tint(PiDesign.Palette.success)
                    .accessibilityIdentifier("approval.allow")
                }
                .disabled(answering)
                .padding()
            }
            .task {
                guard request.tool == "publish_surface", let id = request.arguments["id"]?.string else { return }
                surface = await store.surfaces(of: request.conversationId).first { $0.id == id }
            }
            .navigationTitle("Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later", action: later) }
            }
        }
    }

    private var details: [(key: String, label: String, value: String)] { ApprovalDetails.rows(request.arguments) }

    private var footer: some View {
        Text("Pi calls \(Text(request.tool).font(.footnote.monospaced())). The conversation waits for your answer, even if Pi is closed in the meantime.")
    }

    /// What Pi wants to do, in words, and where; the tool's own name is in the footer, for those who want the exact call.
    private var header: some View {
        let title = ToolTitles.title(for: request.tool)
        return HStack(spacing: 14) {
            SettingsIcon(systemImage: title.symbol, tint: title.tint, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.action)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("In “\(store.meta(request.conversationId)?.title ?? "Conversation \(request.conversationId)")”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("approval.header")
    }

    private var sshHostLabel: String {
        let id = request.arguments["host"]?.string ?? "?"
        return store.sshHosts.first { $0.id == id }.map { "\($0.name) (\($0.address))" } ?? id
    }

    private func answer(_ allow: Bool) {
        answering = true
        Task { await store.answer(request, allow: allow) }
    }
}
