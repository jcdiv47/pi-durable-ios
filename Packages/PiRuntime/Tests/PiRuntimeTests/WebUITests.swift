import Foundation
import Testing
@testable import PiRuntime

/// A web card's submission or prompt, as `ChatStore` sends it (`CardInput` in chat.ts).
private struct CardInput: Encodable {
    let conversationId: Int
    let cardId: String
    let requestId: String
    let kind: String
    var value: [String: String]?
    var text: String?
    var label: String?
}

@Suite("Web cards inside JavaScriptCore", .serialized)
struct WebUITests {
    @Test("show_ui stores the card and the transcript carries its HTML under the call", .timeLimit(.minutes(1)))
    func show() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openSurfaceChat(log, db: directory.appendingPathComponent("chat.sqlite").path, root: directory)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "webui", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }

        let result = try #require(log.last(meta.id, kind: "toolResult"))
        #expect(result["isError"] as? Bool == false, "\(result["text"] ?? "")")
        #expect((result["text"] as? String)?.contains("\"shown\": true") == true)
        #expect((result["text"] as? String)?.contains("warnings") == false, "\(result["text"] ?? "")")
        let card = try #require(result["webCard"] as? [String: Any])
        #expect(card["id"] as? String == "w1")
        #expect(card["version"] as? Int == 1)
        #expect(card["title"] as? String == "Trip planner")
        #expect((card["html"] as? String)?.contains("<pi-chart") == true)
        #expect(card["conversationId"] as? Int == meta.id)

        // A new version under the update's call; the first call keeps version 1.
        try await harness.perform("PiRuntime.send", [meta.id, "webupdate w1", "r2"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 8 }
        let results = log.items(meta.id).filter { $0["kind"] as? String == "toolResult" }
        let updated = try #require(results.last?["webCard"] as? [String: Any])
        #expect(updated["id"] as? String == "w1")
        #expect(updated["version"] as? Int == 2)
        #expect(updated["title"] as? String == "Trip planned")
        #expect((results.first?["webCard"] as? [String: Any])?["version"] as? Int == 1)
        try await harness.close()
    }

    @Test("A card's submission is one message per request ID, shown by its label", .timeLimit(.minutes(1)))
    func submit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openSurfaceChat(log, db: directory.appendingPathComponent("chat.sqlite").path, root: directory)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "webui", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }

        let input = CardInput(conversationId: meta.id, cardId: "w1", requestId: "card:w1:1:abc", kind: "submit", value: ["pace": "Slow", "nights": "4"])
        try await harness.perform("PiRuntime.cardInput", [try harness.jsonArgument(input)])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 6 }
        // The same tap delivered again is the same input.
        try await harness.perform("PiRuntime.cardInput", [try harness.jsonArgument(input)])
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.items(meta.id).count == 6)

        let users = log.items(meta.id).filter { $0["kind"] as? String == "user" }
        let sent = try #require(users.last)
        #expect(sent["origin"] as? String == "Card: Trip planner")
        #expect((sent["card"] as? [String: Any])?["id"] as? String == "w1")
        // No label from the page: a summary of the value, not the model's JSON.
        let shown = try #require(sent["text"] as? String)
        #expect(shown.contains("Pace: Slow") && shown.contains("Nights: 4"), "\(shown)")
        // The model got the value itself.
        let answer = try #require(log.last(meta.id, kind: "assistant")?["text"] as? String)
        #expect(answer.contains("Submitted from card w1") && answer.contains("\"pace\": \"Slow\""), "\(answer)")

        let prompt = CardInput(conversationId: meta.id, cardId: "w1", requestId: "card:w1:1:def", kind: "prompt", text: "Show cheaper hotels")
        try await harness.perform("PiRuntime.cardInput", [try harness.jsonArgument(prompt)])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 8 }
        let prompted = log.items(meta.id).filter { $0["kind"] as? String == "user" }.last
        #expect(prompted?["text"] as? String == "Show cheaper hotels")

        let missing = CardInput(conversationId: meta.id, cardId: "w9", requestId: "card:w9:1:x", kind: "prompt", text: "Hi")
        await #expect(throws: (any Error).self) {
            try await harness.perform("PiRuntime.cardInput", [try harness.jsonArgument(missing)])
        }
        try await harness.close()
    }
}
