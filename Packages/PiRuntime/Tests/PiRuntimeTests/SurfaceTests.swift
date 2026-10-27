import Foundation
import PiUI
import Testing
@testable import PiRuntime

/// Opens the chat with the UI tools answered by PiUI's real `SurfaceHost`, publishing into `root`.
func openSurfaceChat(_ log: ChatLog, db: String, root: URL) async throws -> PiHarness {
    let host = SurfaceHost(store: SurfaceStore(root: root), reload: {})
    let (_, url) = try bundledScript("pi-runtime")
    let harness = try await PiHarness.load(bundle: url, options: .init(
        onEvent: { log.handle($0) },
        onLog: { level, message in if level == "error" || level == "warn" { print("[js \(level)] \(message)") } },
        hostCall: { name, json in
            log.record(name, json)
            guard SurfaceHost.handlers.contains(name) else { throw JSRuntimeError("unexpected host call \(name)") }
            return try await host.handle(name, json)
        }
    ))
    _ = try await harness.open(.init(dbPath: db, provider: "faux", modelId: "killtest"))
    return harness
}

struct SurfaceInfo: Decodable {
    struct Published: Decodable { let publishedId: String; let version: Int }
    let id: String
    let version: Int
    let published: Published?
}

struct PublishedInfo: Decodable {
    let publishedId: String
    let surfaceId: String
    let title: String
    let families: [String]
}

@Suite("UI tools inside JavaScriptCore", .serialized)
struct SurfaceTests {
    @Test("A widget is created, approved, published for the widget, and shown under its call", .timeLimit(.minutes(1)))
    func publish() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openSurfaceChat(log, db: directory.appendingPathComponent("chat.sqlite").path, root: directory)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "widget please", "r1"])

        try await until { log.approvals.count == 1 }
        #expect(log.approvals[0]["tool"] as? String == "publish_surface")
        #expect(log.calls("ui.publish") == 0)
        let _: Bool = try await harness.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 6 }

        let results = log.items(meta.id).filter { $0["kind"] as? String == "toolResult" }
        #expect(results.map { $0["isError"] as? Bool } == [false, false], "\(results.map { $0["text"] ?? "" })")
        let shown = results[0]["surface"] as? [String: Any]
        #expect(shown?["id"] as? String == "s1")
        #expect((shown?["spec"] as? [String: Any])?["title"] as? String == "Morning")

        let publishedId = "c\(meta.id)-s1"
        let file = try #require(SurfaceStore(root: directory).surface(publishedId))
        #expect(file.parsed.families == [.systemMedium, .systemSmall, .accessoryRectangular])
        let surfaces: [SurfaceInfo] = try await harness.call("PiRuntime.surfaces", [meta.id])
        #expect(surfaces.map(\.id) == ["s1"])
        #expect(surfaces[0].published?.publishedId == publishedId)
        let published: [PublishedInfo] = try await harness.call("PiRuntime.publishedSurfaces")
        #expect(published.map(\.publishedId) == [publishedId])
        #expect(published[0].title == "Morning")

        try await harness.perform("PiRuntime.unpublishSurface", [publishedId])
        #expect(SurfaceStore(root: directory).published().isEmpty)
        let after: [PublishedInfo] = try await harness.call("PiRuntime.publishedSurfaces")
        #expect(after.isEmpty)
        let surfacesAfter: [SurfaceInfo] = try await harness.call("PiRuntime.surfaces", [meta.id])
        #expect(surfacesAfter[0].published == nil)
        try await harness.close()
    }

    @Test("After a crash at the approval, the surface is not created twice and publishes once", .timeLimit(.minutes(1)))
    func crash() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("chat.sqlite").path
        let firstLog = ChatLog()
        let first = try await openSurfaceChat(firstLog, db: db, root: directory)
        let meta: Meta = try await first.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await first.perform("PiRuntime.send", [meta.id, "widget", "r1"])
        try await until { firstLog.approvals.count == 1 }
        first.runtime.terminate()

        let log = ChatLog()
        let second = try await openSurfaceChat(log, db: db, root: directory)
        try await second.perform("PiRuntime.watchConversation", [meta.id])
        try await until { log.approvals.count == 1 }
        let _: Bool = try await second.call("PiRuntime.answerApproval", [log.approvals[0]["id"] as! Int, "allow"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 6 }
        let surfaces: [SurfaceInfo] = try await second.call("PiRuntime.surfaces", [meta.id])
        #expect(surfaces.map(\.id) == ["s1"])
        #expect(log.calls("ui.publish") == 1)
        #expect(SurfaceStore(root: directory).published().count == 1)
        try await second.close()
    }

    @Test("A card is created and shown in the chat, never published", .timeLimit(.minutes(1)))
    func card() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openSurfaceChat(log, db: directory.appendingPathComponent("chat.sqlite").path, root: directory)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "card", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 4 }
        let result = try #require(log.last(meta.id, kind: "toolResult"))
        #expect(result["isError"] as? Bool == false)
        #expect((result["text"] as? String)?.contains("\"valid\": true") == true, "\(result["text"] ?? "")")
        #expect(((result["surface"] as? [String: Any])?["spec"] as? [String: Any])?["surface"] as? String == "card")
        #expect(log.calls("ui.validate") == 1)
        #expect(log.calls("ui.publish") == 0)
        try await harness.close()
    }

    @Test("A fork sees the parent's surfaces as of its fork point", .timeLimit(.minutes(1)))
    func fork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openSurfaceChat(log, db: directory.appendingPathComponent("chat.sqlite").path, root: directory)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "hello", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 2 }
        let beforeCard = log.items(meta.id)[1]["id"] as! Int
        try await harness.perform("PiRuntime.send", [meta.id, "card", "r2"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 6 }
        let afterCard = log.items(meta.id)[5]["id"] as! Int

        let early: Meta = try await harness.call("PiRuntime.fork", [meta.id, beforeCard])
        let late: Meta = try await harness.call("PiRuntime.fork", [meta.id, afterCard])
        let earlySurfaces: [SurfaceInfo] = try await harness.call("PiRuntime.surfaces", [early.id])
        let lateSurfaces: [SurfaceInfo] = try await harness.call("PiRuntime.surfaces", [late.id])
        #expect(earlySurfaces.isEmpty)
        #expect(lateSurfaces.map(\.id) == ["s1"])
        try await harness.close()
    }
}

extension SurfaceTests {
    @Test("Validation errors come back to the model; a patch at the right version fixes them", .timeLimit(.minutes(1)))
    func repair() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ChatLog()
        let harness = try await openSurfaceChat(log, db: directory.appendingPathComponent("chat.sqlite").path, root: directory)
        let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
        try await harness.perform("PiRuntime.watchConversation", [meta.id])
        try await harness.perform("PiRuntime.send", [meta.id, "repair", "r1"])
        try await until { !log.busy(meta.id) && log.items(meta.id).count == 6 }
        let results = log.items(meta.id).filter { $0["kind"] as? String == "toolResult" }.map { $0["text"] as? String ?? "" }
        #expect(results[0].contains("/slots/0/goal: Ring needs goal"), "\(results[0])")
        #expect(results[1].contains("\"version\": 2") && results[1].contains("\"valid\": true"), "\(results[1])")
        let surfaces: [SurfaceInfo] = try await harness.call("PiRuntime.surfaces", [meta.id])
        #expect(surfaces.map(\.version) == [2])
        try await harness.close()
    }
}
