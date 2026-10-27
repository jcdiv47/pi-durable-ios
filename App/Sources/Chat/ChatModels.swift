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
    /// The parsed output of a tool the chat draws a native card for (`cardTools` in display.ts).
    var data: JSONValue?

    var date: Date? { timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } }
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
    let thinkingLevel: String
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
    /// pi-ai's `ModelThinkingLevel`: `off`, `minimal`, `low`, `medium`, `high`, `xhigh` or `max`.
    private(set) var thinkingLevel = "off"
    private(set) var usage = UsageTotals()
    private(set) var loaded = false
    /// When the current run started: its input's timestamp, or when this process first saw it busy. Nil while idle.
    private(set) var busySince: Date?
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
        if !frame.live.busy {
            busySince = nil
        } else if busySince == nil || !live.busy {
            busySince = runStart()
        }
        live = frame.live
        queue = frame.queue
        model = frame.model
        thinkingLevel = frame.thinkingLevel
        usage = frame.usage
        loaded = true
    }

    func liveTool(_ callId: String) -> LiveTool? { live.tools.first { $0.callId == callId } }

    /// The input after the last finished answer (one that did not stop to call tools), so a run resumed after a relaunch
    /// keeps its start. Its entry may not be committed yet when the first busy frame comes: then now.
    private func runStart() -> Date {
        let answered = items.lastIndex { $0.kind == .assistant && $0.stopReason != "toolUse" } ?? -1
        let input = items.indices.last { $0 > answered && items[$0].kind == .user }
        return input.flatMap { items[$0].date }.map { min($0, .now) } ?? .now
    }
}

struct ModelInfo: Decodable, Identifiable, Hashable {
    let provider: String
    let providerName: String
    let id: String
    let name: String
    let reasoning: Bool
    /// The thinking levels it supports, `off` first; just `off` for a model without reasoning.
    let thinkingLevels: [String]
    let contextWindow: Double

    var ref: ModelRef { ModelRef(provider: provider, modelId: id) }
}

/// pi-ai's thinking levels as the composer's effort menu names them.
enum ThinkingLevel {
    static func name(_ level: String) -> String {
        switch level {
        case "off": "Off"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Max"
        default: level.capitalized
        }
    }

    /// A gauge that fills with the level.
    static func symbol(_ level: String) -> String {
        switch level {
        case "off": "gauge.with.dots.needle.0percent"
        case "minimal", "low": "gauge.with.dots.needle.33percent"
        case "medium": "gauge.with.dots.needle.50percent"
        case "high": "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
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
