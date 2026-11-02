import Foundation
import Observation
import os
import PiAppleTools
import PiRuntime
import PiUI
import SwiftUI
import UIKit

/// The chat app's state and the only owner of the Harness in chat mode. JS events arrive on the main
/// actor as JSON; calls into JS go through `PiHarness.call`. One per process (`shared`): the scene, App Intents,
/// notification actions and background tasks all reach Pi through it, and whichever comes first opens it.
@MainActor
@Observable
final class ChatStore {
    static let shared = ChatStore()

    /// The store once Pi is open, for entry points that may have launched the app in the background.
    static func ready() async -> ChatStore {
        await shared.ensureStarted()
        return shared
    }

    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    /// Providers with Keychain keys, in Settings order. `custom` is the user's OpenAI-compatible endpoint.
    static let providers: [(id: String, name: String)] = [
        ("anthropic", "Anthropic"), ("openai", "OpenAI"), ("openrouter", "OpenRouter"), ("deepseek", "DeepSeek"), ("custom", "Custom endpoint"),
    ]
    /// Keyed HTTP APIs behind tools, which are not model providers (docs/adr/0004-http-api-services.md).
    static let services: [(id: String, name: String)] = [("brave", "Brave Search")]
    static let offlineModel = ModelRef(provider: "scripted", modelId: "assistant")

    private(set) var phase = Phase.starting
    private(set) var conversations: [ConversationMeta] = []
    private(set) var states: [Int: ConversationState] = [:]
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var models: [ModelInfo] = []
    private(set) var tools: [ToolInfo] = []
    private(set) var tasks: [TaskInfo] = []
    private(set) var keyedProviders: Set<String> = []
    /// Surfaces on the Home Screen and Lock Screen.
    private(set) var published: [PublishedEntry] = []
    private(set) var schedules: [ScheduleEntry] = []
    /// A screen to show, from a notification, a deep link or an intent; the root view takes it.
    var pendingRoute: Route?
    /// Composer drafts from the share sheet's "Open in Pi to Edit", by conversation; the conversation's view takes them.
    private(set) var drafts: [Int: Draft] = [:]

    struct Draft: Hashable {
        var text: String
        var attachments: [Attachment]
    }
    /// What was left in a conversation's composer when its view went away, until it opens again. In memory only.
    private var composerDrafts: [Int: Draft] = [:]
    /// Native and `$doc` values for drawing surfaces in the app (chat cards, the Widgets screen).
    private(set) var surfaceData = SurfaceData()
    let diagnostics = DiagnosticsLog()

    /// How much the agent may generate per family (debug Settings). `SurfaceHost` reads it on every tool call.
    var dial = GenerativityDial() {
        didSet { settings.set(try? JSONEncoder().encode(dial), forKey: Self.dialKey) }
    }

    /// The model new conversations start with; a conversation keeps the one it started with.
    var defaultModel: ModelRef {
        didSet { settings.set(defaultModel.key, forKey: "defaultModel") }
    }

    /// The effort new conversations from the chat start with, clamped to the model in JS; a conversation keeps its own.
    var defaultThinking: String {
        didSet { settings.set(defaultThinking, forKey: "defaultThinking") }
    }

    /// Reminders' state by ID, read when a card shows them or set when one is ticked: a card's rows are its tool
    /// result's snapshot.
    private(set) var reminderDone: [String: Bool] = [:]
    /// Reminder lists' and calendars' colors by title, read when a card first needs them.
    private(set) var listColors: (reminders: [String: Color], calendars: [String: Color])?

    /// Where `web_search` searches: `off`, `deepseek`, `brave`, or `scripted` (offline, debug builds).
    var searchProvider: String {
        didSet {
            settings.set(searchProvider, forKey: "searchProvider")
            Task { await applySearchProvider() }
        }
    }

    /// Where links in the chat open: Pi's browser, pushed on the chat (`BrowserView`), or the default browser.
    var openLinksInApp: Bool {
        didSet { settings.set(openLinksInApp, forKey: "openLinksInApp") }
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
    private let native = NativeData()
    private var surfaceHost: SurfaceHost!
    private var surfaceDataRead = Date.distantPast
    nonisolated static let dialKey = "generativityDial"
    private let settings = UserDefaults.standard
    private var watched: Set<Int> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var startTask: Task<Void, Never>?
    private var receivingShares = false
    @ObservationIgnored private(set) var background: BackgroundWork!
    @ObservationIgnored private(set) var notifications: Notifications!
    @ObservationIgnored private(set) var activities: RunActivities!
    @ObservationIgnored private let spotlight = SpotlightIndex()
    nonisolated static let logger = Logger(subsystem: "dev.pi.durable", category: "chat")

    init() {
        let stored = settings.string(forKey: "defaultModel")?.split(separator: "/", maxSplits: 1).map(String.init)
        defaultModel = stored?.count == 2 ? ModelRef(provider: stored![0], modelId: stored![1]) : Self.offlineModel
        defaultThinking = settings.string(forKey: "defaultThinking") ?? "medium"
        searchProvider = settings.string(forKey: "searchProvider") ?? "off"
        openLinksInApp = settings.object(forKey: "openLinksInApp") as? Bool ?? true
        custom = settings.data(forKey: "customProvider").flatMap { try? JSONDecoder().decode(PiHarness.CustomProvider.self, from: $0) }
        ProviderKeys.setCustomHost(custom.flatMap { URL(string: $0.baseUrl)?.host() })
        dial = settings.data(forKey: Self.dialKey).flatMap { try? JSONDecoder().decode(GenerativityDial.self, from: $0) } ?? GenerativityDial()
        surfaceHost = SurfaceHost(
            native: native,
            dial: {
                UserDefaults.standard.data(forKey: ChatStore.dialKey).flatMap { try? JSONDecoder().decode(GenerativityDial.self, from: $0) } ?? GenerativityDial()
            },
            tuning: { [weak self] event in
                // The tuning log (spec "Generativity dial"), reviewed in Widgets › Design Tuning. Custom trees and failed
                // validations also go to Diagnostics.
                TuningLog.shared.append(event)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for tree in event.customTrees { self.diagnostics.record("info", "ui.custom", tree) }
                        if !event.errors.isEmpty { self.diagnostics.record("warn", "ui.invalid", event.errors.joined(separator: "\n")) }
                        if event.kind == .published {
                            self.diagnostics.record("info", "ui.published", event.detail ?? "")
                            self.spotlight.sync(self)
                        }
                    }
                }
            }
        )
        background = BackgroundWork(store: self)
        notifications = Notifications(store: self)
        activities = RunActivities(store: self)
        SharedIntents.perform = { request in await ChatStore.ready().perform(request) }
    }

    var busyConversations: [Int] { states.values.filter(\.live.busy).map(\.id) }

    func state(_ id: Int) -> ConversationState {
        if let state = states[id] { return state }
        let state = ConversationState(id: id)
        states[id] = state
        return state
    }

    // MARK: Start

    /// Opens Pi once per process, whoever asks first; later callers wait for the same start.
    func ensureStarted() async {
        guard LaunchMode.current == .chat else { return }
        if startTask == nil { startTask = Task { await start() } }
        await startTask?.value
    }

    private func start() async {
        importKeysIfPresent()
        keyedProviders = Set((Self.providers + Self.services).map(\.id).filter { keys.hasKey(for: $0) })
        do {
            let directory = try SharedContainer.directory("pi")
            let tools = appleTools
            let surfaces = surfaceHost!
            let notifications = notifications!
            let harness = try await PiHarness.load(bundle: AppModel.bundleURL, options: .init(
                keys: keys,
                usage: .shared,
                onEvent: { [weak self] json in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(json) } }
                },
                onLog: AppModel.forwardLog,
                hostCall: { name, json in
                    if SurfaceHost.handlers.contains(name) { return try await surfaces.handle(name, json) }
                    if name == "notify.post" || name == "notify.schedule" {
                        let args = try JSONDecoder().decode(Notifications.NotifyArguments.self, from: Data(json.utf8))
                        return try await notifications.post(args)
                    }
                    return try await tools.handle(name, json)
                }
            ))
            _ = try await harness.open(.init(
                dbPath: directory.appendingPathComponent("session.sqlite").path,
                provider: defaultModel.provider,
                modelId: defaultModel.modelId,
                keyedProviders: Array(keyedProviders),
                customProvider: custom,
                searchProvider: searchProvider,
                policies: settings.dictionary(forKey: "toolPolicies") as? [String: String]
            ))
            self.harness = harness
            conversations = try await harness.call("PiRuntime.conversations")
            await refreshModels()
            await refreshTools()
            await refreshTasks()
            approvals = try await harness.call("PiRuntime.approvals")
            await syncSurfaces()
            await refreshSchedules()
            phase = .ready
            diagnostics.record("info", "app", "Opened Pi storage; \(conversations.count) conversations")
            spotlight.sync(self)
            // Conversations that were busy when the process died resume on open; watch them so their
            // progress shows in the list.
            let resuming = Set(tasks.compactMap(\.conversationId))
            for id in resuming { watch(id) }
            activities.adopt(busy: resuming)
            // Widget and Live Activity taps that could not reach the app while it was not running.
            for request in PendingIntents.drain() { await perform(request) }
            publishRecent()
            await receiveShares()
            await sweepAttachments()
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
            let conversation = state(frame.conversationId)
            let wasBusy = conversation.loaded && conversation.live.busy
            conversation.apply(frame)
            updateBackgroundTime()
            activities.update(conversation, approval: approvals.first { $0.conversationId == conversation.id })
            background.progress(busy: busyConversations.count, status: activities.statusText(conversation.id))
            if wasBusy, !conversation.live.busy {
                runEnded(conversation)
                spotlight.sync(self, refresh: [conversation.id])
            }
        case "conversations":
            if let event = try? decoder.decode(ConversationsEvent.self, from: data) {
                conversations = event.items
                publishRecent()
                if phase == .ready { spotlight.sync(self) }
            }
        case "approvals":
            if let event = try? decoder.decode(ApprovalsEvent.self, from: data) {
                let previous = Set(approvals.map(\.id))
                approvals = event.pending
                if !event.pending.isEmpty { diagnostics.record("info", "approval", "Waiting for approval: \(event.pending.map(\.tool).joined(separator: ", "))") }
                approvalsChanged(new: event.pending.filter { !previous.contains($0.id) })
            }
        case "report":
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let info = (object?["info"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            diagnostics.record("warn", "report", "\(object?["error"] as? String ?? "?") \(info)")
            Task { await refreshTasks() }
        case "wake":
            guard let wake = try? decoder.decode(WakeEvent.self, from: data).wake else { return }
            // Active/idle flips with every run; only sleep deadlines are worth a line.
            if wake.at != nil, wake.at != background.wake.at { diagnostics.record("info", "wake", "Next sleep ends \(wake.date!.formatted(date: .abbreviated, time: .shortened))") }
            background.update(wake)
        default:
            break
        }
    }

    private struct Envelope: Decodable { let type: String }
    private struct FrameEvent: Decodable { let frame: DisplayFrame }
    private struct ConversationsEvent: Decodable { let items: [ConversationMeta] }
    private struct ApprovalsEvent: Decodable { let pending: [ApprovalRequest] }
    private struct WakeEvent: Decodable { let wake: BackgroundWork.Wake }

    // MARK: Conversations

    func watch(_ id: Int) {
        guard let harness, !watched.contains(id) else { return }
        watched.insert(id)
        _ = state(id)
        Task {
            do { try await harness.perform("PiRuntime.watchConversation", [id]) } catch { report("watch", error) }
        }
    }

    /// A conversation's messages as plain text, for Spotlight.
    func searchText(_ id: Int) async -> String? {
        guard let harness else { return nil }
        return try? await harness.call("PiRuntime.searchText", [id])
    }

    /// The newest conversation if nothing was ever sent in it: the compose button opens it instead of making another.
    var unusedConversation: ConversationMeta? {
        guard let top = conversations.first, top.forkOf == nil, top.updatedAt == top.createdAt else { return nil }
        return top
    }

    func newConversation() async -> ConversationMeta? {
        guard let harness else { return nil }
        do {
            let meta: ConversationMeta = try await harness.call(
                "PiRuntime.createConversation", [defaultModel.provider, defaultModel.modelId, defaultThinking]
            )
            watch(meta.id)
            return meta
        } catch {
            report("new conversation", error)
            return nil
        }
    }

    func send(_ text: String, attachments: [Attachment] = [], to id: Int) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let harness, !trimmed.isEmpty || !attachments.isEmpty else { return }
        watch(id)
        do {
            var arguments: [any Sendable] = [id, trimmed, UUID().uuidString]
            if !attachments.isEmpty { arguments.append(try attachments.compactMap(InputAttachment.init).map { try harness.jsonArgument($0) }) }
            try await harness.perform("PiRuntime.send", arguments)
            let title = conversations.first { $0.id == id }?.title ?? "Pi"
            activities.start(conversationId: id, title: title)
            // The first run asks for notification permission: answers and approvals may arrive while away.
            Task { await notifications.authorize() }
        } catch {
            report("send", error)
        }
    }

    func abort(_ id: Int) async {
        guard let harness else { return }
        do { try await harness.perform("PiRuntime.abort", [id]) } catch { report("abort", error) }
    }

    /// Takes a queued message back; false when it was already sent.
    func withdraw(_ message: QueuedMessage, from id: Int) async -> Bool {
        guard let harness else { return false }
        do { return try await harness.call("PiRuntime.withdraw", [id, message.id]) } catch {
            report("withdraw", error)
            return false
        }
    }

    /// Takes a queued message back to edit it, with its attachments; nil when it was already sent. An image whose file
    /// is gone is left out.
    func takeBack(_ message: QueuedMessage, from id: Int) async -> Draft? {
        guard let harness else { return nil }
        do {
            let taken: TakenBack? = try await harness.call("PiRuntime.takeBack", [id, message.id])
            guard let taken else { return nil }
            let attachments = taken.attachments.compactMap(\.attachment).filter { attachment in
                guard case let .image(file) = attachment.content else { return true }
                guard let url = Attachments.imageURL(file), FileManager.default.fileExists(atPath: url.path) else { return false }
                Attachments.touch(file)
                return true
            }
            return Draft(text: taken.text, attachments: attachments)
        } catch {
            report("take back", error)
            return nil
        }
    }

    /// Sends a queued message before the answer ends: after the running tools, or now, stopping streamed text.
    func steer(_ message: QueuedMessage, in id: Int) async {
        guard let harness else { return }
        do { try await harness.perform("PiRuntime.steer", [id, message.id]) } catch { report("steer", error) }
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

    func model(_ ref: ModelRef?) -> ModelInfo? { models.first { $0.ref == ref } }

    func modelName(_ ref: ModelRef?) -> String {
        guard let ref else { return "No model" }
        return models.first { $0.ref == ref }?.name ?? ref.modelId
    }

    // MARK: Approvals

    func answer(_ request: ApprovalRequest, allow: Bool) async {
        await answerApproval(request.id, allow: allow, tool: request.tool)
    }

    /// By ID, for notification and Live Activity buttons: the request may not be waiting yet in a process the
    /// button just launched, so JS keeps the answer for when the hook asks again.
    func answerApproval(_ id: Int, allow: Bool, tool: String? = nil) async {
        guard let harness else { return }
        do {
            let waiting: Bool = try await harness.call("PiRuntime.answerApproval", [id, allow ? "allow" : "deny"])
            diagnostics.record("info", "approval", "\(allow ? "Allowed" : "Denied") \(tool ?? "a tool") (task \(id))\(waiting ? "" : ", before it asked again")")
        } catch {
            report("approval", error)
        }
    }

    /// New requests while the app is away become notifications with Allow and Deny; answered ones are removed.
    private func approvalsChanged(new: [ApprovalRequest]) {
        for request in Set(approvals.map(\.conversationId)).union(new.map(\.conversationId)) {
            if let state = states[request] { activities.update(state, approval: approvals.first { $0.conversationId == request }) }
        }
        let away = UIApplication.shared.applicationState != .active
        let pending = Set(approvals.map(\.id))
        Task {
            if away {
                for request in new {
                    let title = conversations.first { $0.id == request.conversationId }?.title ?? "Pi"
                    await notifications.postApproval(request, conversation: title)
                }
            }
            await notifications.removeApprovals(except: pending)
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

    func applySearchProvider() async {
        guard let harness else { return }
        do { try await harness.perform("PiRuntime.setSearchProvider", [searchProvider]) } catch { report("search provider", error) }
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

    // MARK: Surfaces

    func refreshPublished() async {
        guard let harness else { return }
        do { published = try await harness.call("PiRuntime.publishedSurfaces") } catch { report("published surfaces", error) }
        spotlight.sync(self)
    }

    func surfaces(of conversationId: Int) async -> [SurfaceRef] {
        guard let harness else { return [] }
        do { return try await harness.call("PiRuntime.surfaces", [conversationId]) } catch {
            report("surfaces", error)
            return []
        }
    }

    func unpublish(_ publishedId: String) async {
        guard let harness else { return }
        do {
            try await harness.perform("PiRuntime.unpublishSurface", [publishedId])
            diagnostics.record("info", "ui", "Unpublished \(publishedId)")
        } catch {
            report("unpublish", error)
        }
        await refreshPublished()
    }

    /// Re-reads native data and `$doc` values for surfaces drawn in the app, at most once a minute unless forced.
    func refreshSurfaceData(force: Bool = false) async {
        guard let harness, force || Date.now.timeIntervalSince(surfaceDataRead) > 60 else { return }
        surfaceDataRead = .now
        let doc: [String: JSONValue] = (try? await harness.call("PiRuntime.surfaceValues")) ?? [:]
        let values = await native.read(Set(DataSources.sources.map(\.name)))
        surfaceData = SurfaceData(native: values, doc: doc)
    }

    /// Pi storage is the source of truth: rewrite the widget's copy of the `$doc` values at launch, in case the
    /// process died between a commit and its export.
    private func syncSurfaces() async {
        guard let harness else { return }
        do {
            let values: [String: JSONValue] = try await harness.call("PiRuntime.surfaceValues")
            try SurfaceStore.shared?.writeValues(values)
            SurfaceStore.reloadWidgets()
            published = try await harness.call("PiRuntime.publishedSurfaces")
        } catch {
            report("sync surfaces", error)
        }
    }

    // MARK: Entry points outside the chat

    /// Siri, Shortcuts and notification replies: sends `text` (to a new conversation when `conversationId` is nil) and
    /// waits up to `waitMs` for the answer. A run still going then notifies when it ends.
    func askFromOutside(
        _ text: String, conversationId: Int?, requestId: String, origin: String, waitMs: Int = 20_000, attachments: [Attachment] = []
    ) async throws -> OutsideAnswer {
        guard let harness else { throw PiIntentError("Pi could not open its storage.") }
        if let conversationId { watch(conversationId) }
        let input = OutsideInput(
            text: text, requestId: requestId, origin: origin, conversationId: conversationId, waitMs: waitMs, model: defaultModel,
            attachments: attachments.compactMap(InputAttachment.init)
        )
        let answer: OutsideAnswer = try await harness.call("PiRuntime.askFromOutside", [try harness.jsonArgument(input)])
        watch(answer.conversationId)
        diagnostics.record("info", "entry", "\(origin): \(answer.status) in conversation \(answer.conversationId) (\(requestId))")
        return answer
    }

    /// Share sheet items (`ShareInbox`): sent with their request ID, so one picked up twice is one message, or put in a
    /// conversation's composer. Each leaves the inbox once handled. A conversation removed meanwhile becomes a new one.
    func receiveShares() async {
        guard harness != nil, !receivingShares else { return }
        receivingShares = true
        defer { receivingShares = false }
        for input in ShareInbox.pending() {
            let target = input.conversationId.flatMap { id in conversations.contains { $0.id == id } ? id : nil }
            if input.draft {
                var id = target
                if id == nil { id = await newConversation()?.id }
                guard let id else { continue }
                // Shares that waited for Pi may target one conversation; each adds to its draft.
                let earlier = drafts[id]
                drafts[id] = Draft(
                    text: [earlier?.text ?? "", input.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                    attachments: (earlier?.attachments ?? []) + input.attachments
                )
                ShareInbox.remove(input.id)
                open(.conversation(id))
                continue
            }
            do {
                let answer = try await askFromOutside(
                    input.text, conversationId: target, requestId: input.requestId, origin: "Share sheet", waitMs: 0, attachments: input.attachments
                )
                ShareInbox.remove(input.id)
                activities.start(conversationId: answer.conversationId, title: conversations.first { $0.id == answer.conversationId }?.title ?? "Pi")
                open(.conversation(answer.conversationId))
                Task { await notifications.authorize() }
            } catch {
                report("share", error)
            }
        }
    }

    /// Dictated text for a conversation's composer, which takes it whether its view is still there or opens again.
    func addDraft(_ text: String, to id: Int) {
        let earlier = drafts[id]
        drafts[id] = Draft(text: [earlier?.text ?? "", text].filter { !$0.isEmpty }.joined(separator: " "), attachments: earlier?.attachments ?? [])
    }

    func takeDraft(_ id: Int) -> Draft? {
        drafts.removeValue(forKey: id)
    }

    func keepComposerDraft(_ draft: Draft, for id: Int) {
        composerDrafts[id] = draft.text.isEmpty && draft.attachments.isEmpty ? nil : draft
    }

    func takeComposerDraft(_ id: Int) -> Draft? {
        composerDrafts.removeValue(forKey: id)
    }

    /// Deletes attachment images nothing shows or sends any more (`Attachments.sweep`), at most once a day, when Pi
    /// opens: the composer's own attachments are then all younger than the sweep's grace period. Removing a
    /// conversation lets its images go; a fork keeps the ones it shows.
    private func sweepAttachments() async {
        let key = "attachmentsSweptAt"
        guard let harness, Date().timeIntervalSince(settings.object(forKey: key) as? Date ?? .distantPast) > Attachments.sweepGrace else { return }
        // Swift's references first: a share item moves from the inbox to `drafts` to a composer, and a composer's left-over
        // draft waits in `composerDrafts`.
        var kept = Set(ShareInbox.pending().flatMap { Attachments.files($0.attachments) } + (Array(drafts.values) + composerDrafts.values).flatMap { Attachments.files($0.attachments) })
        do {
            let files: [String] = try await harness.call("PiRuntime.attachmentFiles")
            kept.formUnion(files)
        } catch {
            return report("sweep attachments", error)
        }
        settings.set(Date(), forKey: key)
        let removed = await Task.detached(priority: .utility) { [kept] in Attachments.sweep(keeping: kept) }.value
        if removed > 0 { diagnostics.record("info", "app", "Deleted \(removed) unused attachment images (\(kept.count) in use)") }
    }

    /// The share sheet's conversation picker reads these from the App Group.
    private func publishRecent() {
        RecentConversation.write(conversations.prefix(12).map { RecentConversation(id: $0.id, title: $0.title) })
    }

    /// Widget and Live Activity buttons (`SharedIntents`).
    func perform(_ request: SharedIntentRequest) async {
        guard let harness else { return }
        switch request {
        case let .widgetAction(publishedId, actionId, _):
            guard let action = SurfaceStore.shared?.surface(publishedId)?.parsed.action(actionId) else {
                return diagnostics.record("warn", "entry", "Widget action \(actionId) is not in \(publishedId) any more")
            }
            if case let .completeReminder(id) = action {
                return await completeReminder(id, requestId: request.requestId)
            }
            do {
                let result: WidgetActionResult = try await harness.call("PiRuntime.widgetAction", [
                    publishedId, try harness.jsonArgument(action.json), request.requestId, defaultModel.provider, defaultModel.modelId,
                ])
                if let conversationId = result.conversationId { watch(conversationId) }
                diagnostics.record("info", "entry", "Widget action \(actionId) of \(publishedId) (\(request.requestId))")
                await refreshSurfaceData(force: true)
                if UIApplication.shared.applicationState != .active { await background.waitForIdle(timeout: .seconds(25)) }
            } catch {
                report("widget action", error)
            }
        case let .answerApproval(id, allow):
            await answerApproval(id, allow: allow)
            if UIApplication.shared.applicationState != .active { await background.waitForIdle(timeout: .seconds(25)) }
        case let .stopRun(conversationId):
            await abort(conversationId)
        }
    }

    private struct WidgetActionResult: Decodable { let conversationId: Int? }

    /// A reminder row in a chat card: EventKit only, like a widget's. The card shows the change at once; a failure undoes it.
    func setReminder(_ id: String, done: Bool) async {
        reminderDone[id] = done
        do {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["id": id, "completed": done]), as: UTF8.self)
            _ = try await appleTools.handle("reminders.complete", json)
            await refreshSurfaceData(force: true)
            SurfaceStore.reloadWidgets()
        } catch {
            reminderDone[id] = !done
            report("complete reminder", error)
        }
    }

    /// A card's reminders as they are now: its rows are the tool result's snapshot, which may be days old.
    func loadReminderStates(_ ids: [String]) {
        for (id, done) in appleTools.reminderCompletion(ids) where reminderDone[id] != done { reminderDone[id] = done }
    }

    func loadListColors() {
        guard listColors == nil else { return }
        let colors = appleTools.listColors()
        listColors = (colors.reminders.mapValues { Color(cgColor: $0) }, colors.calendars.mapValues { Color(cgColor: $0) })
    }

    /// A reminder row in a widget: EventKit only, no Pi. Completing is idempotent, so a repeated delivery is harmless.
    private func completeReminder(_ id: String, requestId: String) async {
        do {
            let json = String(decoding: try JSONEncoder().encode(["id": id]), as: UTF8.self)
            _ = try await appleTools.handle("reminders.complete", json)
            diagnostics.record("info", "entry", "Completed a reminder from a widget (\(requestId))")
            await refreshSurfaceData(force: true)
            SurfaceStore.reloadWidgets()
        } catch {
            report("complete reminder", error)
        }
    }

    func notificationResponse(identifier: String, action: String, conversationId: Int?, approvalId: Int?, reply: String?) async {
        await ensureStarted()
        switch action {
        case Notifications.allowAction, Notifications.denyAction:
            guard let approvalId else { return }
            await answerApproval(approvalId, allow: action == Notifications.allowAction)
            await resumeWork()
            await background.waitForIdle(timeout: .seconds(25))
        case Notifications.replyAction:
            guard let conversationId, let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = try? await askFromOutside(
                reply, conversationId: conversationId, requestId: IntentRequest.id("reply", identifier, reply), origin: "Notification reply", waitMs: 25_000
            )
        default:
            if let conversationId { open(.conversation(conversationId)) }
        }
    }

    func open(_ route: Route) {
        pendingRoute = route
    }

    /// Runs due sleeps and work a lost process left (BackgroundTasks, coming back to the foreground).
    func resumeWork() async {
        guard let harness else { return }
        do {
            let wake: BackgroundWork.Wake = try await harness.call("PiRuntime.resume")
            background.update(wake)
        } catch {
            report("resume", error)
        }
    }

    /// A watched run ended. While the app is away, its answer becomes a notification.
    private func runEnded(_ conversation: ConversationState) {
        guard UIApplication.shared.applicationState != .active,
              let answer = conversation.items.last(where: { $0.kind == .assistant }), answer.stopReason != "aborted"
        else { return }
        let title = conversations.first { $0.id == conversation.id }?.title ?? "Pi"
        let text = answer.stopReason == "error" ? "The run failed: \(answer.error ?? "model error")" : answer.text ?? ""
        Task { await notifications.postAnswer(conversationId: conversation.id, entryId: answer.id, title: title, text: text) }
    }

    func scenePhaseChanged(from old: ScenePhase, to new: ScenePhase) {
        switch new {
        case .inactive where old == .active:
            let titles = busyConversations.map { id in conversations.first { $0.id == id }?.title ?? "Conversation \(id)" }
            background.continueRuns(titles: titles)
        case .background:
            background.enteredBackground()
            // Requests the user left unanswered in the app follow them out as notifications (same identifiers).
            let pending = approvals
            Task {
                for request in pending {
                    await notifications.postApproval(request, conversation: conversations.first { $0.id == request.conversationId }?.title ?? "Pi")
                }
            }
        case .active:
            background.enteredForeground()
            // Cards on screen show reminders and colors as they are now: they may have changed, or access been granted.
            if listColors != nil { listColors = nil; loadListColors() }
            loadReminderStates(Array(reminderDone.keys))
            Task {
                guard phase == .ready else { return }
                await resumeWork()
                for request in PendingIntents.drain() { await perform(request) }
                await receiveShares()
                await refreshSchedules()
            }
        default:
            break
        }
    }

    // MARK: Schedules

    func refreshSchedules() async {
        schedules = await scheduleList()
    }

    func scheduleList() async -> [ScheduleEntry] {
        guard let harness else { return [] }
        do { return try await harness.call("PiRuntime.schedules") } catch {
            report("schedules", error)
            return []
        }
    }

    func runSchedule(_ name: String, requestId: String) async throws -> OutsideAnswer {
        guard let harness else { throw PiIntentError("Pi could not open its storage.") }
        let answer: OutsideAnswer = try await harness.call("PiRuntime.runSchedule", [name, requestId, 20_000, defaultModel.provider, defaultModel.modelId])
        watch(answer.conversationId)
        diagnostics.record("info", "entry", "Ran \(name) now (\(requestId))")
        return answer
    }

    func cancelSchedule(_ schedule: ScheduleEntry) async {
        guard let harness else { return }
        do {
            try await harness.perform("PiRuntime.cancelSchedule", [schedule.taskId])
            diagnostics.record("info", "task", "Cancelled scheduled task \(schedule.name)")
        } catch {
            report("cancel schedule", error)
        }
        await refreshSchedules()
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
        for (provider, _) in Self.providers + Self.services {
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
