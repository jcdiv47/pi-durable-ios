import Foundation
import Network
import Synchronization
import Testing
@testable import PiRuntime

private struct EndpointKeys: ProviderKeySource {
    func apiKey(for provider: String) -> String? {
        ["http-ha": "ha-secret", "http-ntfy": "ntfy/secret=1", "http-local": "local-secret", "deepseek": "sk-test"][provider]
    }
}

/// Endpoint secrets are pinned to the endpoint's base URL: scheme, host, port, and whole path segments after resolving
/// dot segments and percent-encoding. Serialized: `ProviderKeys` holds one endpoint list for the process.
@Suite(.serialized)
struct HTTPEndpointTests {
    private func header(_ url: String, _ provider: String = "http-ha") throws -> String {
        var used = Set<String>()
        return try ProviderKeys.substitute("Bearer pi-host-key:\(provider)", url: URL(string: url)!, keys: EndpointKeys(), used: &used)
    }

    private func allowed(_ url: String, _ provider: String = "http-ha") -> Bool {
        (try? header(url, provider)) != nil
    }

    @Test("A secret goes only to its endpoint's scheme, host and port")
    func origin() throws {
        ProviderKeys.setHTTPEndpoints(["ha": "http://100.64.0.2:8123/api"])
        defer { ProviderKeys.setHTTPEndpoints([:]) }
        #expect(try header("http://100.64.0.2:8123/api/states") == "Bearer ha-secret")
        #expect(allowed("HTTP://100.64.0.2:8123/api"), "scheme compared without case")
        #expect(!allowed("https://100.64.0.2:8123/api/states"), "another scheme")
        #expect(!allowed("http://100.64.0.3:8123/api/states"), "another host")
        #expect(!allowed("http://100.64.0.2:8124/api/states"), "another port")
        #expect(!allowed("http://100.64.0.2/api/states"), "the default port is another port")
        #expect(!allowed("http://user@100.64.0.2:8123/api/states"), "a user in the URL")
        #expect(!allowed("http://100.64.0.2:8123/api/states", "http-nas"), "an endpoint not in Settings")

        ProviderKeys.setHTTPEndpoints(["ha": "https://HA.example.com/api/"])
        #expect(allowed("https://ha.example.com:443/api/states"), "the default port written out; host without case")
        #expect(!allowed("http://ha.example.com/api/states"))

        ProviderKeys.setHTTPEndpoints([:])
        #expect(!allowed("https://ha.example.com/api/states"), "a removed endpoint")
    }

    @Test("A secret goes only under the base path, on whole segments")
    func pathSegments() {
        ProviderKeys.setHTTPEndpoints(["ha": "http://100.64.0.2:8123/api"])
        defer { ProviderKeys.setHTTPEndpoints([:]) }
        #expect(allowed("http://100.64.0.2:8123/api"))
        #expect(allowed("http://100.64.0.2:8123/api/"))
        #expect(allowed("http://100.64.0.2:8123/api/states/light.kitchen?x=1"))
        #expect(!allowed("http://100.64.0.2:8123/apiary"), "not a whole segment")
        #expect(!allowed("http://100.64.0.2:8123/"), "above the base")
        #expect(!allowed("http://100.64.0.2:8123/admin"))
        #expect(!allowed("http://100.64.0.2:8123/API/states"), "paths compare with case")
    }

    @Test("Dot segments and percent-encoding are resolved before the path is compared")
    func dotSegments() {
        ProviderKeys.setHTTPEndpoints(["ha": "http://100.64.0.2:8123/api"])
        defer { ProviderKeys.setHTTPEndpoints([:]) }
        #expect(!allowed("http://100.64.0.2:8123/api/../admin"))
        #expect(!allowed("http://100.64.0.2:8123/api/%2e%2e/admin"))
        #expect(!allowed("http://100.64.0.2:8123/api/%2E%2E/admin"))
        #expect(!allowed("http://100.64.0.2:8123/api/.%2e/admin"))
        #expect(!allowed("http://100.64.0.2:8123/api/states%2F..%2F..%2Fadmin"), "an encoded slash")
        #expect(!allowed("http://100.64.0.2:8123/api/states%5C..%5Cadmin"), "an encoded backslash")
        #expect(!allowed("http://100.64.0.2:8123/api/../../.."), "above the root")
        #expect(!allowed("http://100.64.0.2:8123/%61pi/../admin"))
        #expect(allowed("http://100.64.0.2:8123/%61pi/states"), "an encoded letter is the letter")
        #expect(allowed("http://100.64.0.2:8123/api/states/../config"), "still inside after resolving")
        #expect(allowed("http://100.64.0.2:8123/api/./states"))
    }

    @Test("Query-parameter auth: the secret in the query goes only inside the base, percent-encoded")
    func queryAuth() throws {
        ProviderKeys.setHTTPEndpoints(["ntfy": "https://ntfy.example.com/alerts"])
        defer { ProviderKeys.setHTTPEndpoints([:]) }
        var used = Set<String>()
        let url = try ProviderKeys.substitute(
            url: URL(string: "https://ntfy.example.com/alerts/up?title=Hi&auth=pi-host-key%3Ahttp-ntfy")!, keys: EndpointKeys(), used: &used
        )
        #expect(url.query == "title=Hi&auth=ntfy/secret%3D1")
        #expect(used == ["http-ntfy"])
        for refused in [
            "https://ntfy.example.com/other?auth=pi-host-key%3Ahttp-ntfy",
            "https://ntfy.example.com/alerts/../other?auth=pi-host-key:http-ntfy",
            "https://evil.example/alerts?auth=pi-host-key:http-ntfy",
        ] {
            #expect(throws: (any Error).self, "\(refused)") {
                try ProviderKeys.substitute(url: URL(string: refused)!, keys: EndpointKeys(), used: &used)
            }
        }
    }

    @Test("A host alone never allows an endpoint's secret, and other keys keep their host rules")
    func hostOnlyChecks() throws {
        ProviderKeys.setHTTPEndpoints(["ha": "http://100.64.0.2:8123/api"])
        defer { ProviderKeys.setHTTPEndpoints([:]) }
        var used = Set<String>()
        #expect(throws: (any Error).self) {
            try ProviderKeys.substitute("pi-host-key:http-ha", host: "100.64.0.2", keys: EndpointKeys(), used: &used)
        }
        #expect(try header("https://api.deepseek.com/v1/x", "deepseek") == "Bearer sk-test")
        #expect(!allowed("http://100.64.0.2:8123/api/x", "deepseek"))
        #expect(ProviderKeys.hosts(for: "http-ha").isEmpty)
    }

    @Test("A base URL with a query, a fragment, a user or another scheme is not an endpoint")
    func badBases() {
        #expect(EndpointBase(URL(string: "http://h/api?x=1")!) == nil)
        #expect(EndpointBase(URL(string: "http://h/api#x")!) == nil)
        #expect(EndpointBase(URL(string: "http://u@h/api")!) == nil)
        #expect(EndpointBase(URL(string: "ftp://h/api")!) == nil)
        #expect(EndpointBase(URL(string: "http://h/api/../x")!)?.segments == ["x"])
    }

    @Test("Redirects: a keyed request follows one only inside the base", .timeLimit(.minutes(1)))
    func redirectRule() {
        ProviderKeys.setHTTPEndpoints(["ha": "http://100.64.0.2:8123/api"])
        defer { ProviderKeys.setHTTPEndpoints([:]) }
        #expect(FetchBridge.mayFollow(["http-ha"], to: URL(string: "http://100.64.0.2:8123/api/states")))
        #expect(!FetchBridge.mayFollow(["http-ha"], to: URL(string: "http://100.64.0.2:8123/admin")))
        #expect(!FetchBridge.mayFollow(["http-ha"], to: URL(string: "http://100.64.0.2:8123/api/%2e%2e/admin")))
        #expect(!FetchBridge.mayFollow(["http-ha"], to: URL(string: "http://evil.example/api/states")))
        #expect(!FetchBridge.mayFollow(["http-ha"], to: nil))
    }

    @Test("The bridge: keyed redirects off the base and every manual redirect come back as 3xx", .timeLimit(.minutes(1)))
    func bridgeRedirects() async throws {
        let server = try await RedirectServer.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        ProviderKeys.setHTTPEndpoints(["local": "\(base)/api"])
        defer { ProviderKeys.setHTTPEndpoints([:]) }
        let collector = Collector()
        let bridge = FetchBridge(keys: EndpointKeys()) { id, event in collector.add(id, event) }

        func send(_ id: Int, _ path: String, keyed: Bool, follow: Bool = true) async -> (status: Int, body: String, url: String) {
            bridge.start(.init(
                id: id, url: base + path, method: "GET",
                headers: keyed ? [("Authorization", "Bearer pi-host-key:http-local")] : [], body: nil, followRedirects: follow
            ))
            return await collector.result(id)
        }

        let inside = await send(1, "/api/hop", keyed: true)
        #expect(inside.status == 200, "a redirect inside the base is followed")
        // URLSession drops Authorization when it follows a redirect; what matters is that it went no further than the base.
        #expect(inside.body.hasPrefix("states:"), "\(inside.body)")
        #expect(inside.url == base + "/api/hop", "JS never learns the keyed request's final URL")

        let away = await send(2, "/api/away", keyed: true)
        #expect(away.status == 302, "a redirect off the base is handed back")
        #expect(away.body == "")
        #expect(!server.paths.withLock { $0 }.contains("/admin"), "and not followed")

        let manual = await send(3, "/api/hop", keyed: false, follow: false)
        #expect(manual.status == 302, "redirect: manual follows none, even without a key")

        let plain = await send(4, "/api/away", keyed: false)
        #expect(plain.status == 200, "an unkeyed request that may follow does")
        #expect(plain.body == "admin:")

        let outside = await send(5, "/admin", keyed: true)
        #expect(outside.status == -1, "a keyed request to a URL outside the base is refused before it is sent")
        #expect(outside.body.contains("may not be sent"))
        #expect(server.paths.withLock { $0 }.filter { $0 == "/admin" }.count == 1, "only the unkeyed request reached /admin")
    }
}

/// Collects bridge events per fetch ID until `end` or `error`.
private final class Collector: Sendable {
    private struct Entry {
        var status = 0
        var url = ""
        var body = Data()
        var done = false
        var waiter: CheckedContinuation<(status: Int, body: String, url: String), Never>?
    }
    private let entries = Mutex<[Int: Entry]>([:])

    func add(_ id: Int, _ event: FetchBridge.Event) {
        let resume = entries.withLock { entries -> (CheckedContinuation<(status: Int, body: String, url: String), Never>, (Int, String, String))? in
            var entry = entries[id] ?? Entry()
            switch event {
            case let .response(status, _, _, url):
                entry.status = status
                entry.url = url
            case let .chunk(data): entry.body.append(data)
            case .end: entry.done = true
            case let .error(message):
                entry.status = -1
                entry.body = Data(message.utf8)
                entry.done = true
            }
            defer { entries[id] = entry }
            guard entry.done, let waiter = entry.waiter else { return nil }
            entry.waiter = nil
            return (waiter, (entry.status, String(decoding: entry.body, as: UTF8.self), entry.url))
        }
        if let (waiter, value) = resume { waiter.resume(returning: value) }
    }

    func result(_ id: Int) async -> (status: Int, body: String, url: String) {
        await withCheckedContinuation { continuation in
            let ready = entries.withLock { entries -> (Int, String, String)? in
                var entry = entries[id] ?? Entry()
                if entry.done { return (entry.status, String(decoding: entry.body, as: UTF8.self), entry.url) }
                entry.waiter = continuation
                entries[id] = entry
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// A one-line HTTP/1.1 server on 127.0.0.1: `/api/hop` redirects to `/api/states`, `/api/away` to `/admin`; the
/// others answer with their name and the Authorization header they got.
private final class RedirectServer: Sendable {
    let listener: NWListener
    let port: UInt16
    let paths: Paths

    final class Paths: Sendable {
        private let list = Mutex<[String]>([])
        func append(_ path: String) { list.withLock { $0.append(path) } }
        func withLock<T>(_ body: ([String]) -> T) -> T { list.withLock { body($0) } }
    }

    private init(listener: NWListener, port: UInt16, paths: Paths) {
        self.listener = listener
        self.port = port
        self.paths = paths
    }

    static func start() async throws -> RedirectServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "redirect-server")
        let paths = Paths()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.serve(connection, paths: paths)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case let .failed(error): result = .failure(error)
                default: return
                }
                if resumed.withLock({ done in defer { done = true }; return !done }) { continuation.resume(with: result) }
            }
            listener.start(queue: queue)
        }
        return RedirectServer(listener: listener, port: port, paths: paths)
    }

    private static func serve(_ connection: NWConnection, paths: Paths, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { serve(connection, paths: paths, buffer: buffer) }
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            paths.append(path)
            let auth = lines.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
            let response: String
            switch path {
            case "/api/hop": response = "HTTP/1.1 302 Found\r\nLocation: /api/states\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            case "/api/away": response = "HTTP/1.1 302 Found\r\nLocation: /admin\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            default:
                let body = "\(path.split(separator: "/").last ?? ""):\(auth)"
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}
