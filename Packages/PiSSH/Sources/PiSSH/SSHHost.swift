import Foundation

/// A machine the user added in Settings › SSH Hosts. The app keeps the list in Application
/// Support (`ssh-hosts.json`); the password or private key is the Keychain item `ssh-<id>` (`SSHSecret`), which only
/// Swift reads. JS gets the list without secrets (`SshHostConfig` in `js/src/app/ssh.ts`).
public struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    /// Lowercase letters and digits, unique; what the model names the host by.
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var auth: Auth
    /// The shell the agent's commands run in.
    public var shell: Shell
    /// The server's host key as an OpenSSH public key line (`ssh-ed25519 AAAA…`), pinned when the user confirmed its
    /// fingerprint. Nil: not confirmed yet, so no command runs.
    public var hostKey: String?
    /// The public half of the saved key (`ssh-ed25519 AAAA… comment`), shown so the user can add it to the machine's
    /// `~/.ssh/authorized_keys`. Not a secret.
    public var publicKey: String?
    public var enabled: Bool
    /// Reached through the VPN: a failed connection says the VPN may be off.
    public var needsVpn: Bool
    /// Settings' "Run without asking": commands still ask while the conversation holds web pages or MCP results.
    public var runWithoutAsking: Bool

    public enum Auth: String, Codable, Sendable, CaseIterable {
        case password, key
    }

    public enum Shell: String, Codable, Sendable, CaseIterable {
        /// The user's login shell (`$SHELL`), as `ssh host command` would use.
        case login, bash, zsh, fish, sh

        /// The command that runs a command string, for the job script (POSIX sh, single-quote safe).
        var invocation: String {
            switch self {
            case .login: #""${SHELL:-/bin/sh}" -l -c"#
            case .bash: "bash -l -c"
            case .zsh: "zsh -l -c"
            case .fish: "fish -l -c"
            case .sh: "sh -c"
            }
        }

        public var title: String {
            switch self {
            case .login: "Login shell"
            case .bash: "bash"
            case .zsh: "zsh"
            case .fish: "fish"
            case .sh: "sh"
            }
        }
    }

    public init(
        id: String, name: String, host: String, port: Int = 22, user: String, auth: Auth = .key, shell: Shell = .login,
        hostKey: String? = nil, publicKey: String? = nil, enabled: Bool = true, needsVpn: Bool = false, runWithoutAsking: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.shell = shell
        self.hostKey = hostKey
        self.publicKey = publicKey
        self.enabled = enabled
        self.needsVpn = needsVpn
        self.runWithoutAsking = runWithoutAsking
    }

    public var keyName: String { SSHHost.keyPrefix + id }
    public static let keyPrefix = "ssh-"

    /// `user@host` or `user@host:port`.
    public var address: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }

    /// The fingerprint of the pinned host key, `SHA256:…` as `ssh-keygen -l` prints it.
    public var fingerprint: String? { hostKey.flatMap(SSHKeys.fingerprint(ofPublicKey:)) }

    /// What the user typed as the host, read the way they likely meant it: a bare name or IP, `user@host`, `host:port`,
    /// `[v6]:port`, or a pasted URL (`http://…`, `ssh://user@host:2222/`). Nil when no host is left.
    public static func parseAddress(_ text: String) -> (host: String, user: String?, port: Int?)? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = rest[..<slash] }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
            rest = rest[rest.index(after: rest.startIndex) ..< close]
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            port = Int(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }
        let host = String(rest)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
        return (host, user.flatMap { $0.isEmpty ? nil : $0 }, port.flatMap { (1 ... 65535).contains($0) ? $0 : nil })
    }

    /// An ID from the name: `Home Server` → `homeserver`, unique among `taken`.
    public static func id(for name: String, taken: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let base = String(name.lowercased().filter { allowed.contains($0) }.prefix(16))
        let stem = base.isEmpty ? "host" : base
        var id = stem
        var n = 2
        while taken.contains(id) {
            id = "\(stem)\(n)"
            n += 1
        }
        return id
    }
}

/// A host's credential, stored as JSON in the Keychain item `ssh-<id>`. Never sent to JS.
public enum SSHSecret: Codable, Sendable, Equatable {
    case password(String)
    /// An unencrypted OpenSSH Ed25519 private key, or an encrypted one with its passphrase.
    case key(privateKey: String, passphrase: String?)

    public func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }

    public static func decode(_ text: String) throws -> SSHSecret { try JSONDecoder().decode(SSHSecret.self, from: Data(text.utf8)) }
}
