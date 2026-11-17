import PiRuntime
import SwiftUI

/// Settings › HTTP Endpoints: the user's own HTTP APIs, which Pi calls with http_get and http_send.
struct HTTPEndpointsSettingsView: View {
    @Bindable var store: ChatStore

    var body: some View {
        Form {
            Section {
                ForEach(store.httpEndpoints) { endpoint in
                    NavigationLink {
                        HTTPEndpointView(store: store, endpoint: endpoint)
                    } label: {
                        HTTPEndpointRow(endpoint: endpoint, hasSecret: store.httpSecretIDs.contains(endpoint.id))
                    }
                }
                NavigationLink {
                    HTTPEndpointView(store: store, endpoint: nil)
                } label: {
                    Label("Add Endpoint", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.http.add")
            } footer: {
                Text("APIs of your own, such as Home Assistant or a webhook. Pi calls them only under the base URL you give, reads with http_get and changes things with http_send, which always asks you first. Tokens stay in the Keychain on this iPhone.")
            }
        }
        .navigationTitle("HTTP Endpoints")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HTTPEndpointRow: View {
    let endpoint: HTTPEndpoint
    let hasSecret: Bool

    var body: some View {
        HStack {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(!endpoint.enabled ? .gray : ready ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var ready: Bool { !endpoint.auth.usesSecret || hasSecret }

    private var detail: String {
        guard endpoint.enabled else { return "Off" }
        if !ready { return "\(endpoint.baseUrl) · no secret saved" }
        return endpoint.readWithoutAsking ? "\(endpoint.baseUrl) · reads without asking" : endpoint.baseUrl
    }
}

/// Adds an endpoint (`endpoint` nil) or edits one: base URL, what it is for, auth and approvals.
struct HTTPEndpointView: View {
    @Bindable var store: ChatStore
    let endpoint: HTTPEndpoint?

    @State private var name = ""
    @State private var baseUrl = ""
    @State private var about = ""
    @State private var auth = HTTPEndpoint.Auth.bearer
    @State private var authName = ""
    @State private var secret = ""
    @State private var needsVpn = false
    @State private var vpnTouched = false
    @State private var enabled = true
    @State private var readWithoutAsking = false
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    private var current: HTTPEndpoint? { endpoint.flatMap { endpoint in store.httpEndpoints.first { $0.id == endpoint.id } } }
    private var hasSecret: Bool { current.map { store.httpSecretIDs.contains($0.id) } ?? false }
    private var parsed: URL? { HTTPEndpoint.parseBase(baseUrl) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedAuthName: String { authName.trimmingCharacters(in: .whitespaces) }
    /// The ID the endpoint has, or will get when added.
    private var id: String { current?.id ?? HTTPEndpoint.id(for: trimmedName, taken: Set(store.httpEndpoints.map(\.id))) }
    /// A saved secret stays only while the origin is the same (`ChatStore.saveHTTPEndpoint`).
    private var keepsSecret: Bool {
        guard hasSecret, let current, let old = URL(string: current.baseUrl), let new = parsed else { return false }
        return old.scheme == new.scheme && old.host() == new.host() && old.port == new.port
    }

    private var canSave: Bool {
        guard !saving, parsed != nil, !trimmedName.isEmpty else { return false }
        if auth == .header || auth == .query, !HTTPEndpoint.validAuthName(trimmedAuthName, for: auth) { return false }
        return !auth.usesSecret || !secret.isEmpty || keepsSecret
    }

    private var hasChanges: Bool {
        guard let current else { return true }
        return trimmedName != current.name || parsed?.absoluteString != current.baseUrl || about != current.about || auth != current.auth
            || (auth == .header || auth == .query ? trimmedAuthName : nil) != current.authName || needsVpn != current.needsVpn
            || enabled != current.enabled || readWithoutAsking != current.readWithoutAsking || !secret.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Home Assistant"))
                    .accessibilityIdentifier("http.name")
                TextField("Base URL", text: $baseUrl, prompt: Text("http://100.64.0.2:8123/api"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: baseUrl) {
                        if !vpnTouched, let host = parsed?.host() { needsVpn = MCPServer.isPrivate(host: host) }
                    }
                    .accessibilityIdentifier("http.baseUrl")
                if !trimmedName.isEmpty { LabeledContent("ID", value: id) }
            } footer: {
                if !baseUrl.isEmpty, parsed == nil {
                    Text("An http:// or https:// address with a host, and no query or #fragment.")
                } else {
                    Text("Pi calls paths under this URL only: with /api, it may call /api/states but not /admin.")
                }
            }

            Section {
                TextField("Description", text: $about, prompt: Text("Home Assistant's REST API. GET states lists entities; POST services/<domain>/<service> with {\"entity_id\": …} runs one."), axis: .vertical)
                    .lineLimit(3 ... 10)
                    .accessibilityIdentifier("http.description")
            } header: {
                Text("For Pi")
            } footer: {
                Text("What the API is and how to use it. Pi reads this with the endpoint's ID and base URL.")
            }

            Section {
                Picker("Auth", selection: $auth) {
                    ForEach(HTTPEndpoint.Auth.allCases) { Text($0.title).tag($0) }
                }
                if auth == .header || auth == .query {
                    TextField(auth == .header ? "Header" : "Parameter", text: $authName, prompt: Text(auth == .header ? "X-API-Key" : "token"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if auth.usesSecret {
                    SecureField(keepsSecret ? "Saved; type to replace" : "Secret", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("http.secret")
                }
            } footer: {
                switch auth {
                case .none: Text("No secret is sent.")
                case .bearer: Text("Sent as “Authorization: Bearer <token>”, only to URLs under the base URL. For Home Assistant, a long-lived access token from your profile.")
                case .header:
                    if !trimmedAuthName.isEmpty, !HTTPEndpoint.validAuthName(trimmedAuthName, for: .header) {
                        Text("Not a header name Pi can use.")
                    } else {
                        Text("Sent as “\(trimmedAuthName.isEmpty ? "Header" : trimmedAuthName): <secret>”, only to URLs under the base URL.")
                    }
                case .query: Text("Added to each URL as “?\(trimmedAuthName.isEmpty ? "parameter" : trimmedAuthName)=<secret>”, only under the base URL. Prefer a header when the API takes one: servers often log URLs.")
                }
            }

            Section {
                Toggle("Read Without Asking", isOn: $readWithoutAsking)
                    .accessibilityIdentifier("http.readWithoutAsking")
                Toggle("Needs VPN", isOn: Binding(get: { needsVpn }, set: { needsVpn = $0; vpnTouched = true }))
                if current != nil { Toggle("Available to Pi", isOn: $enabled) }
            } header: {
                Text("Requests")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(readWithoutAsking
                        ? "Pi reads (GET) without asking, except in conversations that read web pages or MCP results. It always asks before changing anything (POST, PUT, PATCH, DELETE)."
                        : "Pi asks before every request, and shows you the method, the URL and what it would send.")
                    if needsVpn, !store.vpnUp { Text("No VPN tunnel is up on this iPhone.") }
                }
            }

            if current != nil {
                Section {
                    Button("Remove Endpoint", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text(current == nil ? "Add" : "Save") }
                }
                .disabled(!canSave || !hasChanges)
                .accessibilityIdentifier("http.save")
            }
        }
        .navigationTitle(current?.name ?? "Add HTTP Endpoint")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(current?.name ?? "this endpoint")?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let id = current?.id else { return }
                Task {
                    await store.removeHTTPEndpoint(id)
                    dismiss()
                }
            }
        } message: {
            Text("Its saved secret is deleted from this iPhone. Conversations keep what the endpoint returned.")
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let current else { return }
        name = current.name
        baseUrl = current.baseUrl
        about = current.about
        auth = current.auth
        authName = current.authName ?? ""
        needsVpn = current.needsVpn
        vpnTouched = true
        enabled = current.enabled
        readWithoutAsking = current.readWithoutAsking
    }

    private func save() async {
        guard let parsed else { return }
        saving = true
        defer { saving = false }
        var updated = current ?? HTTPEndpoint(id: id, name: trimmedName, baseUrl: parsed.absoluteString, about: "", needsVpn: needsVpn, auth: auth)
        updated.name = trimmedName
        updated.baseUrl = parsed.absoluteString
        updated.about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.auth = auth
        updated.authName = auth == .header || auth == .query ? trimmedAuthName : nil
        updated.needsVpn = needsVpn
        updated.enabled = enabled
        updated.readWithoutAsking = readWithoutAsking
        let newSecret = secret
        secret = ""
        await store.saveHTTPEndpoint(updated, secret: newSecret.isEmpty ? nil : newSecret)
        if endpoint == nil { dismiss() }
    }
}
