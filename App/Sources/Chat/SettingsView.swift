import PiRuntime
import SwiftUI

struct SettingsView: View {
    @Bindable var store: ChatStore

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
            } footer: {
                Text("New conversations start with this model. Change a conversation's model from its title bar.")
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
                ForEach(store.tools) { tool in
                    Picker(selection: Binding(get: { tool.policy }, set: { policy in Task { await store.setPolicy(policy, for: tool.name) } })) {
                        Text("Allow").tag("auto")
                        Text("Ask").tag("ask")
                        Text("Never").tag("deny")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.body.monospaced())
                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
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
            if store.hasKey(provider) {
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
