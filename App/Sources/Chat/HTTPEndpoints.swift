import Foundation
import PiRuntime
import PiUI

/// An HTTP API the user added in Settings › HTTP Endpoints: Home Assistant's REST API, an ntfy or n8n webhook, a
/// service on the tailnet. Pi calls it with `http_get` and `http_send` (`js/src/app/http.ts`), naming it by ID and
/// giving a path under `baseUrl`. The secret is the item `http-<id>` in `HTTPSecrets`; the fetch bridge sends it only
/// to URLs inside `baseUrl` (`ProviderKeys.setHTTPEndpoints`).
struct HTTPEndpoint: Codable, Identifiable, Hashable {
    enum Auth: String, Codable, CaseIterable, Identifiable {
        case none, bearer, header, query
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .bearer: "Bearer token"
            case .header: "Custom header"
            case .query: "Query parameter"
            }
        }
        var usesSecret: Bool { self != .none }
    }

    /// Lowercase letters and digits, unique.
    var id: String
    var name: String
    /// `scheme://host[:port][/path]`, without a query or fragment.
    var baseUrl: String
    /// What the API is and how to use it, written by the user for the model.
    var about: String
    var enabled = true
    var needsVpn: Bool
    /// `http_get` runs without asking while the conversation holds no outside text. Off by default.
    var readWithoutAsking = false
    var auth: Auth
    /// The header (`header`) or query parameter (`query`) the secret goes in.
    var authName: String?

    var keyName: String { HTTPEndpoint.keyPrefix + id }
    var host: String? { URL(string: baseUrl)?.host()?.lowercased() }

    static let keyPrefix = ProviderKeys.httpPrefix

    /// An ID from the name: `Home Assistant` → `homeassistant`, unique among `taken`.
    static func id(for name: String, taken: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let base = String(name.lowercased().filter { allowed.contains($0) }.prefix(16))
        let stem = base.isEmpty ? "api" : base
        var id = stem
        var n = 2
        while taken.contains(id) {
            id = "\(stem)\(n)"
            n += 1
        }
        return id
    }

    /// A base URL as typed, if it can be one: http or https, a host, no user, query or fragment.
    static func parseBase(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ProviderKeys.isEndpointBase(url) else { return nil }
        return url
    }

    /// Headers the secret may not go in: the request's own framing, which URLSession or JS set.
    private static let reservedHeaders: Set<String> = ["host", "content-length", "content-type", "transfer-encoding", "connection", "accept", "cookie"]

    /// Whether `name` can carry the secret for `auth`: an HTTP token for a header, a plain name for a query parameter.
    static func validAuthName(_ name: String, for auth: Auth) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        switch auth {
        case .none, .bearer: return true
        case .header:
            let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            return !name.isEmpty && name.unicodeScalars.allSatisfy(token.contains) && !reservedHeaders.contains(name.lowercased())
        case .query:
            let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
            return !name.isEmpty && name.unicodeScalars.allSatisfy { plain.contains($0) && $0.isASCII }
        }
    }

    /// What JS gets: no secret.
    func info(hasSecret: Bool) -> PiHarness.HTTPEndpointInfo {
        .init(
            id: id, name: name, baseUrl: baseUrl, description: about, enabled: enabled, ready: !auth.usesSecret || hasSecret,
            needsVpn: needsVpn, readWithoutAsking: readWithoutAsking, auth: auth.rawValue,
            authName: auth == .header || auth == .query ? authName : nil
        )
    }

    /// A call as the approval sheet shows it: the method and the full URL (the endpoint's query auth left out, as JS
    /// adds it), and the body of a write, cut to 2,000 characters.
    struct Call {
        let method: String
        let url: String
        let body: String?
    }

    func call(_ arguments: JSONValue, tool: String) -> Call {
        let method = arguments["method"]?.string?.uppercased() ?? (tool == "http_get" ? "GET" : "POST")
        let path = (arguments["path"]?.string ?? "").split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        let trimmedBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        var url = path.isEmpty ? baseUrl : "\(trimmedBase)/\(path)"
        if case let .object(query)? = arguments["query"], !query.isEmpty, var components = URLComponents(string: url) {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value.string ?? $0.value.jsonText) }
            url = components.string ?? url
        }
        var body: String?
        if let json = arguments["json"] {
            body = json.jsonText
        } else if let text = arguments["body"]?.string {
            body = text
        }
        if let text = body, text.count > 2000 { body = String(text.prefix(2000)) + "…" }
        return Call(method: method, url: url, body: body)
    }
}

/// The endpoint list, in a JSON file in Application Support. Secrets are in the Keychain (`HTTPSecrets`), never here.
enum HTTPEndpointFile {
    static var url: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("http-endpoints.json")
    }

    static func load() -> [HTTPEndpoint] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HTTPEndpoint].self, from: data)) ?? []
    }

    static func save(_ endpoints: [HTTPEndpoint]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(endpoints).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Endpoints' tokens and secrets: a Keychain service of their own, one item per endpoint (`http-<id>`). The fetch
/// bridge reads them through `AppKeys`, and only for URLs inside the endpoint's base URL.
enum HTTPSecrets {
    static let keychain = KeychainKeys(service: "dev.jcdiv47.pidurable.http")

    static func has(_ endpoint: HTTPEndpoint) -> Bool { keychain.hasKey(for: endpoint.keyName) }
    static func set(_ secret: String, for endpoint: HTTPEndpoint) throws { try keychain.setKey(secret, for: endpoint.keyName) }
    static func remove(_ endpoint: HTTPEndpoint) { try? keychain.removeKey(for: endpoint.keyName) }
}

/// The keys the fetch bridge substitutes: endpoints' secrets from `HTTPSecrets`, everything else from the provider keys.
struct AppKeys: ProviderKeySource {
    let providers: KeychainKeys

    func apiKey(for provider: String) -> String? {
        provider.hasPrefix(HTTPEndpoint.keyPrefix) ? HTTPSecrets.keychain.apiKey(for: provider) : providers.apiKey(for: provider)
    }
}
