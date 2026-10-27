import Foundation
@testable import PiUI

/// The checked-in sample slots, specs and data (Tests/PiUITests/Fixtures), read in place.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static let components: JSONValue = try! JSONValue(json: Data(contentsOf: directory.appendingPathComponent("components.json")))

    static var data: SurfaceData {
        SurfaceData(
            native: components["native"]?.object ?? [:],
            doc: components["doc"]?.object ?? [:],
            now: DateParsing.parse(components["now"]!.string!)!
        )
    }

    static func slot(_ component: String) -> JSONValue { components["slots"]![component]! }

    static func spec(_ name: String) -> JSONValue {
        try! JSONValue(json: Data(contentsOf: directory.appendingPathComponent("specs/\(name).json")))
    }

    static let specNames = ["morning", "week", "card"]

    /// A widget spec with one slot, shown in the given families.
    static func single(_ component: String, families: [SurfaceFamily]) -> JSONValue {
        ["schema": 1, "title": .string(component), "surface": "widget", "families": .array(families.map { .string($0.rawValue) }), "slots": [slot(component)]]
    }

    /// Every level at its most permissive, so component fixtures validate in every family.
    static let openDial = GenerativityDial(levels: Dictionary(uniqueKeysWithValues: SurfaceFamily.allCases.map { ($0.rawValue, 3) }))
}
