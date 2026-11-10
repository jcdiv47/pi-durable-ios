import PiRuntime
import SwiftUI
import UIKit

/// Settings › Proxmox: the node's address, the token Pi uses, and the node's certificate,
/// which the user trusts by its fingerprint before any token is sent.
struct ProxmoxSettingsView: View {
    let store: ChatStore

    @State private var address = ""
    @State private var token = ""
    @State private var needsVpn = true
    @State private var vpnTouched = false
    @State private var saving = false
    @State private var error: String?
    @State private var fetching = false
    @State private var fetched: CertificateInfo?
    @State private var confirmingCertificate = false
    @State private var testing = false
    @State private var about: ProxmoxAbout?
    @State private var connectionError: String?
    @State private var copied = false
    @State private var confirmingRemove = false

    private var server: ProxmoxServer? { store.proxmox }
    private var url: String? { ProxmoxServer.normalize(address) }
    private var host: String? { url.flatMap { URL(string: $0)?.host() } }
    private var newToken: String? { token.isEmpty ? nil : ProxmoxServer.normalizeToken(token) }

    private var canSave: Bool {
        guard !saving, url != nil else { return false }
        if !token.isEmpty && newToken == nil { return false }
        return newToken != nil || store.hasProxmoxToken
    }

    private var hasChanges: Bool {
        guard let server else { return true }
        return url != server.url || needsVpn != server.needsVpn || newToken != nil
    }

    var body: some View {
        Form {
            if let server { statusSection(server) }

            Section {
                LabeledContent("Address") {
                    TextField("Address", text: $address, prompt: Text("192.168.1.10"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: address) {
                            if !vpnTouched, let host { needsVpn = MCPServer.isPrivate(host: host) }
                        }
                        .accessibilityIdentifier("proxmox.address")
                }
                if let fingerprint = server?.fingerprint, server?.url == url {
                    LabeledContent("Certificate") {
                        Text(fingerprint)
                            .font(.caption2.monospaced())
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                Toggle("Needs VPN", isOn: Binding(get: { needsVpn }, set: { needsVpn = $0; vpnTouched = true }))
            } header: {
                Text("Node")
            } footer: {
                if let host, !ProxmoxServer.allowsPinning(host: host) {
                    Text("iOS lets Pi trust Proxmox's own certificate only on an IP address, a name without a dot (pve), a .local name or a Tailscale name. Use one of those for \(host).")
                        .foregroundStyle(.orange)
                } else {
                    Text("The web UI's address: an IP address, the node's name, or its Tailscale name. Port 8006 unless you say otherwise.")
                }
            }

            Section {
                LabeledContent("Token") {
                    SecureField("Token", text: $token, prompt: Text(store.hasProxmoxToken ? "Saved" : "pi@pve!iphone=…"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("proxmox.token")
                }
                Button {
                    UIPasteboard.general.string = ProxmoxServer.setupCommands
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied. Paste It in the Node's Shell" : "Copy Setup Commands", systemImage: copied ? "checkmark" : "terminal")
                }
            } header: {
                Text("API Token")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if !token.isEmpty && newToken == nil {
                    Text("A token looks like user@realm!name=, then its secret (a UUID).").foregroundStyle(.red)
                } else {
                    Text("The commands make a user and a read-only token for Pi (PVEAuditor). Paste them into the node's shell (Datacenter › node › Shell) and copy the token's secret here; Proxmox shows it once.")
                }
            }

            if server != nil {
                Section {
                    Button("Remove Node", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .navigationTitle("Proxmox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text(server == nil ? "Add" : "Save") }
                }
                .disabled(!canSave || !hasChanges)
                .accessibilityIdentifier("proxmox.save")
            }
        }
        .alert("Trust This Certificate?", isPresented: $confirmingCertificate, presenting: fetched) { info in
            Button("Trust") {
                Task {
                    await store.trustProxmoxCertificate(info.fingerprint)
                    fetched = nil
                    await test()
                }
            }
            Button("Cancel", role: .cancel) { fetched = nil }
        } message: { info in
            Text(certificateMessage(info))
        }
        .confirmationDialog("Remove the node?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await store.removeProxmox()
                    load()
                }
            }
        } message: {
            Text("The token is deleted from this iPhone. It stays on the node until you remove it there (Datacenter › Permissions › API Tokens).")
        }
        .task {
            guard let server, server.fingerprint != nil, store.hasProxmoxToken, about == nil, connectionError == nil else { return }
            await test()
        }
        .onAppear(perform: load)
    }

    // MARK: Status

    private enum Step { case certificate, test }

    private struct Status {
        var title: String
        var icon: String
        var color: Color
        var detail: String?
        var step: Step?
    }

    private func status(of server: ProxmoxServer) -> Status {
        let vpnHint = server.needsVpn && !store.vpnUp ? " No VPN tunnel is up on this iPhone." : ""
        if server.fingerprint == nil {
            return Status(
                title: "Confirm the certificate", icon: "lock.trianglebadge.exclamationmark.fill", color: .orange,
                detail: connectionError.map { $0 + vpnHint } ?? "Pi shows the node's certificate before it sends the token.",
                step: .certificate
            )
        }
        if !store.hasProxmoxToken {
            return Status(title: "No token saved", icon: "exclamationmark.circle.fill", color: .orange, detail: "Add a token below.")
        }
        if testing && about == nil && connectionError == nil {
            return Status(title: "Connecting…", icon: "ellipsis.circle.fill", color: .secondary, step: .test)
        }
        if let connectionError {
            let changed = connectionError.contains("isn't the one trusted")
            return Status(title: changed ? "Certificate changed" : "Can't connect", icon: "xmark.circle.fill", color: .red,
                          detail: connectionError + (changed ? "" : vpnHint), step: changed ? .certificate : .test)
        }
        if let about {
            let rights = about.missing.isEmpty
                ? "\(about.privileges.count) privileges on /"
                : "Missing \(about.missing.joined(separator: ", ")): some tools will fail"
            return Status(title: "Connected", icon: "checkmark.circle.fill", color: about.missing.isEmpty ? .green : .orange,
                          detail: "Proxmox VE \(about.version) · \(rights)", step: .test)
        }
        return Status(title: "Ready", icon: "checkmark.circle", color: .green, step: .test)
    }

    private func statusSection(_ server: ProxmoxServer) -> some View {
        let status = status(of: server)
        return Section {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(status.color.gradient, in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.host ?? server.url).font(.headline)
                    Text(server.url)
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
            if let step = status.step {
                Button {
                    Task { if step == .certificate { await fetchCertificate() } else { await test() } }
                } label: {
                    HStack {
                        Text(step == .certificate ? "Get Certificate" : about == nil && connectionError == nil ? "Test Connection" : "Test Again")
                        Spacer()
                        if fetching || testing { ProgressView() }
                    }
                }
                .disabled(fetching || testing)
                .accessibilityIdentifier(step == .certificate ? "proxmox.certificate" : "proxmox.test")
            }
        }
    }

    private func certificateMessage(_ info: CertificateInfo) -> String {
        var lines = [
            info.subject.map { "\($0)\n" } ?? "",
            "SHA-256:\n\(info.fingerprint)",
            "\nCompare it with the fingerprint of pve-ssl.pem in the web UI (Datacenter › node › System › Certificates).",
        ]
        if let pinned = server?.fingerprint, pinned != info.fingerprint {
            lines.append("\nThe certificate you trusted before was:\n\(pinned)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private func load() {
        address = server?.url ?? ""
        needsVpn = server?.needsVpn ?? true
        vpnTouched = server != nil
        token = ""
        error = nil
    }

    private func save() async {
        guard let url else { return }
        saving = true
        defer { saving = false }
        let addressChanged = server?.url != url
        await store.saveProxmox(ProxmoxServer(url: url, fingerprint: server?.fingerprint, needsVpn: needsVpn), token: newToken)
        token = ""
        about = nil
        connectionError = nil
        if addressChanged || store.proxmox?.fingerprint == nil {
            await fetchCertificate()
        } else {
            await test()
        }
    }

    private func fetchCertificate() async {
        guard let server, let url = URL(string: server.url) else { return }
        fetching = true
        defer { fetching = false }
        connectionError = nil
        do {
            fetched = try await CertificateProbe.fetch(url)
            confirmingCertificate = true
        } catch {
            connectionError = String(describing: error)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            about = try await store.testProxmox()
            connectionError = nil
        } catch {
            about = nil
            connectionError = String(describing: error)
        }
    }
}
