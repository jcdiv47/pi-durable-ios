import Darwin
import Foundation
import PiUI

/// An MCP server the user added in Settings › MCP servers. Swift owns the list and the
/// last tool list each server returned; JS gets both (`McpServerConfig` in `js/src/app/mcp.ts`) when Pi opens and on
/// every change. The token is the Keychain item `mcp-<id>`, sent only to `url`'s host.
struct MCPServer: Codable, Identifiable, Hashable {
    /// Lowercase letters and digits, unique; prefixes the server's tools (`mcp__<id>__…`).
    var id: String
    var name: String
    /// The Streamable HTTP endpoint, such as `http://100.64.0.2:8123/api/mcp`.
    var url: String
    /// The header the token goes in: `Authorization` gets `Bearer <token>`, any other header the bare token. Nil: no
    /// auth.
    var authHeader: String?
    var enabled = true
    /// Reached through the VPN (Tailscale, sing-box): Pi warns when the VPN looks off and the server can't be reached.
    var needsVpn: Bool
    /// The last `tools/list`, as the server sent it; schemas are arbitrary JSON.
    var tools: JSONValue?
    var instructions: String?
    var serverName: String?

    var host: String? { URL(string: url)?.host()?.lowercased() }
    var keyName: String { MCPServer.keyPrefix + id }
    var toolCount: Int {
        if case let .array(tools) = tools { return tools.count }
        return 0
    }

    static let keyPrefix = "mcp-"

    /// An ID from the name: `Home Assistant` → `homeassistant`, unique among `taken`.
    static func id(for name: String, taken: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let base = String(name.lowercased().filter { allowed.contains($0) }.prefix(16))
        let stem = base.isEmpty ? "server" : base
        var id = stem
        var n = 2
        while taken.contains(id) {
            id = "\(stem)\(n)"
            n += 1
        }
        return id
    }

    /// Whether `host` is only reachable inside the homelab or over a VPN: private and CGNAT (Tailscale) IPv4 ranges,
    /// IPv6 ULAs, `.local`, Tailscale's `.ts.net`, and names without a dot.
    static func isPrivate(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".ts.net") || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if host == "localhost" { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 && host.split(separator: ".").count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true // CGNAT, Tailscale's addresses
            default: return false
            }
        }
        if host.contains(":") { return host.hasPrefix("fd") || host.hasPrefix("fc") || host.hasPrefix("fe80") }
        return !host.contains(".")
    }

    /// What JS gets: the config with the cached tools (`McpServerConfig`).
    var config: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "url": .string(url), "enabled": .bool(enabled), "needsVpn": .bool(needsVpn),
        ]
        if let authHeader { object["authHeader"] = .string(authHeader) }
        if let tools { object["tools"] = tools }
        if let instructions { object["instructions"] = .string(instructions) }
        if let serverName { object["serverName"] = .string(serverName) }
        return .object(object)
    }
}

/// A server's state after the app last talked to it (`McpStatus` in JS).
struct MCPStatus: Decodable, Hashable {
    let id: String
    /// `ok`, `unreachable`, `unauthorized` or `error`.
    let state: String
    let error: String?
    let checkedAt: Double
    let tools: JSONValue?
    let instructions: String?
    let serverName: String?

    var date: Date { Date(timeIntervalSince1970: checkedAt / 1000) }
}

/// The server list, in a JSON file in Application Support (tool schemas make it too big for UserDefaults).
enum MCPServerFile {
    static var url: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("mcp-servers.json")
    }

    static func load() -> [MCPServer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MCPServer].self, from: data)) ?? []
    }

    static func save(_ servers: [MCPServer]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(servers).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Whether a VPN tunnel looks up. iOS tells an app nothing about another app's VPN (sing-box, Tailscale), so this
/// looks for an up tunnel interface (`utun`, `ipsec`, `ppp`, `tun`, `tap`) with an IPv4 address: iOS keeps some `utun`
/// interfaces of its own, but those carry only IPv6 link-local addresses. A hint for the warning; whether a server
/// answers is what counts.
enum VPNStatus {
    static func tunnelUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        let prefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard prefixes.contains(where: name.hasPrefix),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            return true
        }
        return false
    }
}
