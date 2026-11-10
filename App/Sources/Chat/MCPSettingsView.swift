import AuthenticationServices
import PiRuntime
import SwiftUI

/// A server in Settings' list: name, host and state.
struct MCPServerRow: View {
    let server: MCPServer
    let status: MCPStatus?

    var body: some View {
        HStack {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var color: Color {
        guard server.enabled else { return .gray }
        switch status?.state {
        case "ok": return .green
        case "unreachable": return .orange
        case .some: return .red
        case nil: return .secondary
        }
    }

    private var detail: String {
        guard server.enabled else { return "Off" }
        let tools = server.toolCount == 1 ? "1 tool" : "\(server.toolCount) tools"
        switch status?.state {
        case "unreachable": return "Unreachable · \(tools)"
        case "unauthorized": return server.usesOAuth ? "Sign-in needed" : "Token refused"
        case "error": return "Error · \(tools)"
        default: return "\(server.host ?? server.url) · \(tools)"
        }
    }
}

/// Adds a server (`server` nil) or edits one: address, auth (a token, or signing in with OAuth), VPN, and its tools'
/// approvals.
struct MCPServerView: View {
    @Bindable var store: ChatStore
    let server: MCPServer?

    enum Auth: String, CaseIterable, Identifiable {
        case none, oauth, bearer, header
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .oauth: "OAuth sign-in"
            case .bearer: "Bearer token"
            case .header: "Custom header"
            }
        }
        var usesToken: Bool { self == .bearer || self == .header }
    }

    @State private var name = ""
    @State private var url = ""
    @State private var auth = Auth.bearer
    @State private var header = "X-API-Key"
    @State private var token = ""
    @State private var needsVpn = true
    /// Whether the user set "Needs VPN" themselves; until then it follows the URL's host.
    @State private var vpnTouched = false
    @State private var enabled = true
    @State private var saving = false
    @State private var confirmingRemove = false
    @State private var loaded = false
    @State private var signingIn = false
    @State private var signInError: String?
    /// A new server whose sign-in failed: the view stays as its edit view, with the error.
    @State private var addedID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private var current: MCPServer? { (server?.id ?? addedID).flatMap { id in store.mcpServers.first { $0.id == id } } }
    private var status: MCPStatus? { current.flatMap { store.mcpStatuses[$0.id] } }
    private var hasToken: Bool { current.map { store.hasKey($0.keyName) } ?? false }
    private var parsed: URL? {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil else { return nil }
        return url
    }
    private var canSave: Bool {
        guard !saving, parsed != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if auth == .header, header.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        // A new server with a token needs it; an edited one keeps the saved one. OAuth signs in after saving.
        return !auth.usesToken || !token.isEmpty || hasToken
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Home Assistant"))
                TextField("URL", text: $url, prompt: Text("http://100.64.0.2:8123/api/mcp"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: url) {
                        if !vpnTouched, let host = parsed?.host() { needsVpn = MCPServer.isPrivate(host: host) }
                    }
                    .accessibilityIdentifier("mcp.url")
            } footer: {
                Text("The server's Streamable HTTP endpoint. Servers that only run over stdio need a bridge on another machine first.")
            }

            Section {
                Picker("Auth", selection: $auth) {
                    ForEach(Auth.allCases) { Text($0.title).tag($0) }
                }
                if auth == .header {
                    TextField("Header", text: $header)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if auth.usesToken {
                    SecureField(hasToken ? "Saved; type to replace" : "Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mcp.token")
                }
            } footer: {
                if auth == .bearer {
                    Text("Sent as “Authorization: Bearer <token>”, only to this URL's host. For Home Assistant, a long-lived access token from your profile.")
                } else if auth == .header {
                    Text("Sent as “\(header): <token>”, only to this URL's host.")
                } else if auth == .oauth {
                    Text("For servers that ask you to sign in, such as hosted ones. Pi registers itself with the server's sign-in service, you sign in on its page, and Pi keeps the sign-in fresh. The server must use HTTPS.")
                }
            }

            Section {
                Toggle("Needs VPN", isOn: Binding(get: { needsVpn }, set: { needsVpn = $0; vpnTouched = true }))
                if current != nil { Toggle("On", isOn: $enabled) }
            } footer: {
                Text("A server only reachable over Tailscale or sing-box. When it can't be reached and the VPN looks off, Pi warns you in the chat, or with a notification when a scheduled task needed it.")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text(saveTitle) }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("mcp.save")
            }

            if let current {
                Section {
                    LabeledContent("State", value: stateText)
                    if let error = status?.error {
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let date = status?.date {
                        LabeledContent("Checked", value: date.formatted(date: .omitted, time: .shortened))
                    }
                    if let serverName = current.serverName {
                        LabeledContent("Server", value: serverName)
                    }
                    Button("Check again") { Task { await store.refreshMCP([current.id]) } }
                        .disabled(!current.enabled)
                } header: {
                    Text("Connection")
                } footer: {
                    if !store.vpnUp && current.needsVpn { Text("No VPN tunnel is up on this iPhone.") }
                }

                if current.usesOAuth {
                    let signedIn = store.mcpSignedIn.contains(current.id)
                    Section {
                        LabeledContent("Account", value: signedIn ? "Signed in" : "Not signed in")
                        Button {
                            Task { await signIn(current.id) }
                        } label: {
                            if signingIn { ProgressView() } else { Text(signedIn ? "Sign in again" : "Sign in") }
                        }
                        .disabled(signingIn || !current.enabled)
                        .accessibilityIdentifier("mcp.signIn")
                        if signedIn {
                            Button("Sign out", role: .destructive) { Task { await store.signOutMCP(current.id) } }
                                .disabled(signingIn)
                        }
                        if let signInError {
                            Text(signInError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    } header: {
                        Text("Sign-in")
                    } footer: {
                        Text("Signing out forgets Pi's tokens and its registration with the server. To revoke Pi's access everywhere, remove it in your account on the server's site too.")
                    }
                }

                let tools = store.tools.filter { $0.server == current.id }
                if !tools.isEmpty {
                    Section {
                        ForEach(tools) { tool in
                            ToolPolicyPicker(store: store, tool: tool, title: String(tool.name.dropFirst("mcp__\(current.id)__".count)))
                        }
                    } header: {
                        Text("Tools")
                    } footer: {
                        Text("Tools the server marks read-only run without asking; the others ask first.")
                    }
                }

                Section {
                    Button("Remove server", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .navigationTitle(current?.name ?? "Add MCP server")
        .confirmationDialog("Remove \(current?.name ?? "this server")?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let id = current?.id else { return }
                Task {
                    await store.removeMCPServer(id)
                    dismiss()
                }
            }
        } message: {
            Text("Its tools and saved token or sign-in are removed. Conversations keep what the tools returned.")
        }
        .onAppear(perform: load)
    }

    private var stateText: String {
        guard current?.enabled == true else { return "Off" }
        switch status?.state {
        case "ok": return "Connected"
        case "unreachable": return "Unreachable"
        case "unauthorized": return current?.usesOAuth == true ? (current.map { store.mcpSignedIn.contains($0.id) } == true ? "Sign-in refused" : "Not signed in") : "Token refused"
        case "error": return "Error"
        default: return "Not checked yet"
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let server = current else { return }
        name = server.name
        url = server.url
        switch server.authHeader?.lowercased() {
        case nil: auth = server.usesOAuth ? .oauth : .none
        case "authorization": auth = .bearer
        default:
            auth = .header
            header = server.authHeader ?? header
        }
        needsVpn = server.needsVpn
        vpnTouched = true
        enabled = server.enabled
    }

    private func save() async {
        guard let parsed else { return }
        saving = true
        defer { saving = false }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let id = current?.id ?? MCPServer.id(for: trimmedName, taken: Set(store.mcpServers.map(\.id)))
        var updated = current ?? MCPServer(id: id, name: trimmedName, url: parsed.absoluteString, needsVpn: needsVpn)
        updated.name = trimmedName
        updated.url = parsed.absoluteString
        updated.authHeader = switch auth {
        case .none, .oauth: nil
        case .bearer: "Authorization"
        case .header: header.trimmingCharacters(in: .whitespaces)
        }
        updated.oauth = auth == .oauth ? true : nil
        updated.needsVpn = needsVpn
        updated.enabled = enabled
        let newToken = token
        token = ""
        await store.saveMCPServer(updated, token: newToken.isEmpty ? nil : newToken)
        // An OAuth server that isn't signed in signs in at once, or it has no tools to offer.
        if updated.usesOAuth, updated.enabled, !store.mcpSignedIn.contains(updated.id), !(await signIn(updated.id)) {
            // Stay, as the new server's edit view, so the error shows and Sign in can be tried again.
            addedID = updated.id
            return
        }
        // A new server's view becomes its edit view: go back to the list, where it now shows.
        if server == nil { dismiss() }
    }

    private var saveTitle: String {
        if current == nil { return auth == .oauth ? "Add and sign in" : "Add and connect" }
        return "Save and connect"
    }

    /// Whether the user is signed in afterwards; false also when they closed the page.
    @discardableResult
    private func signIn(_ id: String) async -> Bool {
        signingIn = true
        signInError = nil
        defer { signingIn = false }
        do {
            try await store.signInMCP(id, session: webAuthenticationSession)
            return true
        } catch ASWebAuthenticationSessionError.canceledLogin {
            // The user closed the page.
        } catch {
            signInError = String(describing: error)
        }
        return false
    }
}
