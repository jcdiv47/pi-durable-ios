import Foundation
import Testing
@testable import PiUI

@Suite("Surface host")
struct HostTests {
    func host(_ root: URL, reloads: Counter = Counter(), tuning: Counter = Counter()) -> SurfaceHost {
        SurfaceHost(store: SurfaceStore(root: root), reload: { reloads.add() }, tuning: { _ in tuning.add() })
    }

    func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("piui-\(UUID().uuidString)")
    }

    @Test("Publish writes the spec for the widget and reloads timelines; unpublish removes it")
    func publish() async throws {
        let root = temporaryRoot()
        let reloads = Counter()
        let host = host(root, reloads: reloads)
        let spec = Fixtures.spec("morning")
        let args: JSONValue = ["publishedId": "c7-s1", "conversationId": 7, "surfaceId": "s1", "version": 3, "spec": spec]
        _ = try await host.handle("ui.publish", args.jsonText)
        let store = SurfaceStore(root: root)
        let published = try #require(store.surface("c7-s1"))
        #expect(published.version == 3)
        #expect(published.spec == spec)
        #expect(published.dial == ["systemMedium": 1, "accessoryRectangular": 1])
        #expect(store.published().map(\.publishedId) == ["c7-s1"])
        #expect(reloads.value == 1)

        _ = try await host.handle("ui.unpublish", #"{"publishedId":"c7-s1"}"#)
        #expect(store.published().isEmpty)
    }

    @Test("Publishing an invalid spec fails with its errors")
    func publishInvalid() async throws {
        let host = host(temporaryRoot())
        let args: JSONValue = ["publishedId": "c1-s1", "conversationId": 1, "surfaceId": "s1", "version": 1, "spec": ["families": ["systemSmall"], "slots": []]]
        await #expect(throws: SurfaceHostError.self) { try await host.handle("ui.publish", args.jsonText) }
    }

    @Test("Values land in snapshots/values.json")
    func values() async throws {
        let root = temporaryRoot()
        _ = try await host(root).handle("ui.values", #"{"values":{"nudge":"Walk","goal":9000}}"#)
        #expect(SurfaceStore(root: root).values() == ["nudge": "Walk", "goal": 9000])
    }

    @Test("Every validation is logged for tuning, with its Custom trees and errors")
    func tuning() async throws {
        let tuning = Counter()
        let host = host(temporaryRoot(), tuning: tuning)
        let card: JSONValue = ["spec": ["surface": "card", "slots": [Fixtures.slot("Custom")]]]
        let report = try JSONValue(json: try await host.handle("ui.validate", card.jsonText))
        #expect(report["errors"]?.array?.isEmpty == true)
        #expect(tuning.value == 1)
        _ = try await host.handle("ui.validate", #"{"spec":{"slots":[]}}"#)
        #expect(tuning.value == 2)
    }

    @Test("Previews return a PNG per family and appearance, accessories once")
    func preview() async throws {
        let host = host(temporaryRoot())
        let args: JSONValue = ["spec": Fixtures.spec("morning"), "appearances": ["light", "dark"], "doc": ["nudge": "Walk"]]
        let result = try JSONValue(json: try await host.handle("ui.preview", args.jsonText))
        let images = result["images"]?.array ?? []
        #expect(images.map { "\($0["family"]!.display)/\($0["appearance"]!.display)" } == ["systemMedium/light", "systemMedium/dark", "accessoryRectangular/tinted"])
        #expect(images.first?["width"]?.number == 728)
        // No HealthKit or EventKit data on the test machine.
        #expect(result["missing"]?.array?.map(\.display) == ["calendar.next", "health.stepsToday"])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
