import Foundation

/// Answers the JS SSH tools (`js/src/app/ssh.ts`) through `hostCall`: `ssh.exec` and `ssh.job`. JS names a host by its
/// ID and never sees a password, a key or a host key; the host must be one the user added, turned on and confirmed.
public struct SSHToolHost: Sendable {
    public static let handlers: Set<String> = ["ssh.exec", "ssh.job"]
    /// The longest a call waits; the job keeps running after that and `ssh_job` waits again.
    public static let maxWait = 600

    let hosts: @Sendable () -> [SSHHost]
    let secret: @Sendable (SSHHost) -> SSHSecret?
    /// Prefixes job IDs, so a reinstall (which starts task IDs over) never finds an old install's job.
    let installID: String
    let connections: SSHConnections

    public init(
        hosts: @escaping @Sendable () -> [SSHHost], secret: @escaping @Sendable (SSHHost) -> SSHSecret?, installID: String,
        connections: SSHConnections = .shared
    ) {
        self.hosts = hosts
        self.secret = secret
        self.installID = installID
        self.connections = connections
    }

    struct ExecArguments: Decodable {
        let host: String
        let command: String
        let timeoutSeconds: Int?
        /// From the tool task (`t<taskId>`): the same call after a restart is the same job.
        let idempotencyKey: String
    }

    struct JobArguments: Decodable {
        let host: String
        let job: String
        let waitSeconds: Int?
    }

    public func handle(_ name: String, _ json: String) async throws -> String {
        let data = Data(json.utf8)
        let result: SSHJobResult
        switch name {
        case "ssh.exec":
            let args = try JSONDecoder().decode(ExecArguments.self, from: data)
            let (host, secret) = try resolve(args.host)
            guard !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SSHFailure("The command is empty.") }
            let job = "\(installID)-\(args.idempotencyKey)"
            result = try await connections.exec(args.command, job: job, on: host, secret: secret, timeout: Self.clamp(args.timeoutSeconds, default: 60))
        case "ssh.job":
            let args = try JSONDecoder().decode(JobArguments.self, from: data)
            let (host, secret) = try resolve(args.host)
            result = try await connections.collect(job: args.job, on: host, secret: secret, wait: Self.clamp(args.waitSeconds, default: 30))
        default:
            throw SSHFailure("No SSH handler \(name).")
        }
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    static func clamp(_ seconds: Int?, default value: Int) -> Int { min(max(seconds ?? value, 0), maxWait) }

    private func resolve(_ id: String) throws -> (SSHHost, SSHSecret) {
        let all = hosts()
        guard let host = all.first(where: { $0.id == id }) else {
            let known = all.filter(\.enabled).map(\.id)
            throw SSHFailure("No SSH host \(id). The user's hosts: \(known.isEmpty ? "none" : known.joined(separator: ", ")).")
        }
        guard host.enabled else { throw SSHFailure("\(host.name) is turned off in Settings › SSH Hosts.") }
        guard let secret = secret(host) else { throw SSHFailure("\(host.name) has no saved \(host.auth == .password ? "password" : "key"). Add it in Settings › SSH Hosts.") }
        return (host, secret)
    }
}
