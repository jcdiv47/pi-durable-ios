import Foundation
import Observation

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

struct DisplayFrame: Decodable {
    let conversationId: Int
    let reset: Bool
    let items: [DisplayItem]
    let live: DisplayLive
    let queued: Int
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
    private(set) var queued = 0
    private(set) var model: ModelRef?
    private(set) var usage = UsageTotals()
    private(set) var loaded = false

    init(id: Int) { self.id = id }

    func apply(_ frame: DisplayFrame) {
        if frame.reset {
            items = frame.items
            results = [:]
        } else {
            items.append(contentsOf: frame.items)
        }
        for item in frame.items where item.kind == .toolResult {
            if let callId = item.callId { results[callId] = item }
        }
        live = frame.live
        queued = frame.queued
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

/// Arbitrary JSON, for tool arguments shown to the user.
enum JSONValue: Decodable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    /// Short readable text: strings unquoted, numbers without a trailing `.0`.
    var display: String {
        switch self {
        case .null: "null"
        case let .bool(value): String(value)
        case let .number(value): value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case let .string(value): value
        case let .array(values): values.map(\.display).joined(separator: ", ")
        case let .object(fields): fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.display)" }.joined(separator: ", ")
        }
    }

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
