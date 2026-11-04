import PiSSH
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings › SSH Hosts: the machines Pi may run commands on (docs/adr/0012-ssh-hosts.md).
struct SSHHostsSettingsView: View {
    @Bindable var store: ChatStore

    var body: some View {
        Form {
            Section {
                ForEach(store.sshHosts) { host in
                    NavigationLink {
                        SSHHostView(store: store, host: host)
                    } label: {
                        SSHHostRow(host: host, hasSecret: store.sshSecretIDs.contains(host.id))
                    }
                }
                NavigationLink {
                    SSHHostView(store: store, host: nil)
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.ssh.add")
            } footer: {
                Text("Pi runs shell commands on these machines with ssh_exec, and asks you before each one unless you let a host run without asking. Passwords and keys stay in the Keychain on this iPhone.")
            }
        }
        .navigationTitle("SSH Hosts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SSHHostRow: View {
    let host: SSHHost
    let hasSecret: Bool

    var body: some View {
        HStack {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(!host.enabled ? .gray : ready ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var ready: Bool { host.hostKey != nil && hasSecret }

    private var detail: String {
        guard host.enabled else { return "Off" }
        if host.hostKey == nil { return "\(host.address) · host key not confirmed" }
        if !hasSecret { return "\(host.address) · no login saved" }
        return host.runWithoutAsking ? "\(host.address) · runs without asking" : host.address
    }
}

/// Adds a host (`host` nil) or edits one: address, login, shell, host key and approvals.
struct SSHHostView: View {
    @Bindable var store: ChatStore
    let host: SSHHost?

    @State private var name = ""
    @State private var address = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var auth = SSHHost.Auth.key
    @State private var password = ""
    /// A key made or imported here, saved with the host.
    @State private var pendingKey: (privateKey: String, publicKey: String, encrypted: Bool)?
    @State private var passphrase = ""
    @State private var shell = SSHHost.Shell.login
    @State private var needsVpn = false
    @State private var vpnTouched = false
    @State private var enabled = true
    @State private var runWithoutAsking = false
    @State private var loaded = false
    /// The host's ID once it is saved: a new host's view becomes its edit view.
    @State private var savedID: String?
    @State private var saving = false
    @State private var error: String?
    @State private var importing = false
    @State private var confirmingReplaceKey = false

    // Host key and test
    @State private var checkingKey = false
    @State private var fetchedKey: String?
    @State private var confirmingKey = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var confirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    private var current: SSHHost? {
        let id = savedID ?? host?.id
        return id.flatMap { id in store.sshHosts.first { $0.id == id } }
    }
    private var hasSecret: Bool { current.map { store.sshSecretIDs.contains($0.id) } ?? false }
    private var savedKeyLogin: Bool { hasSecret && current?.auth == .key }
    private var publicKey: String? { pendingKey?.publicKey ?? (auth == .key ? current?.publicKey : nil) }
    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1 ... 65535).contains($0) ? $0 : nil } }
    /// The host as typed, read leniently (a pasted `http://` URL, `user@host:port`).
    private var parsedAddress: (host: String, user: String?, port: Int?)? { SSHHost.parseAddress(address) }
    private var trimmedAddress: String { parsedAddress?.host ?? "" }

    private var canSave: Bool {
        guard !saving, portNumber != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty, !trimmedAddress.isEmpty,
              !(parsedAddress?.user ?? user).trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if pendingKey?.encrypted == true && passphrase.isEmpty { return false }
        switch auth {
        case .password: return !password.isEmpty || (hasSecret && current?.auth == .password)
        case .key: return pendingKey != nil || savedKeyLogin
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Home server"))
                TextField("Host", text: $address, prompt: Text("nas.tail1234.ts.net or 192.168.1.20"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: address) {
                        if !vpnTouched { needsVpn = MCPServer.isPrivate(host: trimmedAddress) }
                    }
                    .accessibilityIdentifier("ssh.host")
                TextField("User", text: $user, prompt: Text("me"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ssh.user")
                LabeledContent("Port") {
                    TextField("Port", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            }

            Section {
                Picker("Login", selection: $auth) {
                    Text("Key").tag(SSHHost.Auth.key)
                    Text("Password").tag(SSHHost.Auth.password)
                }
                if auth == .password {
                    SecureField(hasSecret && current?.auth == .password ? "Saved; type to replace" : "Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ssh.password")
                } else {
                    keyControls
                }
            } header: {
                Text("Login")
            } footer: {
                if auth == .password {
                    Text("A key is safer: it can't be guessed, and you can remove it from the machine on its own.")
                } else if publicKey == nil {
                    Text("Pi makes an Ed25519 key that never leaves this iPhone, or uses one of yours (OpenSSH Ed25519, with or without a passphrase).")
                }
            }

            if auth == .key, let publicKey {
                publicKeySection(publicKey)
            }

            Section {
                Picker("Shell", selection: $shell) {
                    ForEach(SSHHost.Shell.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Run without asking", isOn: $runWithoutAsking)
                    .accessibilityIdentifier("ssh.runWithoutAsking")
                Toggle("Needs VPN", isOn: Binding(get: { needsVpn }, set: { needsVpn = $0; vpnTouched = true }))
                if current != nil { Toggle("On", isOn: $enabled) }
            } header: {
                Text("Commands")
            } footer: {
                Text(runWithoutAsking
                    ? "Pi runs commands on this host without asking, except in conversations that hold web pages, search results or MCP results: those could tell Pi what to run. Every command still shows in the chat."
                    : "Pi asks before each command, showing it in full. Commands run in your home folder, in the shell you pick, without a terminal.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote).textSelection(.enabled) }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text(current == nil ? "Add Host" : "Save") }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("ssh.save")
            }

            if let current {
                hostKeySection(current)
                Section {
                    Button("Remove Host", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .navigationTitle(current?.name ?? "Add SSH Host")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result { importKey(from: url) }
        }
        .confirmationDialog("Replace the saved key?", isPresented: $confirmingReplaceKey, titleVisibility: .visible) {
            Button("Make a New Key", role: .destructive) { generateKey() }
        } message: {
            Text("The machine still lists the old key in authorized_keys until you remove it there. Add the new one before saving.")
        }
        .alert(keyAlertTitle, isPresented: $confirmingKey, presenting: fetchedKey) { key in
            Button("Trust") {
                guard let id = current?.id else { return }
                Task {
                    await store.trustSSHHostKey(id, key: key)
                    fetchedKey = nil
                    await test()
                }
            }
            Button("Cancel", role: .cancel) { fetchedKey = nil }
        } message: { key in
            Text(keyAlertMessage(key))
        }
        .confirmationDialog("Remove \(current?.name ?? "this host")?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let id = current?.id else { return }
                Task {
                    await store.removeSSHHost(id)
                    dismiss()
                }
            }
        } message: {
            Text("Its saved password or key is deleted from this iPhone. A key stays in the machine's authorized_keys until you remove it there.")
        }
        .onAppear(perform: load)
    }

    // MARK: Key

    @ViewBuilder private var keyControls: some View {
        if let pendingKey {
            LabeledContent("Key", value: pendingKey.encrypted ? "Imported, encrypted" : "New, not saved yet")
            if pendingKey.encrypted {
                SecureField("Passphrase", text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } else if savedKeyLogin {
            LabeledContent("Key", value: "Saved in the Keychain")
        }
        Menu {
            Button("Make a New Key", systemImage: "key") {
                if savedKeyLogin { confirmingReplaceKey = true } else { generateKey() }
            }
            Button("Import from Files", systemImage: "folder") { importing = true }
            Button("Paste a Private Key", systemImage: "doc.on.clipboard") { pasteKey() }
        } label: {
            Text(pendingKey == nil && !savedKeyLogin ? "Choose a Key…" : "Change Key…")
        }
        .accessibilityIdentifier("ssh.key")
    }

    private func publicKeySection(_ line: String) -> some View {
        Section {
            Text(line)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(4)
            Button("Copy Public Key", systemImage: "doc.on.doc") { UIPasteboard.general.string = line }
            Button("Copy Setup Command", systemImage: "terminal") { UIPasteboard.general.string = Self.setupCommand(line) }
            ShareLink(item: line) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
        } header: {
            Text("Public Key")
        } footer: {
            Text("Add this line to ~/.ssh/authorized_keys on the machine. The setup command does that when you paste it into a terminal there.")
        }
    }

    static func setupCommand(_ line: String) -> String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(line.replacingOccurrences(of: "'", with: ""))' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    private func generateKey() {
        let key = SSHKeys.generate(comment: "pi-durable@\(UIDevice.current.name.lowercased().replacingOccurrences(of: " ", with: "-"))")
        pendingKey = (key.privateKey, key.publicKey, false)
        passphrase = ""
        error = nil
    }

    private func pasteKey() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            error = "The clipboard holds no text."
            return
        }
        useKey(text)
    }

    private func importKey(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 64_000, let text = String(data: data, encoding: .utf8) else {
            error = "That file isn't a private key."
            return
        }
        useKey(text)
    }

    private func useKey(_ text: String) {
        do {
            let info = try SSHKeys.info(ofPrivateKey: text)
            // An encrypted Ed25519 key is checked on save, with its passphrase; anything else now.
            if info.type != "ssh-ed25519" || !info.encrypted { try SSHKeys.check(privateKey: text, passphrase: nil) }
            pendingKey = (text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", info.publicKey, info.encrypted)
            passphrase = ""
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: Host key

    private func hostKeySection(_ host: SSHHost) -> some View {
        Section {
            if let key = host.hostKey {
                LabeledContent("Host key", value: SSHKeys.typeName(ofPublicKey: key))
                Text(SSHKeys.fingerprint(ofPublicKey: key) ?? "?")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                LabeledContent("Host key", value: "Not confirmed")
            }
            Button {
                Task { await checkHostKey() }
            } label: {
                HStack {
                    Text(host.hostKey == nil ? "Get Host Key" : "Check Host Key Again")
                    if checkingKey { Spacer(); ProgressView() }
                }
            }
            .disabled(checkingKey)
            .accessibilityIdentifier("ssh.hostKey")
            if host.hostKey != nil {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || !hasSecret)
                .accessibilityIdentifier("ssh.test")
            }
            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(testFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
            }
        } header: {
            Text("Connection")
        } footer: {
            if host.hostKey == nil {
                Text("Pi reads the machine's host key and shows its fingerprint before it sends any password or key. Nothing runs until you trust it.")
            } else if !store.vpnUp && host.needsVpn {
                Text("No VPN tunnel is up on this iPhone.")
            }
        }
    }

    private var keyAlertTitle: String {
        guard let pinned = current?.hostKey, let fetchedKey else { return "Trust this host key?" }
        return SSHKeys.normalized(pinned) == SSHKeys.normalized(fetchedKey) ? "Host key unchanged" : "The host key changed"
    }

    private func keyAlertMessage(_ key: String) -> String {
        let fingerprint = "\(SSHKeys.typeName(ofPublicKey: key)) \(SSHKeys.fingerprint(ofPublicKey: key) ?? "?")"
        let check = "To check it, run “ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub” on the machine."
        if let pinned = current?.hostKey {
            if SSHKeys.normalized(pinned) == SSHKeys.normalized(key) { return "\(fingerprint)\n\nIt's the key you trusted." }
            return "Now: \(fingerprint)\nTrusted: \(SSHKeys.fingerprint(ofPublicKey: pinned) ?? "?")\n\nTrust the new key only if you reinstalled the machine or changed its keys. Otherwise someone may be in the way. \(check)"
        }
        return "\(fingerprint)\n\n\(check)"
    }

    private func checkHostKey() async {
        guard let host = current else { return }
        checkingKey = true
        defer { checkingKey = false }
        do {
            fetchedKey = try await SSHConnections.shared.hostKey(host: host.host, port: host.port)
            confirmingKey = true
            testResult = nil
        } catch {
            testFailed = true
            testResult = String(describing: error) + (host.needsVpn && !VPNStatus.tunnelUp() ? " The VPN looks off." : "")
        }
    }

    private func test() async {
        guard let id = current?.id else { return }
        testing = true
        defer { testing = false }
        do {
            let about = try await store.testSSHHost(id)
            testFailed = false
            testResult = ["Connected.", about.hostname.map { "Host: \($0)" }, about.system.map { "System: \($0)" }, about.shell.map { "Login shell: \($0)" }]
                .compactMap { $0 }
                .joined(separator: "\n")
        } catch {
            testFailed = true
            testResult = String(describing: error)
        }
    }

    // MARK: Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let host = current else { return }
        name = host.name
        address = host.host
        port = String(host.port)
        user = host.user
        auth = host.auth
        shell = host.shell
        needsVpn = host.needsVpn
        vpnTouched = true
        enabled = host.enabled
        runWithoutAsking = host.runWithoutAsking
    }

    private func save() async {
        // A user or port inside the host field fills those fields, and the field keeps just the host.
        if let parsed = parsedAddress {
            if let parsedUser = parsed.user { user = parsedUser }
            if let parsedPort = parsed.port { port = String(parsedPort) }
            address = parsed.host
        }
        guard let portNumber else { return }
        error = nil
        var secret: SSHSecret?
        var publicKeyLine = current?.publicKey
        switch auth {
        case .password:
            if !password.isEmpty { secret = .password(password) }
            publicKeyLine = nil
        case .key:
            if let pendingKey {
                do {
                    try SSHKeys.check(privateKey: pendingKey.privateKey, passphrase: pendingKey.encrypted ? passphrase : nil)
                    publicKeyLine = pendingKey.publicKey
                } catch {
                    self.error = String(describing: error)
                    return
                }
                secret = .key(privateKey: pendingKey.privateKey, passphrase: pendingKey.encrypted ? passphrase : nil)
            }
        }
        // Switching between password and key needs the new login.
        if let current, current.auth != auth, secret == nil { error = "Enter the new login first."; return }
        saving = true
        defer { saving = false }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let id = current?.id ?? SSHHost.id(for: trimmedName, taken: Set(store.sshHosts.map(\.id)))
        var updated = current ?? SSHHost(id: id, name: trimmedName, host: trimmedAddress, user: user)
        updated.name = trimmedName
        updated.host = trimmedAddress
        updated.port = portNumber
        updated.user = user.trimmingCharacters(in: .whitespaces)
        updated.auth = auth
        updated.shell = shell
        updated.publicKey = publicKeyLine
        updated.needsVpn = needsVpn
        updated.enabled = enabled
        updated.runWithoutAsking = runWithoutAsking
        await store.saveSSHHost(updated, secret: secret)
        savedID = id
        password = ""
        pendingKey = nil
        passphrase = ""
        // A new or moved host: read its key now, for the user to confirm.
        if store.sshHosts.first(where: { $0.id == id })?.hostKey == nil { await checkHostKey() }
    }
}
