import PiRuntime
import SwiftUI

/// Settings is an index: a few groups of rows, each opening one focused page, the way iOS Settings reads.
/// Chat (how new conversations start, your instructions and skills, archived ones, backups, links), Connections (model providers, web search, MCP servers, SSH hosts),
/// Permissions (tool approvals), and Pi itself (scheduled tasks, widgets, alarms, usage, diagnostics).
struct SettingsView: View {
    @Bindable var store: ChatStore

    private var savedProviders: Int { ChatStore.providers.filter { store.hasKey($0.id) }.count }
    private var askingTools: Int { store.tools.filter { $0.server == nil && $0.policy == "ask" }.count }
    /// This month's cost so far, across conversations.
    @State private var monthCost: Double?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ModelSettingsView(store: store)
                } label: {
                    SettingsRow("Default Model", systemImage: "cpu.fill", tint: .purple) {
                        Text(store.model(store.defaultModel)?.name ?? store.defaultModel.key)
                    }
                }
                .accessibilityIdentifier("settings.model")
                NavigationLink {
                    InstructionsView(store: store)
                } label: {
                    SettingsRow("Instructions", systemImage: "doc.text.fill", tint: .indigo) {
                        Text(store.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : "\(store.instructions.count.formatted()) characters")
                    }
                }
                .accessibilityIdentifier("settings.instructions")
                NavigationLink {
                    SkillsView(store: store)
                } label: {
                    SettingsRow("Skills", systemImage: "book.closed.fill", tint: .brown) {
                        Text(store.skills.isEmpty ? "None" : "\(store.skills.count)")
                    }
                }
                .accessibilityIdentifier("settings.skills")
                // A route, not a destination closure: its rows push conversations onto the same path.
                NavigationLink(value: Route.archived) {
                    SettingsRow("Archived Conversations", systemImage: "archivebox.fill", tint: .gray) {
                        Text("\(store.archivedConversations.count)")
                    }
                }
                NavigationLink {
                    BackupView(store: store)
                } label: {
                    SettingsRow("Backup & Export", systemImage: "externaldrive.fill", tint: .blue)
                }
                .accessibilityIdentifier("settings.backup")
            } header: {
                Text("Chat")
            }

            Section {
                Picker(selection: $store.openLinksInApp) {
                    Text("Pi").tag(true)
                    Text("Default Browser").tag(false)
                } label: {
                    // A plain Label: the menu picker stacks a LabeledContent's icon over its title.
                    Label {
                        Text("Open Links In")
                    } icon: {
                        SettingsIcon(systemImage: "safari.fill", tint: .blue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.links")
            } footer: {
                Text(store.openLinksInApp
                    ? "Links open over the chat; swipe from the left edge to come back. Map links open in Maps."
                    : "Links open in your default browser. Map links open in Maps.")
            }

            Section {
                NavigationLink {
                    ProvidersSettingsView(store: store)
                } label: {
                    SettingsRow("Model Providers", systemImage: "key.fill", tint: .orange) {
                        Text(savedProviders == 0 ? "No keys" : "\(savedProviders) saved")
                    }
                }
                .accessibilityIdentifier("settings.providers")
                NavigationLink {
                    IntelligenceSettingsView(store: store)
                } label: {
                    SettingsRow("Apple Intelligence", systemImage: "apple.intelligence", tint: .pink) {
                        Text(store.intelligenceStatus == .available ? "On device" : "Unavailable")
                    }
                }
                .accessibilityIdentifier("settings.intelligence")
                NavigationLink {
                    WebSearchSettingsView(store: store)
                } label: {
                    SettingsRow("Web Search", systemImage: "magnifyingglass", tint: .teal) {
                        Text(searchProviderName)
                    }
                }
                .accessibilityIdentifier("settings.search")
                NavigationLink {
                    MCPServersSettingsView(store: store)
                } label: {
                    SettingsRow("MCP Servers", systemImage: "server.rack", tint: .gray) {
                        Text(store.mcpServers.isEmpty ? "None" : "\(store.mcpServers.count)")
                    }
                }
                .accessibilityIdentifier("settings.mcp")
                NavigationLink {
                    SSHHostsSettingsView(store: store)
                } label: {
                    SettingsRow("SSH Hosts", systemImage: "terminal.fill", tint: .mint) {
                        Text(store.sshHosts.isEmpty ? "None" : "\(store.sshHosts.count)")
                    }
                }
                .accessibilityIdentifier("settings.ssh")
            } header: {
                Text("Connections")
            } footer: {
                Text("Keys and tokens stay in the Keychain on this iPhone and go only to their own servers.")
            }

            Section {
                NavigationLink {
                    ToolApprovalsView(store: store)
                } label: {
                    SettingsRow("Tool Approvals", systemImage: "hand.raised.fill", tint: .green) {
                        if askingTools > 0 { Text("\(askingTools) ask first") }
                    }
                }
                .accessibilityIdentifier("settings.approvals")
            } header: {
                Text("Permissions")
            }

            Section {
                NavigationLink(value: Route.schedules) {
                    SettingsRow("Scheduled Tasks", systemImage: "clock.arrow.circlepath", tint: .red)
                }
                NavigationLink(value: Route.surfaces) {
                    SettingsRow("Widgets", systemImage: "square.grid.2x2.fill", tint: .cyan)
                }
                NavigationLink(value: Route.alarms) {
                    SettingsRow("Alarms & Timers", systemImage: "alarm.fill", tint: .orange)
                }
                .accessibilityIdentifier("settings.alarms")
                NavigationLink {
                    VoiceSettingsView()
                } label: {
                    SettingsRow("Talk to Pi", systemImage: "waveform", tint: .blue)
                }
                .accessibilityIdentifier("settings.voice")
                NavigationLink {
                    PhotoSearchSettingsView()
                } label: {
                    SettingsRow("Photo Search", systemImage: "photo.on.rectangle.angled", tint: .indigo)
                }
                .accessibilityIdentifier("settings.photos")
                NavigationLink {
                    UsageSettingsView(store: store)
                } label: {
                    SettingsRow("Usage", systemImage: "chart.bar.fill", tint: .teal) {
                        if let monthCost { Text(UsageFormat.cost(monthCost)).monospacedDigit() }
                    }
                }
                .accessibilityIdentifier("settings.usage")
                NavigationLink(value: Route.diagnostics) {
                    SettingsRow("Diagnostics", systemImage: "stethoscope", tint: .gray)
                }
            } header: {
                Text("Pi")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await store.refreshTools()
            await store.refreshModels()
            monthCost = await store.spending(UsageSettingsView.month(0))?.cost
        }
    }

    private var searchProviderName: String {
        switch store.searchProvider {
        case "deepseek": "DeepSeek"
        case "brave": "Brave Search"
        case "scripted": "Offline"
        default: "Off"
        }
    }
}

/// A Settings index row: a tinted symbol, a title and an optional value on the trailing side.
struct SettingsRow<Value: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: Value

    init(_ title: String, systemImage: String, tint: Color, @ViewBuilder value: () -> Value) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.value = value()
    }

    var body: some View {
        LabeledContent {
            value
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(systemImage: systemImage, tint: tint)
            }
        }
    }
}

/// A white symbol on a colored rounded square, as iOS Settings draws its rows' icons. Scales with Dynamic Type.
struct SettingsIcon: View {
    let systemImage: String
    let tint: Color
    @ScaledMetric private var size: CGFloat

    init(systemImage: String, tint: Color, size: CGFloat = 30) {
        self.systemImage = systemImage
        self.tint = tint
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.53, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension SettingsRow where Value == EmptyView {
    init(_ title: String, systemImage: String, tint: Color) {
        self.init(title, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// Settings › Default Model: the model and effort new conversations start with.
struct ModelSettingsView: View {
    @Bindable var store: ChatStore
    /// The efforts the default model supports; just `off` for one without reasoning, which gets no effort picker.
    private var defaultLevels: [String] { store.model(store.defaultModel)?.thinkingLevels ?? [] }

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $store.defaultModel) {
                    ForEach(store.models) { model in
                        Text("\(model.name) · \(model.providerName)").tag(model.ref)
                    }
                    if !store.models.contains(where: { $0.ref == store.defaultModel }) {
                        Text(store.defaultModel.key).tag(store.defaultModel)
                    }
                }
                .pickerStyle(.navigationLink)
                if defaultLevels.count > 1 {
                    Picker("Effort", selection: Binding(
                        get: { ThinkingLevel.clamp(store.defaultThinking, to: defaultLevels) },
                        set: { store.defaultThinking = $0 }
                    )) {
                        ForEach(defaultLevels, id: \.self) { level in
                            Label(ThinkingLevel.name(level), systemImage: ThinkingLevel.symbol(level)).tag(level)
                        }
                    }
                    .accessibilityIdentifier("settings.effort")
                }
            } footer: {
                Text("New conversations start with this model and effort, and keep them. Conversations already started don't change.")
            }
            if store.models.count <= 1 {
                Section {
                    NavigationLink("Add a Provider Key") { ProvidersSettingsView(store: store) }
                } footer: {
                    Text("Only the offline demo model is available until a provider has a key.")
                }
            }
        }
        .navigationTitle("Default Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Model Providers: one row per provider, each opening its key page.
struct ProvidersSettingsView: View {
    @Bindable var store: ChatStore

    var body: some View {
        Form {
            Section {
                ForEach(ChatStore.providers, id: \.id) { provider in
                    NavigationLink {
                        ProviderKeyView(store: store, provider: provider.id, name: provider.name)
                    } label: {
                        KeyStatusRow(name: provider.name, saved: store.hasKey(provider.id))
                    }
                }
            } footer: {
                Text("Keys stay in the Keychain on this iPhone. Pi's JavaScript never sees them: the app adds a key only to requests going to that provider's own servers.")
            }
        }
        .navigationTitle("Model Providers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Web Search: the search provider, the keyed services and their monthly usage.
struct WebSearchSettingsView: View {
    @Bindable var store: ChatStore

    private var capped: [(id: String, name: String)] {
        ChatStore.services.filter { store.hasKey($0.id) && ServiceUsage.shared.cap(for: $0.id) != nil }.map { ($0.id, $0.name) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Search With", selection: $store.searchProvider) {
                    Text("Off").tag("off")
                    Text("DeepSeek").tag("deepseek")
                    Text("Brave Search").tag("brave")
                    #if DEBUG
                    Text("Offline (scripted)").tag("scripted")
                    #endif
                }
            } footer: {
                Text("DeepSeek search uses the DeepSeek provider key, and reading pages always goes through DeepSeek. Pi asks before reading a page whose link didn't come from you or a search.")
            }
            Section("Service Keys") {
                ForEach(ChatStore.services, id: \.id) { service in
                    NavigationLink {
                        ProviderKeyView(store: store, provider: service.id, name: service.name)
                    } label: {
                        KeyStatusRow(name: service.name, saved: store.hasKey(service.id))
                    }
                }
            }
            if !capped.isEmpty {
                Section("This Month") {
                    ForEach(capped, id: \.id) { service in
                        LabeledContent(service.name) {
                            Text("\(ServiceUsage.shared.count(for: service.id)) of \(ServiceUsage.shared.cap(for: service.id)!) requests")
                        }
                    }
                }
            }
        }
        .navigationTitle("Web Search")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › MCP Servers: the user's servers and the way to add one.
struct MCPServersSettingsView: View {
    @Bindable var store: ChatStore

    var body: some View {
        Form {
            Section {
                ForEach(store.mcpServers) { server in
                    NavigationLink {
                        MCPServerView(store: store, server: server)
                    } label: {
                        MCPServerRow(server: server, status: store.mcpStatuses[server.id])
                    }
                }
                NavigationLink {
                    MCPServerView(store: store, server: nil)
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.mcp.add")
            } footer: {
                Text("Tools from MCP servers that speak Streamable HTTP. Tokens stay in the Keychain and go only to their server's host; servers that ask you to sign in use OAuth. Pi asks before tools that change things; a server's tool approvals are on its page.")
            }
        }
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Tool Approvals: Pi's own tools (MCP servers' tools are under their server).
struct ToolApprovalsView: View {
    @Bindable var store: ChatStore

    var body: some View {
        Form {
            Section {
                ForEach(store.tools.filter { $0.server == nil }) { tool in
                    ToolPolicyPicker(store: store, tool: tool)
                }
            } footer: {
                Text("“Ask” pauses the conversation until you allow or deny the call.")
            }
        }
        .navigationTitle("Tool Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshTools() }
    }
}

/// A provider or service row: its name and whether its key is saved.
struct KeyStatusRow: View {
    let name: String
    let saved: Bool

    var body: some View {
        LabeledContent(name) {
            Text(saved ? "Key saved" : "No key")
                .foregroundStyle(saved ? .green : .secondary)
        }
    }
}

/// A tool's approval policy: Allow, Ask or Never. A row with the description's first line and the policy; it opens
/// the tool's page, which has the whole description (written for the model, so often long) and the choice.
struct ToolPolicyPicker: View {
    let store: ChatStore
    let tool: ToolInfo
    /// Shown instead of the name, such as an MCP tool's own name without its server prefix.
    var title: String?

    var body: some View {
        NavigationLink {
            ToolPolicyView(store: store, name: tool.name, title: title ?? tool.name)
        } label: {
            // Centred, so the policy sits level with the chevron the list draws in the row's middle.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? tool.name).font(.body.monospaced())
                    Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(ToolPolicy.name(tool.policy))
                    .foregroundStyle(tool.policy == "ask" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityIdentifier("tool.\(tool.name)")
    }
}

/// One tool: its policy, then its whole description.
struct ToolPolicyView: View {
    let store: ChatStore
    let name: String
    let title: String

    /// Read from the store, so the choice shows once `setPolicy` has refreshed the tools.
    private var tool: ToolInfo? { store.tools.first { $0.name == name } }

    var body: some View {
        Form {
            if let tool {
                Section {
                    Picker("Approval", selection: Binding(get: { tool.policy }, set: { policy in Task { await store.setPolicy(policy, for: name) } })) {
                        ForEach(ToolPolicy.all, id: \.self) { policy in
                            Text(ToolPolicy.name(policy)).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(ToolPolicy.explanation(tool.policy))
                }
                Section("What Pi Is Told") {
                    Text(tool.description)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum ToolPolicy {
    static let all = ["auto", "ask", "deny"]

    static func name(_ policy: String) -> String {
        switch policy {
        case "auto": "Allow"
        case "ask": "Ask"
        case "deny": "Never"
        default: policy
        }
    }

    static func explanation(_ policy: String) -> String {
        switch policy {
        case "auto": "Pi runs this tool without asking."
        case "ask": "Pi pauses the conversation until you allow or deny each call."
        case "deny": "Pi can’t use this tool: a call is refused, and Pi is told you turned it off."
        default: ""
        }
    }
}

struct ArchivedConversationsView: View {
    @Bindable var store: ChatStore
    @State private var deleting: ConversationMeta?

    var body: some View {
        Group {
            if store.archivedConversations.isEmpty {
                ContentUnavailableView("No Archived Conversations", systemImage: "archivebox", description: Text("Swipe left on a conversation to archive it."))
            } else {
                List(store.archivedConversations) { meta in
                    NavigationLink(value: Route.conversation(meta.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meta.title).lineLimit(1)
                            if let archived = meta.archived {
                                Text("Archived \(archived.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button {
                            Task { await store.unarchive(meta.id) }
                        } label: {
                            Label("Unarchive", systemImage: "tray.and.arrow.up").labelStyle(.iconOnly)
                        }
                        .tint(.indigo)
                        Button {
                            deleting = meta
                        } label: {
                            Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button("Unarchive", systemImage: "tray.and.arrow.up") {
                            Task { await store.unarchive(meta.id) }
                        }
                        ShareLink(item: ConversationMarkdown(id: meta.id, title: meta.title), preview: SharePreview(meta.title)) {
                            Label("Export as Markdown", systemImage: "square.and.arrow.up")
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleting = meta
                        }
                    }
                }
            }
        }
        .navigationTitle("Archived")
        .deleteConversationDialog($deleting, store: store)
    }
}

struct ProviderKeyView: View {
    @Bindable var store: ChatStore
    let provider: String
    let name: String
    @State private var key = ""
    @State private var customName = ""
    @State private var baseUrl = ""
    @State private var modelIds = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if provider == "custom" {
                Section {
                    TextField("Name", text: $customName)
                    TextField("Base URL", text: $baseUrl, prompt: Text("https://example.com/v1"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model IDs, comma separated", text: $modelIds, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save endpoint") {
                        let ids = modelIds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        store.custom = baseUrl.isEmpty ? nil : .init(name: customName, baseUrl: baseUrl, modelIds: ids)
                        Task { await store.applyProviders() }
                    }
                    .disabled(URL(string: baseUrl)?.host() == nil && !baseUrl.isEmpty)
                } header: {
                    Text("OpenAI-compatible endpoint")
                } footer: {
                    Text("Any server that speaks the OpenAI chat completions API. Its key is sent only to this URL's host.")
                }
            }
            Section {
                if store.hasKey(provider) {
                    Label("Stored in the Keychain", systemImage: "key.fill")
                    Button("Remove key", role: .destructive) {
                        Task { await store.removeKey(for: provider) }
                    }
                } else {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("key.field")
                    Button("Save to Keychain") {
                        let value = key
                        key = ""
                        Task { await store.setKey(value, for: provider) }
                    }
                    .disabled(key.isEmpty)
                }
            } header: {
                Text("\(name) API key")
            }
            if store.hasKey(provider), ChatStore.providers.contains(where: { $0.id == provider }) {
                Section("Models") {
                    ForEach(store.models.filter { $0.provider == provider }.prefix(200)) { model in
                        LabeledContent(model.name) {
                            Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(name)
        .onAppear {
            customName = store.custom?.name ?? ""
            baseUrl = store.custom?.baseUrl ?? ""
            modelIds = store.custom?.modelIds.joined(separator: ", ") ?? ""
        }
    }
}
