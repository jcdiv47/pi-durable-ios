import Foundation
import Observation
import os
import PiAppleTools
import PiRuntime
import PiUI
import UIKit

/// The chat app's state and the only owner of the Harness in chat mode. JS events arrive on the main
/// actor as JSON; calls into JS go through `PiHarness.call`.
@MainActor
@Observable
final class ChatStore {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    /// Providers with Keychain keys, in Settings order. `custom` is the user's OpenAI-compatible endpoint.
    static let providers: [(id: String, name: String)] = [
        ("anthropic", "Anthropic"), ("openai", "OpenAI"), ("openrouter", "OpenRouter"), ("deepseek", "DeepSeek"), ("custom", "Custom endpoint"),
    ]
    static let offlineModel = ModelRef(provider: "scripted", modelId: "assistant")

    private(set) var phase = Phase.starting
    private(set) var conversations: [ConversationMeta] = []
    private(set) var states: [Int: ConversationState] = [:]
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var models: [ModelInfo] = []
    private(set) var tools: [ToolInfo] = []
    private(set) var tasks: [TaskInfo] = []
    private(set) var keyedProviders: Set<String> = []
    let diagnostics = DiagnosticsLog()

    var defaultModel: ModelRef {
        didSet { settings.set(defaultModel.key, forKey: "defaultModel") }
    }

    var custom: PiHarness.CustomProvider? {
        didSet {
            settings.set(try? JSONEncoder().encode(custom), forKey: "customProvider")
            ProviderKeys.setCustomHost(custom.flatMap { URL(string: $0.baseUrl)?.host() })
        }
    }

    private var harness: PiHarness?
    private let keys = KeychainKeys()
    private let appleTools = AppleToolHost()
    private let settings = UserDefaults.standard
    private var watched: Set<Int> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    nonisolated static let logger = Logger(subsystem: "dev.pi.durable", category: "chat")

    init() {
        let stored = settings.string(forKey: "defaultModel")?.split(separator: "/", maxSplits: 1).map(String.init)
        defaultModel = stored?.count == 2 ? ModelRef(provider: stored![0], modelId: stored![1]) : Self.offlineModel
        custom = settings.data(forKey: "customProvider").flatMap { try? JSONDecoder().decode(PiHarness.CustomProvider.self, from: $0) }
        ProviderKeys.setCustomHost(custom.flatMap { URL(string: $0.baseUrl)?.host() })
    }

    var busyConversations: [Int] { states.values.filter(\.live.busy).map(\.id) }

    func state(_ id: Int) -> ConversationState {
        if let state = states[id] { return state }
        let state = ConversationState(id: id)
        states[id] = state
        return state
    }

    // MARK: Start

    func start() async {
        importKeysIfPresent()
        keyedProviders = Set(Self.providers.map(\.id).filter { keys.hasKey(for: $0) })
        do {
            let directory = try SharedContainer.directory("pi")
            let tools = appleTools
            let harness = try await PiHarness.load(bundle: AppModel.bundleURL, options: .init(
                keys: keys,
                onEvent: { [weak self] json in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(json) } }
                },
                onLog: AppModel.forwardLog,
                hostCall: { name, json in try await tools.handle(name, json) }
            ))
            _ = try await harness.open(.init(
                dbPath: directory.appendingPathComponent("session.sqlite").path,
                provider: defaultModel.provider,
                modelId: defaultModel.modelId,
                keyedProviders: Array(keyedProviders),
                customProvider: custom,
                policies: settings.dictionary(forKey: "toolPolicies") as? [String: String]
            ))
            self.harness = harness
            conversations = try await harness.call("PiRuntime.conversations")
            await refreshModels()
            await refreshTools()
            await refreshTasks()
            approvals = try await harness.call("PiRuntime.approvals")
            phase = .ready
            diagnostics.record("info", "app", "Opened Pi storage; \(conversations.count) conversations")
            // Conversations that were busy when the process died resume on open; watch them so their
            // progress shows in the list.
            for task in tasks where task.conversationId != nil {
                watch(task.conversationId!)
            }
        } catch {
            phase = .failed(String(describing: error))
            diagnostics.record("error", "app", "Open failed: \(error)")
        }
    }

    // MARK: Events from JS

    private func handle(_ json: String) {
        let data = Data(json.utf8)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        let decoder = JSONDecoder()
        switch envelope.type {
        case "frame":
            guard let frame = try? decoder.decode(FrameEvent.self, from: data).frame else {
                diagnostics.record("error", "app", "Undecodable frame: \(json.prefix(300))")
                return
            }
            state(frame.conversationId).apply(frame)
            updateBackgroundTime()
        case "conversations":
            if let event = try? decoder.decode(ConversationsEvent.self, from: data) { conversations = event.items }
        case "approvals":
            if let event = try? decoder.decode(ApprovalsEvent.self, from: data) {
                approvals = event.pending
                if !event.pending.isEmpty { diagnostics.record("info", "approval", "Waiting for approval: \(event.pending.map(\.tool).joined(separator: ", "))") }
            }
        case "report":
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let info = (object?["info"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            diagnostics.record("warn", "report", "\(object?["error"] as? String ?? "?") \(info)")
            Task { await refreshTasks() }
        case "wake":
            // Active/idle flips are constant; a sleep deadline is what M3's BackgroundTasks will arm from.
            if json.contains("\"at\"") { diagnostics.record("info", "wake", String(json.prefix(300))) }
        default:
            break
        }
    }

    private struct Envelope: Decodable { let type: String }
    private struct FrameEvent: Decodable { let frame: DisplayFrame }
    private struct ConversationsEvent: Decodable { let items: [ConversationMeta] }
    private struct ApprovalsEvent: Decodable { let pending: [ApprovalRequest] }

    // MARK: Conversations

    func watch(_ id: Int) {
        guard let harness, !watched.contains(id) else { return }
        watched.insert(id)
        _ = state(id)
        Task {
            do { try await harness.perform("PiRuntime.watchConversation", [id]) } catch { report("watch", error) }
        }
    }

    func newConversation() async -> ConversationMeta? {
        guard let harness else { return nil }
        do {
            let meta: ConversationMeta = try await harness.call("PiRuntime.createConversation", [defaultModel.provider, defaultModel.modelId])
            watch(meta.id)
            return meta
        } catch {
            report("new conversation", error)
            return nil
        }
    }

    func send(_ text: String, to id: Int) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let harness, !trimmed.isEmpty else { return }
        watch(id)
        do {
            try await harness.perform("PiRuntime.send", [id, trimmed, UUID().uuidString])
        } catch {
            report("send", error)
        }
    }

    func abort(_ id: Int) async {
        guard let harness else { return }
        do { try await harness.perform("PiRuntime.abort", [id]) } catch { report("abort", error) }
    }

    func fork(_ id: Int, at entryId: Int) async -> ConversationMeta? {
        guard let harness else { return nil }
        do {
            let meta: ConversationMeta = try await harness.call("PiRuntime.fork", [id, entryId])
            watch(meta.id)
            diagnostics.record("info", "app", "Forked conversation \(id) at entry \(entryId) into \(meta.id)")
            return meta
        } catch {
            report("fork", error)
            return nil
        }
    }

    func rename(_ id: Int, to title: String) async {
        guard let harness else { return }
        do { try await harness.perform("PiRuntime.rename", [id, title]) } catch { report("rename", error) }
    }

    func remove(_ id: Int) async {
        guard let harness else { return }
        do {
            try await harness.perform("PiRuntime.removeConversation", [id])
            watched.remove(id)
            states[id] = nil
        } catch {
            report("remove", error)
        }
    }

    func setModel(_ model: ModelRef, for id: Int) async {
        guard let harness else { return }
        do { try await harness.perform("PiRuntime.setModel", [id, model.provider, model.modelId]) } catch { report("set model", error) }
    }

    func modelName(_ ref: ModelRef?) -> String {
        guard let ref else { return "No model" }
        return models.first { $0.ref == ref }?.name ?? ref.modelId
    }

    // MARK: Approvals

    func answer(_ request: ApprovalRequest, allow: Bool) async {
        guard let harness else { return }
        do {
            let _: Bool = try await harness.call("PiRuntime.answerApproval", [request.id, allow ? "allow" : "deny"])
            diagnostics.record("info", "approval", "\(allow ? "Allowed" : "Denied") \(request.tool) (task \(request.id))")
        } catch {
            report("approval", error)
        }
    }

    func setPolicy(_ policy: String, for tool: String) async {
        guard let harness else { return }
        var policies = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.policy) })
        policies[tool] = policy
        settings.set(policies, forKey: "toolPolicies")
        do {
            try await harness.perform("PiRuntime.setPolicies", [policies])
            await refreshTools()
        } catch {
            report("policy", error)
        }
    }

    func refreshTools() async {
        guard let harness else { return }
        do { tools = try await harness.call("PiRuntime.tools") } catch { report("tools", error) }
    }

    // MARK: Providers and keys

    func hasKey(_ provider: String) -> Bool { keyedProviders.contains(provider) }

    func setKey(_ key: String, for provider: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keys.setKey(trimmed, for: provider)
            keyedProviders.insert(provider)
            await applyProviders()
        } catch {
            report("save key", error)
        }
    }

    func removeKey(for provider: String) async {
        try? keys.removeKey(for: provider)
        keyedProviders.remove(provider)
        await applyProviders()
    }

    func applyProviders() async {
        guard let harness else { return }
        do {
            var arguments: [any Sendable] = [Array(keyedProviders)]
            if let custom { arguments.append(try harness.jsonArgument(custom)) }
            try await harness.perform("PiRuntime.configureProviders", arguments)
            await refreshModels()
        } catch {
            report("providers", error)
        }
    }

    func refreshModels() async {
        guard let harness else { return }
        do { models = try await harness.call("PiRuntime.models") } catch { report("models", error) }
    }

    // MARK: Tasks

    func refreshTasks() async {
        guard let harness else { return }
        do { tasks = try await harness.call("PiRuntime.tasks") } catch { report("tasks", error) }
    }

    func retry(_ task: TaskInfo) async {
        guard let harness else { return }
        do {
            try await harness.perform("PiRuntime.retryTask", [task.id])
            diagnostics.record("info", "task", "Retried parked task \(task.id) (\(task.kind))")
        } catch {
            report("retry", error)
        }
        await refreshTasks()
    }

    func abortTask(_ task: TaskInfo) async {
        guard let harness else { return }
        do {
            try await harness.perform("PiRuntime.abortTask", [task.id])
            diagnostics.record("info", "task", "Aborted task \(task.id) (\(task.kind))")
        } catch {
            report("abort task", error)
        }
        await refreshTasks()
    }

    // MARK: Background time

    /// While a run is going, ask iOS for the usual short background grace period. If it still suspends
    /// the app, Pi resumes the run at the next launch.
    private func updateBackgroundTime() {
        let busy = !busyConversations.isEmpty
        if busy, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pi.run") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTime() }
            }
        } else if !busy {
            endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Helpers

    private func report(_ action: String, _ error: Error) {
        diagnostics.record("error", "app", "\(action) failed: \(error)")
    }

    /// Debug builds only: `scripts/push-key.sh` copies a key file to `Documents/m0/import-<provider>.key`;
    /// it moves into the Keychain here and the file is deleted.
    private func importKeysIfPresent() {
        #if DEBUG
        for (provider, _) in Self.providers {
            let url = M0Files.url("import-\(provider).key")
            guard let key = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: url)
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, (try? keys.setKey(trimmed, for: provider)) != nil else { continue }
            diagnostics.record("info", "app", "Imported the \(provider) key into the Keychain")
        }
        #endif
    }
}
