import Foundation
import os

/// Supplies API keys to outgoing requests. Keys stay on the Swift side: JS sends a placeholder
/// (`ProviderKeys.placeholder(for:)`) in a header value or a URL query value, and the bridge substitutes the real
/// key, but only for requests to that service's hosts.
public protocol ProviderKeySource: Sendable {
    func apiKey(for provider: String) -> String?
}

/// The keyed services: model providers and the HTTP APIs behind tools.
public enum ProviderKeys {
    static let prefix = "pi-host-key:"

    /// The value JS uses in place of a service's key.
    public static func placeholder(for provider: String) -> String { prefix + provider }

    /// Hosts each service's key may be sent to.
    public static let allowedHosts: [String: Set<String>] = [
        "anthropic": ["api.anthropic.com"],
        "brave": ["api.search.brave.com"],
        "deepseek": ["api.deepseek.com"],
        "openai": ["api.openai.com"],
        "openrouter": ["openrouter.ai"],
    ]

    /// Requests a service's key may be used for per calendar month (`ServiceUsage`). Brave: the free plan.
    public static let monthlyCaps: [String: Int] = [
        "brave": 2000,
    ]

    private static let customHost = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let mcpHosts = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private static let httpBases = OSAllocatedUnfairLock<[String: EndpointBase]>(initialState: [:])

    /// The key prefix of MCP servers' tokens: server `ha`'s is the Keychain item and placeholder `mcp-ha`.
    public static let mcpPrefix = "mcp-"

    /// The key prefix of HTTP endpoints' secrets: endpoint `ha`'s is the key and placeholder `http-ha`.
    public static let httpPrefix = "http-"

    /// The host of the user's OpenAI-compatible endpoint, the only host the `custom` key may be sent to.
    public static func setCustomHost(_ host: String?) {
        customHost.withLock { $0 = host?.lowercased() }
    }

    /// The host of each MCP server the user added in Settings, by server ID. A
    /// server's token (`mcp-<id>`) may be sent only to its own host. Set from Swift only; JS cannot add a host.
    public static func setMCPHosts(_ hosts: [String: String]) {
        mcpHosts.withLock { $0 = hosts.mapValues { $0.lowercased() } }
    }

    /// The base URL of each HTTP endpoint the user added in Settings, by endpoint ID. An endpoint's secret
    /// (`http-<id>`) may be sent only to URLs inside its base: the same scheme, host and port, and a path under the base
    /// path on whole segments. Set from Swift only; JS cannot add an endpoint. Base URLs that don't parse are dropped.
    public static func setHTTPEndpoints(_ bases: [String: String]) {
        let parsed = bases.compactMapValues { URL(string: $0).flatMap(EndpointBase.init) }
        httpBases.withLock { $0 = parsed }
    }

    /// Whether `url` can be an HTTP endpoint's base: `http` or `https`, a host, and no user, query or fragment.
    public static func isEndpointBase(_ url: URL) -> Bool { EndpointBase(url) != nil }

    static func hosts(for provider: String) -> Set<String> {
        if provider == "custom" { return customHost.withLock { $0.map { [$0] } ?? [] } }
        if provider.hasPrefix(mcpPrefix) {
            let id = String(provider.dropFirst(mcpPrefix.count))
            return mcpHosts.withLock { $0[id].map { [$0] } ?? [] }
        }
        // An endpoint's secret is pinned to more than a host: see `allows(_:url:)`.
        if provider.hasPrefix(httpPrefix) { return [] }
        return allowedHosts[provider] ?? []
    }

    /// Whether `provider`'s key may be sent with a request to `url`. Model providers, services and MCP servers: by host.
    /// HTTP endpoints: inside the endpoint's base URL (`EndpointBase.contains`).
    static func allows(_ provider: String, url: URL) -> Bool {
        if provider.hasPrefix(httpPrefix) {
            let id = String(provider.dropFirst(httpPrefix.count))
            guard let base = httpBases.withLock({ $0[id] }) else { return false }
            return base.contains(url)
        }
        guard let host = url.host?.lowercased() else { return false }
        return hosts(for: provider).contains(host)
    }

    /// Replaces placeholders in a header value of a request to `url`; see `substitute(_:host:keys:used:)`.
    static func substitute(_ value: String, url: URL, keys: ProviderKeySource?, used: inout Set<String>) throws -> String {
        try substitute(value, target: url.host ?? "?", allowed: { allows($0, url: url) }, keys: keys, used: &used)
    }

    /// Replaces placeholders in a header value and adds the services whose keys it used to `used`. Throws when a
    /// placeholder targets a host it is not allowed for. A host alone never allows an HTTP endpoint's secret.
    static func substitute(_ value: String, host: String?, keys: ProviderKeySource?, used: inout Set<String>) throws -> String {
        try substitute(value, target: host ?? "?", allowed: { provider in
            guard let host, !provider.hasPrefix(httpPrefix) else { return false }
            return hosts(for: provider).contains(host.lowercased())
        }, keys: keys, used: &used)
    }

    private static func substitute(
        _ value: String, target: String, allowed: (String) -> Bool, keys: ProviderKeySource?, used: inout Set<String>
    ) throws -> String {
        var result = value
        while let range = result.range(of: prefix) {
            let provider = String(result[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            guard allowed(provider) else {
                throw FetchBridgeError.keyNotAllowed(provider: provider, host: target)
            }
            guard let key = keys?.apiKey(for: provider), !key.isEmpty else {
                throw FetchBridgeError.missingKey(provider: provider)
            }
            result.replaceSubrange(range.lowerBound..<result.index(range.upperBound, offsetBy: provider.count), with: key)
            used.insert(provider)
        }
        return result
    }

    /// Replaces placeholders in a URL's query (`key=pi-host-key:amap`, also percent-encoded as `%3A`).
    static func substitute(url: URL, keys: ProviderKeySource?, used: inout Set<String>) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery else { return url }
        let decoded = query.replacingOccurrences(of: "pi-host-key%3A", with: prefix, options: .caseInsensitive)
        guard decoded.contains(prefix) else { return url }
        var keysUsed = Set<String>()
        let substituted = try substitute(decoded, url: url, keys: EncodedKeys(keys: keys), used: &keysUsed)
        components.percentEncodedQuery = substituted
        guard let result = components.url else { throw FetchBridgeError.badURL(url.absoluteString) }
        used.formUnion(keysUsed)
        return result
    }

    /// Keys percent-encoded for a query value.
    private struct EncodedKeys: ProviderKeySource {
        let keys: ProviderKeySource?
        func apiKey(for provider: String) -> String? {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#")
            return keys?.apiKey(for: provider)?.addingPercentEncoding(withAllowedCharacters: allowed)
        }
    }
}

/// An HTTP endpoint's base URL as the key check compares it: scheme, host, port and path segments.
struct EndpointBase: Equatable {
    let scheme: String
    let host: String
    let port: Int
    let segments: [String]

    /// Nil for a URL that is not plain `http` or `https` with a host, or that has a user, query or fragment.
    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let segments = Self.segments(components.percentEncodedPath)
        else { return nil }
        self.scheme = scheme
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = components.port ?? (scheme == "https" ? 443 : 80)
        self.segments = segments
    }

    /// Whether `url` is inside the base: the same scheme, host and port, no user, and the base's path segments first.
    func contains(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host,
              (components.port ?? (scheme == "https" ? 443 : 80)) == port,
              components.user == nil, components.password == nil,
              let path = Self.segments(components.percentEncodedPath)
        else { return false }
        return path.count >= segments.count && Array(path.prefix(segments.count)) == segments
    }

    /// A percent-encoded path as decoded segments, with dot segments resolved (`.`, `..` and their encodings, such as
    /// `%2e%2e`) and empty segments dropped. Nil when a segment doesn't decode, decodes to a slash or a backslash (a
    /// server may read `%2F` as a separator), or `..` climbs above the root.
    static func segments(_ percentEncodedPath: String) -> [String]? {
        var result: [String] = []
        for raw in percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let segment = String(raw).removingPercentEncoding, !segment.contains("/"), !segment.contains("\\") else { return nil }
            switch segment {
            case "", ".": continue
            case "..":
                guard !result.isEmpty else { return nil }
                result.removeLast()
            default: result.append(segment)
            }
        }
        return result
    }
}

/// Requests sent with each service's key, per calendar month, kept in UserDefaults. A service with a monthly cap
/// (`ProviderKeys.monthlyCaps`) is refused once it reaches it, so a runaway schedule cannot spend a month's quota.
public final class ServiceUsage: @unchecked Sendable {
    public static let shared = ServiceUsage(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let caps: [String: Int]

    public init(defaults: UserDefaults, caps: [String: Int] = ProviderKeys.monthlyCaps) {
        self.defaults = defaults
        self.caps = caps
    }

    /// Requests sent with `service`'s key this month.
    public func count(for service: String, at date: Date = .now) -> Int {
        lock.withLock { defaults.integer(forKey: Self.key(service, date)) }
    }

    public func cap(for service: String) -> Int? { caps[service] }

    /// Counts one request, or throws when the service's cap for this month is used up.
    func record(_ service: String, at date: Date = .now) throws {
        try lock.withLock {
            let key = Self.key(service, date)
            let count = defaults.integer(forKey: key)
            if let cap = caps[service], count >= cap { throw FetchBridgeError.quotaUsedUp(provider: service, cap: cap) }
            defaults.set(count + 1, forKey: key)
        }
    }

    /// Takes the service's own count of requests left this month (`X-RateLimit-Remaining`) as the truth.
    func correct(_ service: String, remaining: Int, at date: Date = .now) {
        guard let cap = caps[service], remaining >= 0, remaining <= cap else { return }
        lock.withLock { defaults.set(cap - remaining, forKey: Self.key(service, date)) }
    }

    private static func key(_ service: String, _ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "serviceUsage.%@.%04d-%02d", service, parts.year ?? 0, parts.month ?? 0)
    }
}

enum FetchBridgeError: Error, CustomStringConvertible {
    case keyNotAllowed(provider: String, host: String)
    case missingKey(provider: String)
    case quotaUsedUp(provider: String, cap: Int)
    case badURL(String)

    var description: String {
        switch self {
        case let .keyNotAllowed(provider, host): "API key for \(provider) may not be sent to \(host)"
        case let .missingKey(provider): "No API key configured for \(provider)"
        case let .quotaUsedUp(provider, cap): "Monthly quota used up: \(provider) allows \(cap) requests a month"
        case let .badURL(url): "Invalid URL: \(url)"
        }
    }
}

/// Streams URLSession responses into JS. Events are delivered through `deliver`, which the runtime
/// hops onto the JS queue.
final class FetchBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event {
        case response(status: Int, statusText: String, headers: [[String]], url: String)
        case chunk(Data)
        case end
        case error(String)
    }

    struct Request {
        let id: Int
        let url: String
        let method: String
        let headers: [(String, String)]
        let body: Data?
        /// False for `fetch`'s `redirect: "manual"` and `"error"`: JS gets the redirect response itself.
        var followRedirects = true
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var tasks: [Int: URLSessionDataTask] = [:]
        var ids: [Int: Int] = [:] // taskIdentifier -> fetch id
        /// Requests that carry a key, by fetch id: never tell JS a URL with the key in it.
        var keyed: [Int: Keyed] = [:]
        /// Requests that follow no redirect, by fetch id.
        var manual: Set<Int> = []
        /// Requests a `LocalHTTPService` is answering, by fetch id.
        var local: [Int: Task<Void, Never>] = [:]
    }

    private struct Keyed {
        /// The URL as JS sent it, with placeholders.
        let url: String
        let services: Set<String>
    }

    private let deliver: @Sendable (Int, Event) -> Void
    private let keys: ProviderKeySource?
    private let usage: ServiceUsage?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Pi applies its own stream idle timeout; this only bounds a silent connection.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "pi.fetch"
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    private let localHosts: [String: any LocalHTTPService]

    init(
        keys: ProviderKeySource?,
        usage: ServiceUsage? = nil,
        localHosts: [String: any LocalHTTPService] = [:],
        deliver: @escaping @Sendable (Int, Event) -> Void
    ) {
        self.keys = keys
        self.usage = usage
        self.localHosts = localHosts
        self.deliver = deliver
    }

    func start(_ request: Request) {
        guard let url = URL(string: request.url) else {
            deliver(request.id, .error(FetchBridgeError.badURL(request.url).description))
            return
        }
        if let host = url.host?.lowercased(), let service = localHosts[host] {
            startLocal(request, url: url, service: service)
            return
        }
        var urlRequest: URLRequest
        var used = Set<String>()
        do {
            urlRequest = URLRequest(url: try ProviderKeys.substitute(url: url, keys: keys, used: &used))
            for (name, value) in request.headers {
                urlRequest.addValue(try ProviderKeys.substitute(value, url: url, keys: keys, used: &used), forHTTPHeaderField: name)
            }
            for service in used.sorted() { try usage?.record(service) }
        } catch {
            deliver(request.id, .error(String(describing: error)))
            return
        }
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        let task = session.dataTask(with: urlRequest)
        let keyed = used.isEmpty ? nil : Keyed(url: request.url, services: used)
        lock.withLock {
            $0.tasks[request.id] = task
            $0.ids[task.taskIdentifier] = request.id
            $0.keyed[request.id] = keyed
            if !request.followRedirects { $0.manual.insert(request.id) }
        }
        task.resume()
    }

    /// Hands the request to an in-process service. Keys are never substituted: a local host is no provider's.
    private func startLocal(_ request: Request, url: URL, service: any LocalHTTPService) {
        let id = request.id
        let deliver = deliver
        let local = LocalHTTPRequest(url: url, method: request.method, headers: request.headers, body: request.body)
        // Holds the lock across `Task` creation so a fast `.end` can't remove the entry before it is stored.
        lock.withLock { state in
            state.local[id] = Task { [weak self] in
                let done = OSAllocatedUnfairLock(initialState: false)
                await service.respond(to: local) { event in
                    // Claims the right to deliver; `end` and `error` close it for later events.
                    let closed = done.withLock { finished -> Bool in
                        if finished || Task.isCancelled { return true }
                        if case .end = event { finished = true }
                        if case .error = event { finished = true }
                        return false
                    }
                    if closed { return }
                    switch event {
                    case let .response(status, headers):
                        deliver(id, .response(
                            status: status,
                            statusText: HTTPURLResponse.localizedString(forStatusCode: status),
                            headers: headers.map { [$0.key.lowercased(), $0.value] },
                            url: url.absoluteString
                        ))
                    case let .chunk(data):
                        deliver(id, .chunk(data))
                    case .end:
                        deliver(id, .end)
                    case let .error(message):
                        deliver(id, .error(message))
                    }
                }
                let unfinished = done.withLock { finished in
                    defer { finished = true }
                    return !finished
                }
                if unfinished, !Task.isCancelled { deliver(id, .end) }
                self?.lock.withLock { _ = $0.local.removeValue(forKey: id) }
            }
        }
    }

    func cancel(_ id: Int) {
        if let local = lock.withLock({ $0.local.removeValue(forKey: id) }) {
            local.cancel()
            return
        }
        let task = lock.withLock { state -> URLSessionDataTask? in
            guard let task = state.tasks.removeValue(forKey: id) else { return nil }
            state.ids.removeValue(forKey: task.taskIdentifier)
            state.keyed.removeValue(forKey: id)
            state.manual.remove(id)
            return task
        }
        task?.cancel()
    }

    func cancelAll() {
        let (tasks, local) = lock.withLock { state -> ([URLSessionDataTask], [Task<Void, Never>]) in
            defer { state = State() }
            return (Array(state.tasks.values), Array(state.local.values))
        }
        for task in tasks { task.cancel() }
        for task in local { task.cancel() }
    }

    private func fetchID(_ task: URLSessionTask) -> Int? {
        lock.withLock { $0.ids[task.taskIdentifier] }
    }

    private func keyed(_ id: Int) -> Keyed? {
        lock.withLock { $0.keyed[id] }
    }

    /// A request that carries a key follows redirects only to where its services' keys may go (for an HTTP endpoint:
    /// inside its base URL); elsewhere JS gets the redirect response itself. URLSession would copy the key's headers to
    /// the new request. A request sent with `redirect: "manual"` follows none.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let id = fetchID(task) else { return completionHandler(nil) }
        if lock.withLock({ $0.manual.contains(id) }) { return completionHandler(nil) }
        guard let keyed = keyed(id) else { return completionHandler(request) }
        completionHandler(Self.mayFollow(keyed.services, to: request.url) ? request : nil)
    }

    /// Whether a keyed request may follow a redirect to `url`: every key it carries may go there.
    static func mayFollow(_ services: Set<String>, to url: URL?) -> Bool {
        guard let url else { return false }
        return services.allSatisfy { ProviderKeys.allows($0, url: url) }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let id = fetchID(dataTask) else { return completionHandler(.cancel) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        var headers: [[String]] = []
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers.append(["\(key)".lowercased(), "\(value)"])
        }
        let keyed = keyed(id)
        if let keyed, let usage, let remaining = http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") {
            // Brave sends the per-second and the per-month window: "0, 1999".
            if let month = remaining.split(separator: ",").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                for service in keyed.services { usage.correct(service, remaining: month) }
            }
        }
        deliver(id, .response(
            status: status,
            statusText: HTTPURLResponse.localizedString(forStatusCode: status),
            headers: headers,
            url: keyed?.url ?? response.url?.absoluteString ?? ""
        ))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = fetchID(dataTask) else { return }
        deliver(id, .chunk(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = lock.withLock { state -> Int? in
            guard let id = state.ids.removeValue(forKey: task.taskIdentifier) else { return nil }
            state.tasks.removeValue(forKey: id)
            state.keyed.removeValue(forKey: id)
            state.manual.remove(id)
            return id
        }
        guard let id else { return }
        if let error {
            deliver(id, .error(error.localizedDescription))
        } else {
            deliver(id, .end)
        }
    }
}

/// A request to a host served in the process (`JSRuntime.Options.localHosts`).
public struct LocalHTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [(String, String)]
    public let body: Data?

    public init(url: URL, method: String, headers: [(String, String)] = [], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// What a local service sends back: one `response`, then chunks, then `end` (or `error` at any point).
public enum LocalHTTPEvent: Sendable {
    case response(status: Int, headers: [String: String])
    case chunk(Data)
    case end
    case error(String)
}

/// Answers `fetch` for a local host. `send` may be called from any thread; after `end` or `error`, or once JS
/// aborted the request (the task is cancelled), further events are dropped.
public protocol LocalHTTPService: Sendable {
    func respond(to request: LocalHTTPRequest, send: @escaping @Sendable (LocalHTTPEvent) -> Void) async
}
