import Foundation
import Observation
import PiUI

// Swift mirrors of what `js/src/app/*.ts` emits. Frames follow `DisplayFrame` in js/src/app/display.ts.

struct ConversationMeta: Decodable, Identifiable, Hashable {
    struct ForkOf: Decodable, Hashable {
        let conversationId: Int
        let entryId: Int
    }

    let id: Int
    let title: String
    let createdAt: Double
    let updatedAt: Double
    let forkOf: ForkOf?

    var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

struct ModelRef: Codable, Hashable {
    let provider: String
    let modelId: String

    var key: String { "\(provider)/\(modelId)" }
}

struct ToolCallItem: Decodable, Hashable {
    let id: String
    let name: String
    let arguments: String
}

struct DisplayItem: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable {
        case user, assistant, toolResult, notice
    }

    let id: Int
    let kind: Kind
    var text: String?
    var thinking: String?
    var toolCalls: [ToolCallItem]?
    var callId: String?
    var toolName: String?
    var isError: Bool?
    var model: String?
    var stopReason: String?
    var error: String?
    var timestamp: Double?
    /// Where an input from outside the chat came from: Siri, a widget button, a schedule.
    var origin: String?
    /// A surface a UI tool made or changed (`DisplaySurface` in display.ts).
    var surface: SurfaceRef?
}

/// One version of a surface, as a UI tool result or `PiRuntime.surfaces` carries it.
struct SurfaceRef: Decodable, Hashable, Identifiable {
    struct Published: Decodable, Hashable {
        let publishedId: String
        let version: Int
    }

    let conversationId: Int
    let id: String
    let version: Int
    let spec: JSONValue
    var published: Published?

    var parsed: SurfaceSpec { SurfaceSpec(spec) }
}

/// A surface on the Home Screen or Lock Screen (`PublishedEntry` in surfaces.ts).
struct PublishedEntry: Decodable, Hashable, Identifiable {
    let publishedId: String
    let conversationId: Int
    let surfaceId: String
    let version: Int
    let title: String
    let families: [String]
    let publishedAt: Double

    var id: String { publishedId }
}

/// A scheduled task (`ScheduleEntry` in js/src/app/schedule.ts).
struct ScheduleEntry: Decodable, Hashable, Identifiable {
    let taskId: Int
    let conversationId: Int
    let name: String
    let prompt: String
    let everyMs: Double?
    let nextAt: Double?
    let runs: Int
    let lastRunAt: Double?
    let lastAnswer: String?
    let notify: Bool

    var id: Int { taskId }
    var next: Date? { nextAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var lastRun: Date? { lastRunAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var every: String {
        guard let everyMs else { return "Once" }
        let minutes = Int(everyMs / 60_000)
        return minutes % 1440 == 0 ? "Every \(minutes / 1440) d" : minutes % 60 == 0 ? "Every \(minutes / 60) h" : "Every \(minutes) min"
    }
}

/// An input from outside the chat (`OutsideInput` in js/src/app/chat.ts).
struct OutsideInput: Encodable {
    let text: String
    let requestId: String
    let origin: String
    let conversationId: Int?
    let waitMs: Int
    let model: ModelRef
}

struct OutsideAnswer: Decodable {
    let conversationId: Int
    /// `done`, `running` (still going after the wait) or `unanswered`.
    let status: String
    let text: String?
    let surface: SurfaceRef?
}

struct LiveGeneration: Decodable, Hashable {
    struct Retry: Decodable, Hashable {
        let at: Double
        let error: String
    }

    let text: String
    let thinking: String
    let toolCalls: [ToolCallItem]
    let attempt: Int
    let retry: Retry?
}

struct LiveTool: Decodable, Hashable {
    let callId: String
    let name: String
    let status: String
    let output: String?
}

struct DisplayLive: Decodable, Hashable {
    var busy = false
    var generation: LiveGeneration?
    var tools: [LiveTool] = []
    var compacting = false
    var compactionError: String?
}

struct UsageTotals: Decodable, Hashable {
    var input: Double = 0
    var output: Double = 0
    var cost: Double = 0
}

/// A message waiting for a boundary, by submission ID. A steer lands when the current tool round finishes.
struct QueuedMessage: Decodable, Identifiable, Hashable {
    let id: Int
    let text: String
    let mode: String

    var steering: Bool { mode == "steer" }
}

struct DisplayFrame: Decodable {
    let conversationId: Int
    let reset: Bool
    let items: [DisplayItem]
    let live: DisplayLive
    let queue: [QueuedMessage]
    let model: ModelRef?
    let usage: UsageTotals
}

/// One conversation as the transcript shows it, built from frames.
@MainActor
@Observable
final class ConversationState {
    let id: Int
    private(set) var items: [DisplayItem] = []
    /// Tool results by call ID, so each call renders with its result.
    private(set) var results: [String: DisplayItem] = [:]
    private(set) var live = DisplayLive()
    private(set) var queue: [QueuedMessage] = []
    private(set) var model: ModelRef?
    private(set) var usage = UsageTotals()
    private(set) var loaded = false
    /// For each surface ID, the call whose result holds its newest version: the transcript draws it there only.
    private(set) var latestSurfaceCall: [String: String] = [:]

    init(id: Int) { self.id = id }

    func apply(_ frame: DisplayFrame) {
        if frame.reset {
            items = frame.items
            results = [:]
            latestSurfaceCall = [:]
        } else {
            items.append(contentsOf: frame.items)
        }
        for item in frame.items where item.kind == .toolResult {
            if let callId = item.callId { results[callId] = item }
            if let surface = item.surface, let callId = item.callId { latestSurfaceCall[surface.id] = callId }
        }
        live = frame.live
        queue = frame.queue
        model = frame.model
        usage = frame.usage
        loaded = true
    }

    func liveTool(_ callId: String) -> LiveTool? { live.tools.first { $0.callId == callId } }
}

struct ModelInfo: Decodable, Identifiable, Hashable {
    let provider: String
    let providerName: String
    let id: String
    let name: String
    let reasoning: Bool
    let contextWindow: Double

    var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
}

struct ApprovalRequest: Decodable, Identifiable, Hashable {
    let id: Int
    let conversationId: Int
    let callId: String
    let tool: String
    let arguments: JSONValue
    let requestedAt: Double
}

struct ToolInfo: Decodable, Identifiable, Hashable {
    let name: String
    let description: String
    let policy: String

    var id: String { name }
}

struct TaskInfo: Decodable, Identifiable, Hashable {
    let id: Int
    let kind: String
    let conversationId: Int?
    let state: String
    let reason: String?
    let error: String?

    var parked: Bool { state == "blocked" && reason == "restart_limit" }
}

extension JSONValue {
    /// An object's fields as readable key/value text, for tool arguments shown to the user.
    var fields: [(String, String)] {
        if case let .object(fields) = self { return fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value.display) } }
        return [("value", display)]
    }
}

/// Pretty JSON text for a tool call's arguments, as the model sent them.
func prettyJSON(_ text: String) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return text }
    return String(decoding: data, as: UTF8.self)
}
