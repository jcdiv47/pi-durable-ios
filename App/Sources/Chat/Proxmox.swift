import Foundation
import PiRuntime

/// Settings › Proxmox: the user's Proxmox VE node. The token is the Keychain item `proxmox`;
/// the node's certificate is pinned by its SHA-256 fingerprint, and the token goes only to its host.
struct ProxmoxServer: Codable, Equatable {
    /// `https://host:port`, without a path.
    var url: String
    /// The certificate the user trusted, `2E:86:…`; nil until they do.
    var fingerprint: String?
    var needsVpn: Bool

    var host: String? { URL(string: url)?.host()?.lowercased() }

    /// What the user typed (`192.168.2.130`, `pve:8006`, a pasted `https://pve.lan:8006/#v1:0:…`) as `https://host:port`.
    static func normalize(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        if components.port == nil { components.port = 8006 }
        return components.string
    }

    /// Whether App Transport Security leaves the host to Pi's own check. It does for IP addresses, names without a dot
    /// and `.local` (NSAllowsLocalNetworking) and `*.ts.net` (the app's exception); elsewhere iOS insists on a certificate
    /// it trusts itself, so a pinned self-signed one fails.
    static func allowsPinning(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".ts.net") || host.hasSuffix(".local") || !host.contains(".") { return true }
        if host.contains(":") { return true } // IPv6
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    func info(hasToken: Bool) -> PiHarness.ProxmoxInfo {
        PiHarness.ProxmoxInfo(url: url, ready: hasToken && fingerprint != nil, needsVpn: needsVpn)
    }

    /// A pasted token (`pi@pve!iphone=0d3c…`, also with `PVEAPIToken=` in front) as Proxmox wants it, or nil.
    static func normalizeToken(_ text: String) -> String? {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("pveapitoken=") { token = String(token.dropFirst("PVEAPIToken=".count)) }
        guard token.wholeMatch(of: /[^@\s!=]+@[^@\s!=]+![^@\s!=]+=[0-9a-fA-F-]{36}/) != nil else { return nil }
        return token
    }

    /// What the user pastes into the node's shell for a read-only token (the ADR's first step).
    static let setupCommands = """
    pveum user add pi@pve --comment "Pi on iPhone"
    pveum user token add pi@pve iphone --privsep 1 --comment "Pi on iPhone"
    pveum acl modify / --users pi@pve --tokens 'pi@pve!iphone' --roles PVEAuditor
    """
}

enum ProxmoxServerFile {
    private static let key = "proxmoxServer"

    static func load() -> ProxmoxServer? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ProxmoxServer.self, from: $0) }
    }

    static func save(_ server: ProxmoxServer?) {
        if let server, let data = try? JSONEncoder().encode(server) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// What the connection test found.
struct ProxmoxAbout: Equatable {
    var version: String
    /// The token's privileges on `/`, sorted.
    var privileges: [String]

    /// The tools need these; the rest of a read-only role is extra.
    static let needed = ["Sys.Audit", "VM.Audit", "Datastore.Audit"]
    var missing: [String] { Self.needed.filter { !privileges.contains($0) } }
}

struct ProxmoxFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum ProxmoxClient {
    /// Settings' "Test Connection": the version, and what the token may do. Uses the pins, so it fails the same way the
    /// tools would.
    static func test(_ server: ProxmoxServer, token: String) async throws -> ProxmoxAbout {
        let delegate = PinnedTrustDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        func get(_ path: String) async throws -> Any? {
            guard let url = URL(string: server.url + "/api2/json" + path) else { throw ProxmoxFailure("The address isn't valid.") }
            var request = URLRequest(url: url)
            request.setValue("PVEAPIToken=\(token)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if let refused = delegate.refusedFingerprint {
                    throw ProxmoxFailure(PinnedCertificates.mismatchMessage(host: server.host ?? "the node", actual: refused))
                }
                throw ProxmoxFailure("Can't reach \(server.host ?? "the node"): \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch status {
            case 200: return body?["data"]
            case 401: throw ProxmoxFailure("The token was refused. Check that it's copied whole, and that it hasn't expired or been removed.")
            case 403: throw ProxmoxFailure("The token may not do this: \((body?["message"] as? String ?? "permission denied").trimmingCharacters(in: .whitespacesAndNewlines))")
            default: throw ProxmoxFailure("The node answered \(status) \((body?["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        let version = try await get("/version") as? [String: Any]
        let permissions = try await get("/access/permissions?path=/") as? [String: [String: Any]]
        return ProxmoxAbout(
            version: [version?["version"] as? String, (version?["release"] as? String).map { "release \($0)" }].compactMap { $0 }.joined(separator: ", "),
            privileges: (permissions?["/"]?.keys).map { $0.sorted() } ?? []
        )
    }
}
