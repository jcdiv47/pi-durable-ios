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
    /// The last test: what the machine said, or why it failed.
    @State private var about: SSHAbout?
    @State private var connectionError: String?
    /// What was just copied, for the confirmation in its row.
    @State private var copied: String?
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

    /// Whether Save has anything to save.
    private var hasChanges: Bool {
        guard let current else { return true }
        return name != current.name || trimmedAddress != current.host || portNumber != current.port || user != current.user
            || auth != current.auth || shell != current.shell || needsVpn != current.needsVpn || enabled != current.enabled
            || runWithoutAsking != current.runWithoutAsking || !password.isEmpty || pendingKey != nil
    }

    /// A label on the left, the value typed on the right: the Settings app's layout, two values a line apart.
    private func field(_ label: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    var body: some View {
        Form {
            if let current { statusSection(current) }

            Section {
                field("Name", text: $name, prompt: "Home server")
                field("Host", text: $address, prompt: "192.168.1.20", keyboard: .URL)
                    .onChange(of: address) {
                        if !vpnTouched { needsVpn = MCPServer.isPrivate(host: trimmedAddress) }
                    }
                    .accessibilityIdentifier("ssh.host")
                field("User", text: $user, prompt: "me")
                    .accessibilityIdentifier("ssh.user")
                field("Port", text: $port, prompt: "22", keyboard: .numberPad)
                if let key = current?.hostKey { hostKeyRow(key) }
            } header: {
                Text("Machine")
            } footer: {
                if current == nil { Text("A name or IP address. A pasted ssh:// or http:// address works too.") }
            }

            loginSection

            Section {
                Picker("Shell", selection: $shell) {
                    ForEach(SSHHost.Shell.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Ask Before Each Command", isOn: Binding(get: { !runWithoutAsking }, set: { runWithoutAsking = !$0 }))
                    .accessibilityIdentifier("ssh.askFirst")
                Toggle("Needs VPN", isOn: Binding(get: { needsVpn }, set: { needsVpn = $0; vpnTouched = true }))
                if current != nil { Toggle("Available to Pi", isOn: $enabled) }
            } header: {
                Text("Commands")
            } footer: {
                Text(runWithoutAsking
                    ? "Pi runs commands here without asking, except in conversations that read web pages or MCP results, which could tell it what to run."
                    : "Pi shows each command in full and waits for you to allow it.")
            }

            if current != nil {
                Section {
                    Button("Remove Host", role: .destructive) { confirmingRemove = true }
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
                .accessibilityIdentifier("ssh.save")
            }
        }
        .task {
            // The status card says whether the host works right now.
            guard let current, current.enabled, current.hostKey != nil, hasSecret, about == nil, connectionError == nil else { return }
            await test()
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new != nil }
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

    /// Login: how Pi signs in, and for a key, how to put it on the machine.
    private var loginSection: some View {
        Section {
            Picker("Login", selection: $auth) {
                Text("Key").tag(SSHHost.Auth.key)
                Text("Password").tag(SSHHost.Auth.password)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ssh.auth")

            if auth == .password {
                LabeledContent("Password") {
                    SecureField("Password", text: $password, prompt: Text(hasSecret && current?.auth == .password ? "Saved" : "Required"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .accessibilityIdentifier("ssh.password")
            } else {
                LabeledContent("Key") {
                    Menu {
                        Button("Make a New Key", systemImage: "key") {
                            if savedKeyLogin { confirmingReplaceKey = true } else { generateKey() }
                        }
                        Button("Import from Files", systemImage: "folder") { importing = true }
                        Button("Paste a Private Key", systemImage: "doc.on.clipboard") { pasteKey() }
                    } label: {
                        Text(keyStatus)
                    }
                    .accessibilityIdentifier("ssh.key")
                }
                if pendingKey?.encrypted == true {
                    LabeledContent("Passphrase") {
                        SecureField("Passphrase", text: $passphrase, prompt: Text("Required"))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if let publicKey {
                    Menu {
                        Button("Copy Public Key", systemImage: "doc.on.doc") { copy(publicKey, as: "public") }
                        ShareLink(item: publicKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
                    } label: {
                        LabeledContent("Public Key") {
                            Text(copied == "public" ? "Copied" : SSHKeys.fingerprint(ofPublicKey: publicKey) ?? "")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.primary)
                    Button {
                        copy(Self.setupCommand(publicKey), as: "setup")
                    } label: {
                        Label(copied == "setup" ? "Copied. Paste It on the Machine" : "Copy Setup Command",
                              systemImage: copied == "setup" ? "checkmark" : "terminal")
                    }
                    .accessibilityIdentifier("ssh.setupCommand")
                }
            }
        } header: {
            Text("Login")
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else if auth == .key, publicKey != nil {
                Text("The setup command adds this key to ~/.ssh/authorized_keys. Paste it into a terminal on the machine.")
            } else if auth == .key {
                Text("Pi can make an Ed25519 key that stays on this iPhone, or use one of yours.")
            }
        }
    }

    private var keyStatus: String {
        if let pendingKey { return pendingKey.encrypted ? "Imported (not saved)" : "New (not saved)" }
        return savedKeyLogin ? "Ed25519" : "Choose…"
    }

    private func copy(_ text: String, as tag: String) {
        UIPasteboard.general.string = text
        copied = tag
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == tag { copied = nil }
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

    // MARK: Status

    /// The top of the page: the host, whether it works, and the one thing to do next.
    private func statusSection(_ host: SSHHost) -> some View {
        let status = status(of: host)
        return Section {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(status.color.gradient, in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.headline)
                    Text(host.address)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Label(status.title, systemImage: status.icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(status.color)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if let detail = status.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let action = status.action {
                Button {
                    Task { if action == .getKey { await checkHostKey() } else { await test() } }
                } label: {
                    HStack {
                        Text(action == .getKey ? "Get Host Key" : about == nil && connectionError == nil ? "Test Connection" : "Test Again")
                        Spacer()
                        if checkingKey || testing { ProgressView() }
                    }
                }
                .disabled(checkingKey || testing)
                .accessibilityIdentifier(action == .getKey ? "ssh.hostKey" : "ssh.test")
            }
        }
    }

    private enum NextStep { case getKey, test }

    private struct Status {
        var title: String
        var icon: String
        var color: Color
        var detail: String?
        var action: NextStep?
    }

    /// Where the host stands, in the order setting it up goes: on, host key, login, connection.
    private func status(of host: SSHHost) -> Status {
        let vpnHint = host.needsVpn && !store.vpnUp ? " No VPN tunnel is up on this iPhone." : ""
        if !host.enabled {
            return Status(title: "Off", icon: "pause.circle.fill", color: .gray, detail: "Pi can't use this host until you make it available again.")
        }
        if host.hostKey == nil {
            return Status(
                title: "Confirm the host key", icon: "key.horizontal.fill", color: .orange,
                detail: connectionError.map { $0 + vpnHint } ?? "Pi shows the machine's fingerprint before it sends any password or key.",
                action: .getKey
            )
        }
        if !hasSecret {
            return Status(title: "No login saved", icon: "exclamationmark.circle.fill", color: .orange, detail: "Add a key or a password below.")
        }
        if testing && about == nil && connectionError == nil {
            return Status(title: "Connecting…", icon: "ellipsis.circle.fill", color: .secondary, action: .test)
        }
        if let connectionError {
            return Status(title: "Can't connect", icon: "xmark.circle.fill", color: .red, detail: connectionError + vpnHint, action: .test)
        }
        if let about {
            let shell = about.shell.map { "login shell \(($0 as NSString).lastPathComponent)" }
            let detail = [about.hostname, about.system, shell].compactMap { $0 }.joined(separator: " · ")
            return Status(title: "Connected", icon: "checkmark.circle.fill", color: .green, detail: detail.isEmpty ? nil : detail, action: .test)
        }
        return Status(title: "Ready", icon: "checkmark.circle", color: .green, action: .test)
    }

    /// The pinned host key, in the Machine section; its menu checks it again.
    private func hostKeyRow(_ key: String) -> some View {
        Menu {
            Button("Check Host Key Again", systemImage: "arrow.clockwise") { Task { await checkHostKey() } }
            Button("Copy Fingerprint", systemImage: "doc.on.doc") { copy(SSHKeys.fingerprint(ofPublicKey: key) ?? "", as: "fingerprint") }
        } label: {
            LabeledContent("Host Key") {
                Text(copied == "fingerprint" ? "Copied" : "\(SSHKeys.typeName(ofPublicKey: key)) \(SSHKeys.fingerprint(ofPublicKey: key) ?? "?")")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.primary)
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
            connectionError = nil
        } catch {
            connectionError = String(describing: error)
        }
    }

    private func test() async {
        guard let id = current?.id else { return }
        testing = true
        defer { testing = false }
        do {
            about = try await store.testSSHHost(id)
            connectionError = nil
        } catch {
            about = nil
            connectionError = String(describing: error)
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
        // The host may have changed: the last test no longer says anything.
        about = nil
        connectionError = nil
        password = ""
        pendingKey = nil
        passphrase = ""
        // A new or moved host: read its key now, for the user to confirm.
        if store.sshHosts.first(where: { $0.id == id })?.hostKey == nil { await checkHostKey() }
    }
}
