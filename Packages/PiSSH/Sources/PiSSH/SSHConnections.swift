@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOSSH
import Synchronization

/// What a job looked like when Pi last checked: `ssh_exec` and `ssh_job` return it to JS.
public struct SSHJobResult: Codable, Sendable, Equatable {
    public let host: String
    public let job: String
    /// `done`, `running` (still going when the wait ended), `lost` (its start was cut off), or `missing` (no such job).
    public let state: String
    public let exitCode: Int?
    public let pid: Int?
    public let stdout: String
    public let stderr: String
    public let stdoutBytes: Int
    public let stderrBytes: Int
}

/// What Settings' "Test connection" found.
public struct SSHAbout: Sendable, Equatable {
    public let shell: String?
    public let system: String?
    public let hostname: String?
}

/// SSH connections to the user's hosts, kept open between commands and opened again when iOS (or the network) closed
/// them. Every connection checks the host key against the pinned one.
public actor SSHConnections {
    public static let shared = SSHConnections()

    private struct Open {
        let client: SSHClient
        /// What the connection was made with; another value means the host changed in Settings.
        let signature: String
    }

    private var open: [String: Open] = [:]
    private let connectTimeout: TimeAmount

    public init(connectTimeout: TimeAmount = .seconds(12)) {
        self.connectTimeout = connectTimeout
    }

    // MARK: Settings

    /// Connects only far enough to read the server's host key, and hangs up before logging in, so no password or key
    /// is offered to a server the user hasn't confirmed. Returns the key as an OpenSSH public key line.
    public func hostKey(host: String, port: Int) async throws -> String {
        let validator = HostKeyCheck(pinned: nil)
        do {
            let client = try await connect(host: host, port: port, auth: .passwordBased(username: "pi", password: ""), validator: validator)
            try? await client.close()
        } catch {
            if let seen = validator.seen { return seen }
            throw describe(error, host: host)
        }
        guard let seen = validator.seen else { throw SSHFailure("\(host) sent no host key.") }
        return seen
    }

    /// Logs in with the pinned key and the secret, and asks the machine about itself.
    public func test(_ host: SSHHost, secret: SSHSecret) async throws -> SSHAbout {
        drop(host.id)
        let (stdout, _) = try await run(SSHJobScript.about, on: host, secret: secret, timeout: 20)
        var values: [String: String] = [:]
        for line in stdout.split(separator: "\n") where line.hasPrefix("pi-ssh:") {
            let parts = line.dropFirst("pi-ssh:".count).split(separator: " ", maxSplits: 1)
            if let key = parts.first { values[String(key)] = parts.count > 1 ? String(parts[1]) : "" }
        }
        func value(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
        return SSHAbout(shell: value("shell"), system: value("system"), hostname: value("host"))
    }

    // MARK: Jobs

    /// Starts `command` as job `job` unless it already exists, then waits up to `timeout` seconds for it.
    public func exec(_ command: String, job: String, on host: SSHHost, secret: SSHSecret, timeout: Int) async throws -> SSHJobResult {
        guard SSHJobScript.validJob(job) else { throw SSHFailure("Bad job ID \(job).") }
        let (started, _) = try await run(SSHJobScript.start(job: job, command: command, shell: host.shell), on: host, secret: secret, timeout: 30)
        if let error = started.split(separator: "\n").first(where: { $0.hasPrefix("pi-ssh:error") }) {
            throw SSHFailure(String(error.dropFirst("pi-ssh:error ".count)))
        }
        guard started.contains("pi-ssh:started") || started.contains("pi-ssh:exists") else {
            throw SSHFailure("The job didn't start on \(host.name): \(started.prefix(500))")
        }
        return try await collect(job: job, on: host, secret: secret, wait: timeout)
    }

    /// Waits up to `wait` seconds for job `job` and returns its state and output so far.
    public func collect(job: String, on host: SSHHost, secret: SSHSecret, wait: Int) async throws -> SSHJobResult {
        guard SSHJobScript.validJob(job) else { throw SSHFailure("Bad job ID \(job).") }
        let (stdout, stderr) = try await run(SSHJobScript.collect(job: job, seconds: wait), on: host, secret: secret, timeout: wait + 30)
        let collected = SSHJobScript.parse(stdout)
        return SSHJobResult(
            host: host.id, job: job, state: collected.state, exitCode: collected.exitCode, pid: collected.pid,
            stdout: collected.stdout, stderr: stderr, stdoutBytes: collected.stdoutBytes, stderrBytes: collected.stderrBytes
        )
    }

    /// Closes the host's connection (it changed or was removed).
    public func drop(_ id: String) {
        guard let open = open.removeValue(forKey: id) else { return }
        Task { try? await open.client.close() }
    }

    public func dropAll() {
        for id in open.keys { drop(id) }
    }

    // MARK: Connections

    /// Runs `script` with `sh -s` and returns its stdout and stderr. A cached connection that turns out to be dead is
    /// replaced once.
    func run(_ script: String, on host: SSHHost, secret: SSHSecret, timeout: Int) async throws -> (String, String) {
        let (client, fresh) = try await client(for: host, secret: secret)
        do {
            return try await withTimeout(seconds: timeout, host: host) { try await Self.exec(script, on: client) }
        } catch let error as SSHFailure {
            throw error
        } catch {
            drop(host.id)
            guard !fresh else { throw describe(error, host: host.host) }
            let (client, _) = try await self.client(for: host, secret: secret)
            do {
                return try await withTimeout(seconds: timeout, host: host) { try await Self.exec(script, on: client) }
            } catch let error as SSHFailure {
                throw error
            } catch {
                drop(host.id)
                throw describe(error, host: host.host)
            }
        }
    }

    private static func exec(_ script: String, on client: SSHClient) async throws -> (String, String) {
        var stdout = ByteBuffer(), stderr = ByteBuffer()
        var ended = false
        do {
            try await client.withExec("sh -s") { inbound, outbound in
                try await outbound.write(ByteBuffer(string: script))
                for try await chunk in inbound {
                    switch chunk {
                    case var .stdout(buffer): stdout.writeBuffer(&buffer)
                    case var .stderr(buffer): stderr.writeBuffer(&buffer)
                    }
                }
                ended = true
            }
        } catch {
            // `withExec` closes the channel after the output ended, and throws when the server already closed it.
            guard ended else { throw error }
        }
        return (String(buffer: stdout), String(buffer: stderr))
    }

    private func withTimeout<T: Sendable>(seconds: Int, host: SSHHost, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SSHFailure("\(host.name) stopped answering.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func client(for host: SSHHost, secret: SSHSecret) async throws -> (SSHClient, fresh: Bool) {
        guard let pinned = host.hostKey else { throw SSHFailure("\(host.name)'s host key isn't confirmed yet. Confirm it in Settings › SSH Hosts.") }
        let signature = [host.host, String(host.port), host.user, pinned, (try? secret.encoded()) ?? ""].joined(separator: "\n")
        if let cached = open[host.id], cached.signature == signature, cached.client.isConnected { return (cached.client, false) }
        drop(host.id)
        let auth = try SSHKeys.authentication(user: host.user, secret: secret)
        let validator = HostKeyCheck(pinned: pinned)
        let client: SSHClient
        do {
            client = try await connect(host: host.host, port: host.port, auth: auth, validator: validator)
        } catch {
            if let seen = validator.seen, SSHKeys.normalized(seen) != SSHKeys.normalized(pinned) {
                throw SSHFailure(
                    "\(host.name)'s host key changed (now \(SSHKeys.fingerprint(ofPublicKey: seen) ?? "?")). Someone may be in the way, or the machine was reinstalled. Pi won't connect until you confirm the new key in Settings › SSH Hosts."
                )
            }
            throw describe(error, host: host.host, auth: host.auth)
        }
        open[host.id] = Open(client: client, signature: signature)
        return (client, true)
    }

    private func connect(host: String, port: Int, auth: SSHAuthenticationMethod, validator: HostKeyCheck) async throws -> SSHClient {
        var settings = SSHClientSettings(host: host, port: port, authenticationMethod: { auth }, hostKeyValidator: .custom(validator))
        settings.connectTimeout = connectTimeout
        return try await SSHClient.connect(to: settings)
    }

    private func describe(_ error: Error, host: String, auth: SSHHost.Auth? = nil) -> SSHFailure {
        if let failure = error as? SSHFailure { return failure }
        if let error = error as? SSHClientError, case .allAuthenticationOptionsFailed = error {
            return SSHFailure(auth == .password ? "\(host) refused the user name or password." : "\(host) refused the key. Is its public key in ~/.ssh/authorized_keys?")
        }
        if error is ChannelError || error is IOError {
            return SSHFailure("Can't reach \(host): \(error)")
        }
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("connect") || text.localizedCaseInsensitiveContains("timeout") || text.localizedCaseInsensitiveContains("refused") {
            return SSHFailure("Can't reach \(host): \(text)")
        }
        return SSHFailure("SSH to \(host) failed: \(text)")
    }
}

/// Checks the server's host key: with `pinned`, only that key; without, it notes the key and refuses, so the connection
/// ends before any login is offered.
final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let pinned: String?
    private let seenKey = Mutex<String?>(nil)

    init(pinned: String?) {
        self.pinned = pinned
    }

    var seen: String? { seenKey.withLock { $0 } }

    struct Rejected: Error {}

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = SSHKeys.line(hostKey)
        seenKey.withLock { $0 = line }
        if let pinned, SSHKeys.normalized(pinned) == SSHKeys.normalized(line) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(Rejected())
        }
    }
}
