import Foundation
import Testing
@testable import PiSSH

/// OpenSSH's `sshd`, run as the current user on a free port with its own host key, `authorized_keys` and `HOME`, so the
/// job scripts run as they would on a real machine, through the user's login shell (which may well be fish).
final class LocalSSHD: @unchecked Sendable {
    static let binary = ["/usr/sbin/sshd", "/opt/homebrew/sbin/sshd"].first { FileManager.default.isExecutableFile(atPath: $0) }

    let directory: URL
    let home: URL
    let port: Int
    let hostKey: String
    let userKey: (privateKey: String, publicKey: String)
    private let process: Process

    static func start() async throws -> LocalSSHD {
        let binary = try #require(binary, "no sshd on this machine")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pisshd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let host = SSHKeys.generate(comment: "")
        let user = SSHKeys.generate(comment: "pi@test")
        let hostKeyFile = directory.appendingPathComponent("hostkey")
        try host.privateKey.write(to: hostKeyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostKeyFile.path)
        try (user.publicKey + "\n").write(to: directory.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        var lastError: Error?
        for _ in 0 ..< 5 {
            let port = Int.random(in: 20_000 ... 50_000)
            let config = directory.appendingPathComponent("sshd_config")
            try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKeyFile.path)
            PidFile \(directory.path)/sshd.pid
            AuthorizedKeysFile \(directory.path)/authorized_keys
            StrictModes no
            UsePAM no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            SetEnv HOME=\(home.path)

            """.write(to: config, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-D", "-f", config.path, "-E", directory.appendingPathComponent("log").path]
            try process.run()
            let server = LocalSSHD(directory: directory, home: home, port: port, hostKey: host.publicKey, userKey: user, process: process)
            for _ in 0 ..< 50 {
                if let key = try? await SSHConnections().hostKey(host: "127.0.0.1", port: port) {
                    if SSHKeys.normalized(key) == SSHKeys.normalized(host.publicKey) { return server }
                    break // another server on that port
                }
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            process.terminate()
            lastError = SSHFailure("sshd didn't start: \((try? String(contentsOf: directory.appendingPathComponent("log"), encoding: .utf8)) ?? "")")
        }
        throw lastError!
    }

    private init(directory: URL, home: URL, port: Int, hostKey: String, userKey: (String, String), process: Process) {
        self.directory = directory
        self.home = home
        self.port = port
        self.hostKey = hostKey
        self.userKey = userKey
        self.process = process
    }

    var secret: SSHSecret { .key(privateKey: userKey.privateKey, passphrase: nil) }

    func host(shell: SSHHost.Shell = .sh) -> SSHHost {
        SSHHost(id: "local", name: "Local", host: "127.0.0.1", port: port, user: NSUserName(), auth: .key, shell: shell, hostKey: hostKey)
    }

    func stop() {
        process.terminate()
        // Jobs still running (the slow test's) end with their sshd's files.
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs `body` against a fresh sshd, stopping it afterwards.
func withSSHD(_ body: (LocalSSHD) async throws -> Void) async throws {
    let server = try await LocalSSHD.start()
    defer { server.stop() }
    try await body(server)
}

@Suite("SSH: against OpenSSH", .serialized, .enabled(if: LocalSSHD.binary != nil))
struct SSHDTests {
    @Test("Test connection: logs in with the key, reports the login shell", .timeLimit(.minutes(1)))
    func test() async throws {
        try await withSSHD { server in
            let about = try await SSHConnections().test(server.host(), secret: server.secret)
            #expect(about.shell?.isEmpty == false && about.system != nil && about.hostname != nil)
            let other = SSHKeys.generate(comment: "").privateKey
            await #expect(throws: SSHFailure.self) { try await SSHConnections().test(server.host(), secret: .key(privateKey: other, passphrase: nil)) }
        }
    }

    @Test("A command: exit code, stdout and stderr apart, quotes and heredoc lookalikes as typed", .timeLimit(.minutes(1)))
    func command() async throws {
        try await withSSHD { server in
            let command = #"""
            printf '%s\n' "it's" 'a "b"' "$HOME" | sed 's/^/> /'
            echo oops >&2
            cat <<'EOF'
            PI_SSH_RUN
            EOF
            exit 3
            """#
            let result = try await SSHConnections().exec(command, job: "cmd-1", on: server.host(), secret: server.secret, timeout: 20)
            #expect(result.state == "done" && result.exitCode == 3)
            #expect(result.stdout == "> it's\n> a \"b\"\n> \(server.home.path)\nPI_SSH_RUN\n")
            #expect(result.stderr == "oops\n" && result.stderrBytes == 5)
            let jobs = server.home.appendingPathComponent(".cache/pi-durable/ssh")
            func mode(_ url: URL) throws -> Int { try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
            #expect(try mode(jobs) == 0o700 && mode(jobs.appendingPathComponent("cmd-1")) == 0o700)
            #expect(try mode(jobs.appendingPathComponent("cmd-1/out")) == 0o600, "other users can't read the output")
        }
    }

    @Test("Shells: the login shell, and fish when it's installed", .timeLimit(.minutes(1)))
    func shells() async throws {
        try await withSSHD { server in
            let connections = SSHConnections()
            let login = try await connections.exec("echo hello", job: "login-1", on: server.host(shell: .login), secret: server.secret, timeout: 20)
            #expect(login.stdout == "hello\n" && login.exitCode == 0, "\(login)")
            let hasFish = try await connections.exec("command -v fish", job: "which-fish", on: server.host(), secret: server.secret, timeout: 20)
            guard hasFish.exitCode == 0 else { return }
            let fish = try await connections.exec("set -l x (math 6 \\* 7); echo $x", job: "fish-1", on: server.host(shell: .fish), secret: server.secret, timeout: 20)
            #expect(fish.stdout == "42\n", "\(fish)")
        }
    }

    @Test("The same job twice runs once: a rerun after a crash waits for the job it started", .timeLimit(.minutes(1)))
    func replay() async throws {
        try await withSSHD { server in
            let command = #"echo run >> "$HOME/count"; wc -l < "$HOME/count" | tr -d ' '"#
            let first = try await SSHConnections().exec(command, job: "replay-1", on: server.host(), secret: server.secret, timeout: 20)
            // As after a relaunch: a new connection.
            let second = try await SSHConnections().exec(command, job: "replay-1", on: server.host(), secret: server.secret, timeout: 20)
            #expect(first.stdout == "1\n" && second == first)
            let third = try await SSHConnections().exec(command, job: "replay-2", on: server.host(), secret: server.secret, timeout: 20)
            #expect(third.stdout == "2\n")
        }
    }

    @Test("A slow command keeps running past the wait and after the connection closes; collect finds it", .timeLimit(.minutes(1)))
    func slow() async throws {
        try await withSSHD { server in
            let connections = SSHConnections()
            let started = try await connections.exec("echo early; sleep 2; echo late", job: "slow-1", on: server.host(), secret: server.secret, timeout: 0)
            #expect(started.state == "running" && started.pid != nil && started.exitCode == nil, "\(started)")
            await connections.dropAll()
            let finished = try await SSHConnections().collect(job: "slow-1", on: server.host(), secret: server.secret, wait: 10)
            #expect(finished.state == "done" && finished.exitCode == 0 && finished.stdout == "early\nlate\n", "\(finished)")
            let missing = try await connections.collect(job: "nope", on: server.host(), secret: server.secret, wait: 0)
            #expect(missing.state == "missing")
        }
    }

    @Test("Long output is cut to its start and end", .timeLimit(.minutes(1)))
    func longOutput() async throws {
        try await withSSHD { server in
            let result = try await SSHConnections().exec("seq 1 20000", job: "long-1", on: server.host(), secret: server.secret, timeout: 20)
            #expect(result.stdoutBytes == 108_894)
            #expect(result.stdout.hasPrefix("1\n2\n3\n") && result.stdout.hasSuffix("19999\n20000\n"))
            #expect(result.stdout.contains("bytes cut") && result.stdout.utf8.count < 24_200)
        }
    }

    @Test("The tool host: only the user's hosts, turned on, with a secret", .timeLimit(.minutes(1)))
    func toolHost() async throws {
        try await withSSHD { server in
            var off = server.host()
            off.id = "off"
            off.enabled = false
            let hosts = [server.host(), off]
            let secret = server.secret
            let tools = SSHToolHost(hosts: { hosts }, secret: { $0.id == "local" ? secret : nil }, installID: "abc123", connections: SSHConnections())
            let json = try await tools.handle("ssh.exec", #"{"host":"local","command":"echo ok","idempotencyKey":"t7"}"#)
            let result = try JSONDecoder().decode(SSHJobResult.self, from: Data(json.utf8))
            #expect(result.job == "abc123-t7" && result.stdout == "ok\n" && result.host == "local")
            let again = try JSONDecoder().decode(SSHJobResult.self, from: Data(try await tools.handle("ssh.job", #"{"host":"local","job":"abc123-t7"}"#).utf8))
            #expect(again == result)
            do {
                _ = try await tools.handle("ssh.exec", #"{"host":"nas","command":"ls","idempotencyKey":"t8"}"#)
                Issue.record("ran on an unknown host")
            } catch let failure as SSHFailure {
                #expect(failure.description == "No SSH host nas. The user's hosts: local.")
            }
            await #expect(throws: SSHFailure.self) { try await tools.handle("ssh.exec", #"{"host":"off","command":"ls","idempotencyKey":"t9"}"#) }
            await #expect(throws: SSHFailure.self) { try await tools.handle("ssh.job", #"{"host":"local","job":"../../etc"}"#) }
        }
    }
}

@Suite("SSH: host keys and logins", .serialized)
struct SSHLoginTests {
    @Test("Reading the host key offers no login; a password logs in only with the pinned key", .timeLimit(.minutes(1)))
    func hostKeyThenLogin() async throws {
        let server = try await TestServer.start()
        defer { Task { await server.stop() } }
        let connections = SSHConnections()
        let key = try await connections.hostKey(host: "127.0.0.1", port: server.port)
        #expect(SSHKeys.normalized(key) == SSHKeys.normalized(server.hostKeyLine))
        #expect(server.logins == 0, "nothing was offered before the user confirmed the key")

        do {
            _ = try await connections.test(server.host(), secret: .password("wrong"))
            Issue.record("logged in with a wrong password")
        } catch let failure as SSHFailure {
            #expect(failure.description.contains("refused the user name or password"), "\(failure)")
        }
        #expect(server.logins > 0)
    }

    @Test("A changed host key stops the connection before login", .timeLimit(.minutes(1)))
    func changedKey() async throws {
        let server = try await TestServer.start()
        defer { Task { await server.stop() } }
        let connections = SSHConnections()
        let impostor = SSHKeys.generate(comment: "").publicKey
        do {
            _ = try await connections.test(server.host(pinned: impostor), secret: .password("secret"))
            Issue.record("connected despite a different host key")
        } catch let failure as SSHFailure {
            #expect(failure.description.contains("host key changed"), "\(failure)")
        }
        #expect(server.logins == 0)
        let unpinned = SSHHost(id: "x", name: "X", host: "127.0.0.1", port: server.port, user: "pi", auth: .password)
        await #expect(throws: SSHFailure.self) { try await connections.exec("true", job: "j", on: unpinned, secret: .password("secret"), timeout: 1) }
    }
}
