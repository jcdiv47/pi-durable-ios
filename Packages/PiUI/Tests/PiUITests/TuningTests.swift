import Foundation
import Testing
@testable import PiUI

@Suite("Tuning log")
struct TuningTests {
    let water = #"{"t":"HStack","children":[{"t":"Image","symbol":"drop.fill"},{"t":"VStack","children":[{"t":"Text","text":"Water"},{"t":"Progress","value":5}]}]}"#
    let other = #"{"t":"HStack","children":[{"t":"Image","symbol":"flame"},{"t":"VStack","children":[{"t":"Text","text":"Energy"},{"t":"Progress","value":0.4}]}]}"#

    func validated(_ families: [String], errors: [String] = [], trees: [String] = []) -> TuningEvent {
        TuningEvent(kind: .validated, families: families, levels: [:], errors: errors, customTrees: trees)
    }

    @Test("Custom trees group by shape, whatever their text and values")
    func shapes() {
        #expect(TuningSummary.signature(water) == "HStack[Image, VStack[Text, Progress]]")
        let summary = TuningSummary([validated(["card"], trees: [water]), validated(["card"], trees: [other]), validated(["card"], trees: [water])], dial: .init())
        #expect(summary.shapes.map(\.count) == [3])
        #expect(summary.suggestions.contains { $0.contains("came up 3 times: HStack[Image, VStack[Text, Progress]]") })
    }

    @Test("Errors group by pattern; refused Custom suggests raising the level")
    func refusals() {
        let refusal = { (slot: Int) in "/slots/\(slot): Custom is not allowed in systemMedium at level 1 (Compose); use components" }
        let events = [
            validated(["systemMedium"], errors: [refusal(0)]),
            validated(["systemMedium"], errors: [refusal(2)]),
            validated(["systemMedium"], errors: [refusal(1), "/slots/0: Ring needs goal"]),
            validated(["systemMedium"]),
        ]
        let summary = TuningSummary(events, dial: .init())
        #expect(summary.failures.first?.count == 3)
        #expect(summary.failures.first?.pattern == "/slots/#: Custom is not allowed in systemMedium at level # (Compose); use components")
        let medium = summary.families.first { $0.family == .systemMedium }
        #expect(medium?.validations == 4)
        #expect(medium?.failures == 3)
        #expect(medium?.customRejected == 3)
        #expect(summary.suggestions.contains { $0.hasPrefix("Pi reached for Custom in Home Screen medium 3 times") && $0.contains("Raise it to 2 (Compose+)") })
        #expect(summary.suggestions.contains { $0.hasPrefix("75% of Home Screen medium designs failed") } == false, "four validations are too few to judge")
    }

    @Test("Family numbers count only events at the family's current level")
    func currentLevel() {
        let refusal = TuningEvent(
            kind: .validated, families: ["systemMedium"], levels: ["systemMedium": 1],
            errors: ["/slots/0: Custom is not allowed in systemMedium at level 1 (Compose); use components"]
        )
        var raised = GenerativityDial()
        raised.set(.composePlus, for: .systemMedium)
        let summary = TuningSummary(Array(repeating: refusal, count: 3), dial: raised)
        #expect(summary.families.map(\.validations) == [0], "the row stays, so its level can be changed back")
        #expect(summary.suggestions.isEmpty, "the refusals were at level 1; level 2 has no events yet")
    }

    @Test("Errors and Custom slots count only for the families they concern")
    func attribution() {
        let event = TuningEvent(
            kind: .validated, families: ["systemMedium", "systemLarge"], levels: [:],
            errors: ["/slots/1/tree: This Custom tree has 30 nodes; systemLarge at level 2 (Compose+) allows 24"],
            customTrees: [water], customFamilies: ["systemLarge"]
        )
        let mentions = validated(["systemMedium", "systemLarge"], errors: [#"/surface: surface must be "widget" or "card""#])
        let summary = TuningSummary([event, validated(["systemMedium", "systemLarge"], errors: ["/slots/0: Ring needs goal (number)"]), mentions], dial: .init())
        let medium = summary.families.first { $0.family == .systemMedium }
        let large = summary.families.first { $0.family == .systemLarge }
        #expect(medium?.failures == 2, "only the spec-wide errors, including one that merely mentions a family")
        #expect(medium?.custom == 0)
        #expect(large?.failures == 3)
        #expect(large?.custom == 1)
        #expect(large?.customRejected == 1)
    }

    @Test("A level whose freedom goes unused suggests lowering it")
    func unused() {
        let summary = TuningSummary(Array(repeating: validated(["systemLarge"]), count: 5), dial: .init())
        #expect(summary.suggestions == ["Home Screen large is at level 2 (Compose+) but Pi never used Custom there in 5 designs; level 1 (Compose) would do."])
    }

    @Test("The file keeps the newest events")
    func file() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tuning-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = TuningLog(url: url, limit: 3)
        for index in 0 ..< 7 { log.append(validated(["card"], errors: ["e\(index)"])) }
        #expect(log.read().map(\.errors) == [["e4"], ["e5"], ["e6"]])
        // Past twice the limit, reading trims the file.
        #expect(log.export().split(separator: "\n").count == 3)
        log.clear()
        #expect(log.read().isEmpty)
    }
}
