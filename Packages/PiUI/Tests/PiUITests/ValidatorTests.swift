import Foundation
import Testing
@testable import PiUI

@Suite("Validator")
struct ValidatorTests {
    let validator = SurfaceValidator(dial: Fixtures.openDial)

    func messages(_ report: ValidationReport) -> String {
        (report.errors + report.warnings).map { "\($0.path): \($0.message)" }.joined(separator: "\n")
    }

    @Test("Every fixture component validates in every family it supports", arguments: Catalog.components.map(\.name))
    func fixtureComponents(_ name: String) {
        let families = SurfaceFamily.widgetFamilies.filter { Catalog.component(name)!.families.contains($0) }
        let report = validator.validate(Fixtures.single(name, families: families))
        #expect(report.errors.isEmpty, "\(messages(report))")
    }

    @Test("The sample specs are valid at the default dial", arguments: Fixtures.specNames)
    func sampleSpecs(_ name: String) {
        let report = SurfaceValidator(docKeys: ["nudge", "focus"]).validate(Fixtures.spec(name))
        #expect(report.valid, "\(messages(report))")
    }

    @Test("Bindings report their sources and permissions")
    func sources() {
        let report = validator.validate(Fixtures.spec("morning"))
        #expect(report.sources == ["calendar.next", "doc.nudge", "health.stepsToday"])
        #expect(report.permissions == ["calendar", "health"])
    }

    @Test("An unknown component lists the known ones")
    func unknownComponent() {
        let report = validator.validate(["families": ["systemSmall"], "slots": [["c": "Donut", "value": 1]]])
        #expect(report.errors.first?.path == "/slots/0/c")
        #expect(report.errors.first?.message.contains("MetricTile") == true)
    }

    @Test("Missing and unknown props, and wrong literal types, are errors at their path")
    func props() {
        let report = validator.validate(["families": ["systemSmall"], "slots": [["c": "Ring", "value": "lots", "colour": "red"]]])
        let paths = Set(report.errors.map(\.path))
        #expect(paths == ["/slots/0/goal", "/slots/0/colour", "/slots/0/value"], "\(messages(report))")
    }

    @Test("A binding must name a known source of a fitting kind")
    func bindings() {
        let unknown = validator.validate(["families": ["systemSmall"], "slots": [["c": "MetricTile", "value": "$health.mood", "label": "Mood"]]])
        #expect(unknown.errors.first?.message.contains("Unknown data source") == true)
        let mismatch = validator.validate(["families": ["systemSmall"], "slots": [["c": "Ring", "value": "$health.stepsWeek", "goal": 10]]])
        #expect(mismatch.errors.first?.message.contains("a series") == true, "\(messages(mismatch))")
        let field = validator.validate(["families": ["systemSmall"], "slots": [["c": "Countdown", "date": "$calendar.next.date"]]])
        #expect(field.valid, "\(messages(field))")
        let literalOnly = validator.validate(["families": ["systemSmall"], "slots": [["c": "Countdown", "date": "$time.now", "style": "$doc.style"]]])
        #expect(literalOnly.errors.first?.path == "/slots/0/style")
    }

    @Test("$doc bindings warn when nothing is stored under the key")
    func docKeys() {
        let spec: JSONValue = ["families": ["systemSmall"], "slots": [["c": "Quote", "text": "$doc.nudge"]]]
        #expect(SurfaceValidator(docKeys: []).validate(spec).warnings.count == 1)
        #expect(SurfaceValidator(docKeys: ["nudge"]).validate(spec).warnings.isEmpty)
    }

    @Test("Slot limits: an error for a single family, a warning when another family uses the slots")
    func slotLimits() {
        let ring = Fixtures.slot("Ring")
        let single = validator.validate(["families": ["systemSmall"], "slots": [ring, ring]])
        #expect(single.errors.contains { $0.message.contains("allows 1 slot") })
        let shared = validator.validate(["families": ["systemSmall", "systemMedium"], "slots": [ring, ring]])
        #expect(shared.valid)
        #expect(shared.warnings.contains { $0.message.contains("shows only its first 1") })
    }

    @Test("A family that would show nothing is an error")
    func emptyFamily() {
        let report = validator.validate(["families": ["accessoryInline"], "slots": [Fixtures.slot("Ring")]])
        #expect(report.errors.contains { $0.message.contains("would show nothing") }, "\(messages(report))")
    }

    @Test("Level 0 requires a preset; level 1 forbids Custom; levels 2 and 3 cap its nodes")
    func dial() {
        let defaults = SurfaceValidator()
        let circular = defaults.validate(["families": ["accessoryCircular"], "slots": [Fixtures.slot("Badge")]])
        #expect(circular.errors.first?.message.contains("presets") == true, "\(messages(circular))")
        #expect(defaults.validate(["families": ["accessoryCircular"], "slots": [Fixtures.slot("Ring")]]).valid)

        let custom = Fixtures.slot("Custom")
        let medium = defaults.validate(["families": ["systemMedium"], "slots": [custom]])
        #expect(medium.errors.first?.message.contains("Custom is not allowed") == true)
        #expect(medium.customTrees.count == 1)
        #expect(defaults.validate(["families": ["systemLarge"], "slots": [custom]]).valid)

        let leaf: JSONValue = ["t": "Text", "text": "x"]
        let big: JSONValue = ["c": "Custom", "tree": ["t": "VStack", "children": .array(Array(repeating: leaf, count: 30))]]
        let tooBig = defaults.validate(["families": ["systemLarge"], "slots": [big]])
        #expect(tooBig.errors.first?.message.contains("31 nodes") == true, "\(messages(tooBig))")
        #expect(defaults.validate(["surface": "card", "slots": [big]]).valid)
    }

    @Test("Long literal text warns about truncation")
    func truncation() {
        let text = String(repeating: "word ", count: 30)
        let report = validator.validate(["families": ["systemSmall"], "slots": [["c": "Quote", "text": .string(text)]]])
        #expect(report.valid)
        #expect(report.warnings.contains { $0.message.contains("truncate") })
    }

    @Test("Custom trees are checked node by node")
    func customTree() {
        let tree: JSONValue = ["t": "VStack", "children": [["t": "Txt", "text": "a"], ["t": "Image"], ["t": "Text", "text": "b", "font": "huge"]]]
        let report = validator.validate(["surface": "card", "slots": [["c": "Custom", "tree": tree]]])
        let paths = Set(report.errors.map(\.path))
        #expect(paths == ["/slots/0/tree/children/0/t", "/slots/0/tree/children/1/symbol", "/slots/0/tree/children/2/font"], "\(messages(report))")
    }

    @Test("The catalog text lists every component, the presets of template families and the sources")
    func catalogText() {
        let text = CatalogText.describe(families: [], dial: GenerativityDial())
        for component in Catalog.components { #expect(text.contains("- \(component.name)")) }
        #expect(text.contains("presets: [Ring] [MetricTile] [Countdown]"))
        #expect(text.contains("$health.stepsToday"))
        let small = CatalogText.describe(families: [.systemSmall], dial: GenerativityDial())
        #expect(!small.contains("- Custom"))
        #expect(!small.contains("ActionRow"))
    }

    @Test("A button does exactly one thing; set needs a value")
    func actions() {
        let spec: JSONValue = ["families": ["systemMedium"], "slots": [["c": "ActionRow", "actions": [
            ["title": "Both", "url": "https://example.com", "prompt": "hi"],
            ["title": "None"],
            ["title": "Set", "set": "done"],
            ["title": "Bad key", "set": "a-b", "value": 1],
        ]]]]
        let errors = validator.validate(spec).errors.map(\.path)
        // Four buttons is also one too many.
        #expect(errors == ["/slots/0/actions", "/slots/0/actions/0", "/slots/0/actions/1", "/slots/0/actions/2/value", "/slots/0/actions/3/set"])
    }

    @Test("Action IDs resolve to the published spec's buttons and $doc checklist rows")
    func actionIds() {
        let spec = SurfaceSpec(["families": ["systemLarge"], "slots": [
            ["c": "Checklist", "items": "$doc.todo"],
            ["c": "ActionRow", "actions": [
                ["title": "Link", "url": "https://example.com"],
                ["title": "Ask", "prompt": "Plan my day"],
                ["title": "Done", "set": "walked", "value": true],
            ]],
            ["c": "Checklist", "items": "$reminders.open"],
        ]])
        #expect(spec.action("t0.2") == .toggle(key: "todo", index: 2))
        #expect(spec.action("a1.0") == nil, "a link opens in place; it is not an action")
        #expect(spec.action("a1.1") == .prompt(title: "Ask", prompt: "Plan my day"))
        #expect(spec.action("a1.2") == .set(key: "walked", value: true))
        #expect(spec.action("t2.0") == nil, "reminder rows are named by reminder ID, not position")
        #expect(spec.action("r2.x-p.1A2B") == .completeReminder(id: "x-p.1A2B"))
        #expect(spec.action("r0.x-p.1A2B") == nil, "a $doc checklist has no reminders")
        #expect(spec.action("r1.x") == nil)
        #expect(spec.action("a5.0") == nil)
        #expect(spec.action("x") == nil)
        #expect(SurfaceAction.toggle(key: "todo", index: 2).json == ["kind": "toggle", "key": "todo", "index": 2])
        #expect(SurfaceAction.completeReminder(id: "abc").json == ["kind": "completeReminder", "id": "abc"])
    }
}
