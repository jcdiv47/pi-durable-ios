import PiRuntime
import SwiftUI

struct SettingsView: View {
    @Bindable var store: ChatStore
    /// The efforts the default model supports; just `off` for one without reasoning, which gets no effort picker.
    private var defaultLevels: [String] { store.model(store.defaultModel)?.thinkingLevels ?? [] }

    var body: some View {
        Form {
            Section {
                Picker("Default model", selection: $store.defaultModel) {
                    ForEach(store.models) { model in
                        Text("\(model.name) · \(model.providerName)").tag(model.ref)
                    }
                    if !store.models.contains(where: { $0.ref == store.defaultModel }) {
                        Text(store.defaultModel.key).tag(store.defaultModel)
                    }
                }
                .pickerStyle(.navigationLink)
                if defaultLevels.count > 1 {
                    Picker("Default effort", selection: Binding(
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

            Section {
                ForEach(ChatStore.providers, id: \.id) { provider in
                    NavigationLink {
                        ProviderKeyView(store: store, provider: provider.id, name: provider.name)
                    } label: {
                        LabeledContent(provider.name) {
                            Text(store.hasKey(provider.id) ? "Key saved" : "No key")
                                .foregroundStyle(store.hasKey(provider.id) ? .green : .secondary)
                        }
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys stay in the Keychain on this iPhone. Pi's JavaScript never sees them: the app adds a key only to requests going to that provider's own servers.")
            }

            Section {
                Picker("Search with", selection: $store.searchProvider) {
                    Text("Off").tag("off")
                    Text("DeepSeek").tag("deepseek")
                    Text("Brave Search").tag("brave")
                    #if DEBUG
                    Text("Offline (scripted)").tag("scripted")
                    #endif
                }
                ForEach(ChatStore.services, id: \.id) { service in
                    NavigationLink {
                        ProviderKeyView(store: store, provider: service.id, name: service.name)
                    } label: {
                        LabeledContent(service.name) {
                            Text(store.hasKey(service.id) ? "Key saved" : "No key")
                                .foregroundStyle(store.hasKey(service.id) ? .green : .secondary)
                        }
                    }
                }
                ForEach(ChatStore.services.filter { store.hasKey($0.id) && ServiceUsage.shared.cap(for: $0.id) != nil }, id: \.id) { service in
                    LabeledContent("\(service.name) this month") {
                        Text("\(ServiceUsage.shared.count(for: service.id)) of \(ServiceUsage.shared.cap(for: service.id)!) requests")
                    }
                }
            } header: {
                Text("Web search")
            } footer: {
                Text("DeepSeek search uses the DeepSeek key above, and reading pages always goes through DeepSeek. Pi asks before reading a page whose link didn't come from you or a search.")
            }

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
                    Label("Add server", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.mcp.add")
            } header: {
                Text("MCP servers")
            } footer: {
                Text("Tools from MCP servers that speak Streamable HTTP. Tokens stay in the Keychain and go only to their server's host. Pi asks before tools that change things.")
            }

            Section {
                Picker("Open links in", selection: $store.openLinksInApp) {
                    Text("Pi").tag(true)
                    Text("Default browser").tag(false)
                }
                .accessibilityIdentifier("settings.links")
            } header: {
                Text("Links")
            } footer: {
                Text("In Pi, a page slides in over the chat; swipe right from the left edge to go back. Map links always open in Maps.")
            }

            Section {
                // MCP servers' tools are under their server.
                ForEach(store.tools.filter { $0.server == nil }) { tool in
                    ToolPolicyPicker(store: store, tool: tool)
                }
            } header: {
                Text("Tool approvals")
            } footer: {
                Text("“Ask” pauses the conversation until you allow or deny the call.")
            }
        }
        .navigationTitle("Settings")
        .task {
            await store.refreshTools()
            await store.refreshModels()
        }
    }
}

/// A tool's approval policy: Allow, Ask or Never.
struct ToolPolicyPicker: View {
    let store: ChatStore
    let tool: ToolInfo
    /// Shown instead of the name, such as an MCP tool's own name without its server prefix.
    var title: String?

    var body: some View {
        Picker(selection: Binding(get: { tool.policy }, set: { policy in Task { await store.setPolicy(policy, for: tool.name) } })) {
            Text("Allow").tag("auto")
            Text("Ask").tag("ask")
            Text("Never").tag("deny")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? tool.name).font(.body.monospaced())
                Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
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
