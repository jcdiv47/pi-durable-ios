@preconcurrency import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Synchronization
import Testing
@testable import PiSSH

/// An SSH server in the test process whose exec requests run in `/bin/sh` with `HOME` in a temporary directory, so
/// the job scripts run for real.
final class TestServer: @unchecked Sendable {
    let server: SSHServer
    let port: Int
    let home: URL
    let hostKey: NIOSSHPrivateKey
    let auth: Auth
    let userKey: (privateKey: String, publicKey: String)

    var hostKeyLine: String { String(openSSHPublicKey: hostKey.publicKey) }
    var logins: Int { auth.attempts.withLock { $0 } }

    static func start() async throws -> TestServer {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pissh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let userKey = SSHKeys.generate(comment: "pi@test")
        let auth = Auth(publicKey: try NIOSSHPublicKey(openSSHPublicKey: userKey.publicKey))
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        var lastError: Error?
        for _ in 0 ..< 10 {
            let port = Int.random(in: 20_000 ... 50_000)
            do {
                let server = try await SSHServer.host(host: "127.0.0.1", port: port, hostKeys: [hostKey], authenticationDelegate: auth)
                return TestServer(server: server, port: port, home: home, hostKey: hostKey, auth: auth, userKey: userKey)
            } catch {
                lastError = error
            }
        }
        throw lastError!
    }

    private init(server: SSHServer, port: Int, home: URL, hostKey: NIOSSHPrivateKey, auth: Auth, userKey: (String, String)) {
        self.server = server
        self.port = port
        self.home = home
        self.hostKey = hostKey
        self.auth = auth
        self.userKey = userKey
    }

    func stop() async {
        try? await server.close()
        try? FileManager.default.removeItem(at: home)
    }

    func host(auth: SSHHost.Auth = .password, pinned: String? = nil, shell: SSHHost.Shell = .sh) -> SSHHost {
        SSHHost(id: "test", name: "Test", host: "127.0.0.1", port: port, user: "pi", auth: auth, shell: shell, hostKey: pinned ?? hostKeyLine)
    }

    final class Auth: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let publicKey: NIOSSHPublicKey
        let attempts = Mutex(0)
        init(publicKey: NIOSSHPublicKey) { self.publicKey = publicKey }

        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.password, .publicKey] }

        func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            attempts.withLock { $0 += 1 }
            switch request.request {
            case let .password(password):
                responsePromise.succeed(request.username == "pi" && password.password == "secret" ? .success : .failure)
            case let .publicKey(key):
                responsePromise.succeed(request.username == "pi" && key.publicKey == publicKey ? .success : .failure)
            default:
                responsePromise.succeed(.failure)
            }
        }
    }
}

@Suite("SSH: keys")
struct SSHKeyTests {
    @Test("A generated key reads back: Ed25519, unencrypted, the same public key, a fingerprint like ssh-keygen's")
    func generated() throws {
        let (privateKey, publicKey) = SSHKeys.generate(comment: "pi@iphone")
        #expect(publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5") && publicKey.hasSuffix(" pi@iphone"))
        let info = try SSHKeys.info(ofPrivateKey: privateKey)
        #expect(info.type == "ssh-ed25519" && !info.encrypted)
        #expect(SSHKeys.normalized(info.publicKey) == SSHKeys.normalized(publicKey))
        #expect(try SSHKeys.check(privateKey: "\n" + privateKey + "\n", passphrase: nil) == info.publicKey)
        let fingerprint = try #require(SSHKeys.fingerprint(ofPublicKey: publicKey))
        #expect(fingerprint.hasPrefix("SHA256:") && fingerprint.count == 50 && !fingerprint.contains("="))
        // The same as `ssh-keygen -lf` would print for a known key.
        let known = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        let blob = Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")!
        let expected = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(SSHKeys.fingerprint(ofPublicKey: known) == expected)
    }

    @Test("Other key formats are refused with a way out")
    func refused() {
        #expect(throws: SSHFailure.self) { try SSHKeys.info(ofPrivateKey: "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----") }
        #expect(throws: SSHFailure.self) { try SSHKeys.info(ofPrivateKey: "hunter2") }
        #expect(throws: SSHFailure.self) { try SSHKeys.info(ofPrivateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----") }
    }

    @Test("Secrets round-trip as JSON")
    func secrets() throws {
        for secret in [SSHSecret.password("p@ss \"word\""), .key(privateKey: "-----BEGIN…", passphrase: nil), .key(privateKey: "k", passphrase: "x")] {
            #expect(try SSHSecret.decode(secret.encoded()) == secret)
        }
    }
}

@Suite("SSH: scripts")
struct SSHScriptTests {
    @Test("Job IDs are plain file names")
    func jobs() {
        #expect(SSHJobScript.validJob("a1b2c3-t42"))
        for bad in ["", "../x", "a b", "a/b", "$(x)", String(repeating: "a", count: 97), "é"] { #expect(!SSHJobScript.validJob(bad), "\(bad)") }
    }

    @Test("Collect output parses")
    func parse() {
        let parsed = SSHJobScript.parse("pi-ssh:done 3 123\npi-ssh:size 3 4\npi-ssh:stdout\nhi\npi-ssh:stdout\n")
        #expect(parsed == .init(state: "done", exitCode: 3, pid: 123, stdoutBytes: 3, stderrBytes: 4, stdout: "hi\npi-ssh:stdout\n"))
        #expect(SSHJobScript.parse("pi-ssh:running 0 9\npi-ssh:size 0 0\npi-ssh:stdout\n").state == "running")
        #expect(SSHJobScript.parse("pi-ssh:missing\n").state == "missing")
    }
}


@Suite("SSH: host field")
struct SSHAddressTests {
    @Test("Pasted URLs and user@host:port read as host, user and port")
    func parse() {
        func check(_ text: String, _ host: String, _ user: String? = nil, _ port: Int? = nil) {
            let parsed = SSHHost.parseAddress(text)
            #expect(parsed?.host == host && parsed?.user == user && parsed?.port == port, "\(text) → \(String(describing: parsed))")
        }
        check("192.168.2.144", "192.168.2.144")
        check(" http://192.168.2.144 ", "192.168.2.144")
        check("http://192.168.2.144/", "192.168.2.144")
        check("ssh://me@nas.local:2222", "nas.local", "me", 2222)
        check("me@box", "box", "me")
        check("box:22", "box", nil, 22)
        check("[fd00::1]:2200", "fd00::1", nil, 2200)
        check("fd00::1", "fd00::1")
        #expect(SSHHost.parseAddress("") == nil && SSHHost.parseAddress("http://") == nil && SSHHost.parseAddress("a b") == nil)
    }
}
