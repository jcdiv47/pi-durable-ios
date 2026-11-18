import Foundation

/// Typed Swift face of `globalThis.PiRuntime` in `js/src/runtime.ts`. A thin adapter: Pi Durable is
/// experimental, so its API stays on the JS side and this layer only moves JSON.
public final class PiHarness: Sendable {
    public struct OpenOptions: Encodable, Sendable {
        public var dbPath: String
        public var provider: String
        public var modelId: String
        public var keyedProviders: [String]
        public var customProvider: CustomProvider?
        /// Where `web_search` searches: `off`, `deepseek`, `brave` or `scripted` (offline).
        public var searchProvider: String?
        /// Approval policy per tool name: `auto`, `ask` or `deny`.
        public var policies: [String: String]?
        /// Settings › MCP servers as JSON text: an array of servers with their cached tool lists (`McpServerConfig[]`
        /// in `js/src/app/mcp.ts`). Text, because the tools' schemas are arbitrary JSON.
        public var mcpServers: String?
        /// Settings › SSH Hosts, without secrets (`SshHostConfig[]` in `js/src/app/ssh.ts`).
        public var sshHosts: [SSHHostInfo]?
        /// Settings › Instructions: the user's AGENTS.md text, a prompt section in every conversation.
        public var instructions: String?
        /// Settings › Skills: the imported skills (`SkillLibrary.list()`).
        public var skills: [SkillLibrary.Skill]?
        /// Apple Intelligence models that can run now (`AppleIntelligence.models()`).
        public var appleModels: [AppleIntelligence.Model]?
        /// Settings › Apple Intelligence › Titles.
        public var intelligenceTitles: Bool?
        /// pi.dev's newer model lists as JSON text, as the last `modelCatalogs` event gave them (`CatalogFile` in
        /// `js/src/app/catalog.ts`).
        public var modelCatalogs: String?
        public var toolMs: Int?

        public init(
            dbPath: String,
            provider: String,
            modelId: String,
            keyedProviders: [String] = [],
            customProvider: CustomProvider? = nil,
            searchProvider: String? = nil,
            policies: [String: String]? = nil,
            mcpServers: String? = nil,
            sshHosts: [SSHHostInfo]? = nil,
            instructions: String? = nil,
            skills: [SkillLibrary.Skill]? = nil,
            appleModels: [AppleIntelligence.Model]? = nil,
            intelligenceTitles: Bool? = nil,
            modelCatalogs: String? = nil,
            toolMs: Int? = nil
        ) {
            self.dbPath = dbPath
            self.provider = provider
            self.modelId = modelId
            self.keyedProviders = keyedProviders
            self.customProvider = customProvider
            self.searchProvider = searchProvider
            self.policies = policies
            self.mcpServers = mcpServers
            self.sshHosts = sshHosts
            self.instructions = instructions
            self.skills = skills
            self.appleModels = appleModels
            self.intelligenceTitles = intelligenceTitles
            self.modelCatalogs = modelCatalogs
            self.toolMs = toolMs
        }
    }

    /// An SSH host as JS sees it: what the model may know, never a secret or a host key.
    public struct SSHHostInfo: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// `user@host` or `user@host:port`.
        public var address: String
        /// `login`, `bash`, `zsh`, `fish` or `sh`.
        public var shell: String
        public var enabled: Bool
        /// Its host key is confirmed and its password or key saved.
        public var ready: Bool
        public var needsVpn: Bool
        public var runWithoutAsking: Bool

        public init(id: String, name: String, address: String, shell: String, enabled: Bool, ready: Bool, needsVpn: Bool, runWithoutAsking: Bool) {
            self.id = id
            self.name = name
            self.address = address
            self.shell = shell
            self.enabled = enabled
            self.ready = ready
            self.needsVpn = needsVpn
            self.runWithoutAsking = runWithoutAsking
        }
    }

    /// An OpenAI-compatible endpoint (provider id `custom`). Its key is the Keychain item `custom`, sent
    /// only to `baseUrl`'s host.
    public struct CustomProvider: Codable, Sendable, Equatable {
        public var name: String
        public var baseUrl: String
        public var modelIds: [String]

        public init(name: String, baseUrl: String, modelIds: [String]) {
            self.name = name
            self.baseUrl = baseUrl
            self.modelIds = modelIds
        }
    }

    public struct OpenResult: Decodable, Sendable {
        public let openMs: Double
        public let rootId: Int
    }

    public struct AskResult: Decodable, Sendable {
        public let status: String
        public let text: String?
        public let totalMs: Double
        /// First streamed delta of any kind (thinking or text).
        public let firstDeltaMs: Double?
        public let firstTextMs: Double?
        public let streamMs: Double?
        public let deltas: Int?
        public let thinkingDeltas: Int?
        /// Usage output tokens; for reasoning models this includes thinking.
        public let outputTokens: Int?
        public let msPerToken: Double?
        public let stopReason: String?
        public let errorMessage: String?
        /// The settled submission, when it did not finish with an answer.
        public let detail: String?
    }

    public struct SettleResult: Decodable, Sendable {
        public struct ToolResult: Decodable, Sendable {
            public let tool: String
            public let isError: Bool
            public let text: String
        }

        public let status: String
        public let entryKinds: [String]
        public let toolResults: [ToolResult]
        public let answer: String?
    }

    public let runtime: JSRuntime
    /// Milliseconds spent evaluating the bundle.
    public let evaluateMs: Double

    private init(runtime: JSRuntime, evaluateMs: Double) {
        self.runtime = runtime
        self.evaluateMs = evaluateMs
    }

    /// Creates a runtime and evaluates the bundle (`pi-runtime.js`) in it.
    public static func load(bundle url: URL, options: JSRuntime.Options = .init()) async throws -> PiHarness {
        let source = try String(contentsOf: url, encoding: .utf8)
        var options = options
        options.resourceDirectory = options.resourceDirectory ?? url.deletingLastPathComponent()
        let runtime = JSRuntime(options: options)
        let start = ContinuousClock.now
        try await runtime.evaluate(source, sourceURL: url)
        return PiHarness(runtime: runtime, evaluateMs: (ContinuousClock.now - start).milliseconds)
    }

    public func open(_ options: OpenOptions) async throws -> OpenResult {
        try await call("PiRuntime.open", [try jsonObject(options)])
    }

    public func ask(_ text: String, requestId: String) async throws -> AskResult {
        try await call("PiRuntime.ask", [text, requestId])
    }

    /// Admits an input without waiting for its answer.
    public func submit(_ text: String, requestId: String) async throws {
        _ = try await runtime.callAsync("PiRuntime.submit", [text, requestId])
    }

    /// Waits for the run that `requestId` started (possibly in an earlier process) and summarizes it.
    public func settle(_ text: String, requestId: String) async throws -> SettleResult {
        try await call("PiRuntime.settle", [text, requestId])
    }

    public func close() async throws {
        _ = try await runtime.callAsync("PiRuntime.close")
    }

    /// Calls `globalThis.<path>(...arguments)` and decodes the JSON it resolves to.
    public func call<T: Decodable>(_ path: String, _ arguments: [any Sendable] = []) async throws -> T {
        let json = try await runtime.callAsync(path, arguments)
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Calls `globalThis.<path>(...arguments)` and ignores what it resolves to.
    public func perform(_ path: String, _ arguments: [any Sendable] = []) async throws {
        _ = try await runtime.callAsync(path, arguments)
    }

    /// An Encodable struct as a JS object argument.
    public func jsonArgument(_ value: some Encodable) throws -> [String: any Sendable] {
        try jsonObject(value)
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: any Sendable] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: any Sendable]
    }
}

extension Duration {
    public var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
