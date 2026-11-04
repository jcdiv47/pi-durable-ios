import Foundation
import PiRuntime
import PiSSH
import Synchronization

/// Settings › SSH Hosts' list, in a JSON file in Application Support (docs/adr/0012-ssh-hosts.md). Passwords and keys
/// are in the Keychain (`SSHSecrets`), never in this file.
enum SSHHostFile {
    static var url: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("ssh-hosts.json")
    }

    static func load() -> [SSHHost] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Hosts saved before the host field read pasted URLs (`http://192.168.2.144`) keep just the host.
        return ((try? JSONDecoder().decode([SSHHost].self, from: data)) ?? []).map { host in
            var host = host
            if let parsed = SSHHost.parseAddress(host.host) { host.host = parsed.host }
            return host
        }
    }

    static func save(_ hosts: [SSHHost]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(hosts).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// SSH passwords and private keys: a Keychain service of their own, apart from the provider keys, so the fetch bridge
/// (which substitutes provider keys into HTTP requests) can never read one. Readable after first unlock, so scheduled
/// tasks can use a host; never synced off the iPhone.
enum SSHSecrets {
    static let keychain = KeychainKeys(service: "dev.jcdiv47.pidurable.ssh")

    static func secret(for host: SSHHost) -> SSHSecret? {
        keychain.apiKey(for: host.keyName).flatMap { try? SSHSecret.decode($0) }
    }

    static func has(_ host: SSHHost) -> Bool { keychain.hasKey(for: host.keyName) }

    static func set(_ secret: SSHSecret, for host: SSHHost) throws { try keychain.setKey(try secret.encoded(), for: host.keyName) }

    static func remove(_ host: SSHHost) { try? keychain.removeKey(for: host.keyName) }
}

/// The host list as the SSH tool host reads it, off the main actor (host calls arrive on any thread).
final class SSHHostList: Sendable {
    static let shared = SSHHostList()
    private let list = Mutex<[SSHHost]>([])

    var hosts: [SSHHost] { list.withLock { $0 } }
    func set(_ hosts: [SSHHost]) { list.withLock { $0 = hosts } }
}

/// A random ID for this installation: it prefixes SSH job IDs, so a reinstalled app (whose task IDs start over) never
/// mistakes an old job on a machine for its own.
enum SSHInstall {
    static var id: String {
        let key = "sshInstallID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

extension SSHHost {
    /// Whether the host's name or address is only reachable inside the homelab or over a VPN.
    var looksPrivate: Bool { MCPServer.isPrivate(host: host) }

    /// What JS gets: no host key, no secret.
    func info(hasSecret: Bool) -> PiHarness.SSHHostInfo {
        .init(
            id: id, name: name, address: address, shell: shell.rawValue, enabled: enabled, ready: hostKey != nil && hasSecret,
            needsVpn: needsVpn, runWithoutAsking: runWithoutAsking
        )
    }
}
