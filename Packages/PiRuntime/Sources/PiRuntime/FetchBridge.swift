import Foundation
import os

/// Supplies provider API keys to outgoing requests. Keys stay on the Swift side: JS sends a placeholder
/// header value (`ProviderKeys.placeholder(for:)`) and the bridge substitutes the real key, but only
/// for requests to that provider's hosts.
public protocol ProviderKeySource: Sendable {
    func apiKey(for provider: String) -> String?
}

public enum ProviderKeys {
    static let prefix = "pi-host-key:"

    /// The value JS uses in place of a provider's key.
    public static func placeholder(for provider: String) -> String { prefix + provider }

    /// Hosts each provider's key may be sent to.
    public static let allowedHosts: [String: Set<String>] = [
        "anthropic": ["api.anthropic.com"],
        "openai": ["api.openai.com"],
        "openrouter": ["openrouter.ai"],
    ]

    /// Replaces placeholders in header values. Throws when a placeholder targets a host it is not allowed for.
    static func substitute(_ value: String, host: String?, keys: ProviderKeySource?) throws -> String {
        guard let range = value.range(of: prefix) else { return value }
        let provider = String(value[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        guard let host, allowedHosts[provider]?.contains(host) == true else {
            throw FetchBridgeError.keyNotAllowed(provider: provider, host: host ?? "?")
        }
        guard let key = keys?.apiKey(for: provider), !key.isEmpty else {
            throw FetchBridgeError.missingKey(provider: provider)
        }
        return value.replacingOccurrences(of: prefix + provider, with: key)
    }
}

enum FetchBridgeError: Error, CustomStringConvertible {
    case keyNotAllowed(provider: String, host: String)
    case missingKey(provider: String)
    case badURL(String)

    var description: String {
        switch self {
        case let .keyNotAllowed(provider, host): "API key for \(provider) may not be sent to \(host)"
        case let .missingKey(provider): "No API key configured for \(provider)"
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
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var tasks: [Int: URLSessionDataTask] = [:]
        var ids: [Int: Int] = [:] // taskIdentifier -> fetch id
    }

    private let deliver: @Sendable (Int, Event) -> Void
    private let keys: ProviderKeySource?
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

    init(keys: ProviderKeySource?, deliver: @escaping @Sendable (Int, Event) -> Void) {
        self.keys = keys
        self.deliver = deliver
    }

    func start(_ request: Request) {
        guard let url = URL(string: request.url) else {
            deliver(request.id, .error(FetchBridgeError.badURL(request.url).description))
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        do {
            for (name, value) in request.headers {
                urlRequest.addValue(try ProviderKeys.substitute(value, host: url.host, keys: keys), forHTTPHeaderField: name)
            }
        } catch {
            deliver(request.id, .error(String(describing: error)))
            return
        }
        let task = session.dataTask(with: urlRequest)
        lock.withLock {
            $0.tasks[request.id] = task
            $0.ids[task.taskIdentifier] = request.id
        }
        task.resume()
    }

    func cancel(_ id: Int) {
        let task = lock.withLock { state -> URLSessionDataTask? in
            guard let task = state.tasks.removeValue(forKey: id) else { return nil }
            state.ids.removeValue(forKey: task.taskIdentifier)
            return task
        }
        task?.cancel()
    }

    private func fetchID(_ task: URLSessionTask) -> Int? {
        lock.withLock { $0.ids[task.taskIdentifier] }
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
        deliver(id, .response(
            status: status,
            statusText: HTTPURLResponse.localizedString(forStatusCode: status),
            headers: headers,
            url: response.url?.absoluteString ?? ""
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
