import Foundation
import Network
import os
import Security
import Testing
@testable import PiRuntime

/// An HTTPS server on the loopback with a self-signed certificate made for the test, like Proxmox's own.
/// It records every request it reads.
final class SelfSignedServer: @unchecked Sendable {
    let fingerprint: String
    let port: UInt16
    private let listener: NWListener
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    var requests: [String] { lock.withLock { $0 } }

    init() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        let p12 = directory.appendingPathComponent("id.p12").path
        try Self.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=pve.test"])
        try Self.openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:pi"])
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: p12)) as CFData, [kSecImportExportPassphrase: "pi"] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw JSRuntimeError("PKCS12 import failed: \(status)") }
        let secIdentity = identity as! SecIdentity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(secIdentity, &certificate)
        fingerprint = PinnedCertificates.fingerprint(of: certificate!)

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(secIdentity)!)
        listener = try NWListener(using: NWParameters(tls: tls), on: .any)
        let ready = OSAllocatedUnfairLock<CheckedContinuation<UInt16, Error>?>(initialState: nil)
        let lock = lock
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                // A refused handshake ends the connection with no data: nothing was sent.
                guard let data, !data.isEmpty else { return connection.cancel() }
                lock.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
                let body = #"{"data":{"version":"9.2.5"}}"#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let listener = listener
        port = try await withCheckedThrowingContinuation { continuation in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.withLock { $0?.resume(returning: listener.port!.rawValue); $0 = nil }
                case let .failed(error): ready.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    deinit { listener.cancel() }

    var url: String { "https://127.0.0.1:\(port)/api2/json/version" }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw JSRuntimeError("openssl \(arguments[0]) failed") }
    }
}

private struct Token: ProviderKeySource {
    func apiKey(for provider: String) -> String? { provider == "proxmox" ? "pi@pve!iphone=secret" : nil }
}

/// Runs one request through the fetch bridge and returns its status or error.
private func fetch(_ url: String) async -> (status: Int?, error: String?) {
    let result = OSAllocatedUnfairLock<(Int?, String?)>(initialState: (nil, nil))
    return await withCheckedContinuation { continuation in
        let done = OSAllocatedUnfairLock(initialState: false)
        let bridge = FetchBridge(keys: Token()) { _, event in
            switch event {
            case let .response(status, _, _, _): result.withLock { $0.0 = status }
            case .chunk: break
            case .end, .error:
                if case let .error(message) = event { result.withLock { $0.1 = message } }
                if done.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: result.withLock { $0 }) }
            }
        }
        bridge.start(.init(id: 1, url: url, method: "GET", headers: [("Authorization", "PVEAPIToken=pi-host-key:proxmox")], body: nil))
    }
}

@Suite("Pinned certificates", .serialized)
struct PinnedCertificateTests {
    @Test("Get Certificate reads the fingerprint and sends nothing")
    func probe() async throws {
        let server = try await SelfSignedServer()
        let info = try await CertificateProbe.fetch(URL(string: server.url)!)
        #expect(info.fingerprint == server.fingerprint)
        #expect(info.subject == "pve.test")
        #expect(!info.systemTrusted)
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.requests.isEmpty, "the probe sent a request: \(server.requests)")
    }

    @Test("A self-signed node gets the token only when its certificate is the pinned one")
    func pinning() async throws {
        let server = try await SelfSignedServer()
        ProviderKeys.setProxmoxHost("127.0.0.1")
        defer {
            ProviderKeys.setProxmoxHost(nil)
            PinnedCertificates.set([:])
        }

        // Not pinned: the system refuses the certificate; nothing is sent.
        let unpinned = await fetch(server.url)
        #expect(unpinned.status == nil && unpinned.error != nil)
        #expect(server.requests.isEmpty)

        // Another certificate pinned: refused before the request, with a message that says why.
        PinnedCertificates.set(["127.0.0.1": String(repeating: "AB", count: 32)])
        let wrong = await fetch(server.url)
        #expect(wrong.status == nil)
        #expect(wrong.error?.contains("isn't the one trusted in Settings") == true && wrong.error?.contains(server.fingerprint) == true, "\(wrong.error ?? "")")
        #expect(server.requests.isEmpty)

        // Its own certificate pinned (in any case, with or without colons): the request goes, with the token.
        PinnedCertificates.set(["127.0.0.1": server.fingerprint.replacingOccurrences(of: ":", with: "").lowercased()])
        let right = await fetch(server.url)
        #expect(right.status == 200, "\(right.error ?? "")")
        #expect(server.requests.count == 1 && server.requests[0].contains("PVEAPIToken=pi@pve!iphone=secret"))
    }

    @Test("Fingerprints are read in the forms people paste them")
    func normalize() {
        let colons = "2E:86:E9:D1:D2:F3:A4:E4:31:CC:00:11:16:D3:69:60:52:33:17:FA:EA:3C:3A:2C:61:0B:8B:E4:9E:2A:57:32"
        #expect(PinnedCertificates.normalize(colons) == colons)
        #expect(PinnedCertificates.normalize(colons.lowercased().replacingOccurrences(of: ":", with: "")) == colons)
        #expect(PinnedCertificates.normalize("2E:86") == nil)
        #expect(PinnedCertificates.normalize(colons + "-x") == nil)
    }

    @Test("The proxmox token goes only to the node's host")
    func host() throws {
        ProviderKeys.setProxmoxHost("192.168.2.130")
        defer { ProviderKeys.setProxmoxHost(nil) }
        var used = Set<String>()
        #expect(try ProviderKeys.substitute("PVEAPIToken=pi-host-key:proxmox", host: "192.168.2.130", keys: Token(), used: &used) == "PVEAPIToken=pi@pve!iphone=secret")
        #expect(throws: (any Error).self) {
            try ProviderKeys.substitute("PVEAPIToken=pi-host-key:proxmox", host: "evil.example", keys: Token(), used: &used)
        }
        ProviderKeys.setProxmoxHost(nil)
        #expect(throws: (any Error).self, "no node in Settings") {
            try ProviderKeys.substitute("PVEAPIToken=pi-host-key:proxmox", host: "192.168.2.130", keys: Token(), used: &used)
        }
    }
}
