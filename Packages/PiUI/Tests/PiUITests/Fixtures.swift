import Foundation
@testable import PiUI

/// The checked-in sample specs (Tests/PiUITests/Fixtures), read in place, and the components' sample slots and data
/// (`ComponentSamples`, a PiUI resource the gallery shows too).
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static var data: SurfaceData { ComponentSamples.data }

    static func slot(_ component: String) -> JSONValue { ComponentSamples.slot(component)! }

    static func spec(_ name: String) -> JSONValue {
        try! JSONValue(json: Data(contentsOf: directory.appendingPathComponent("specs/\(name).json")))
    }

    static let specNames = ["morning", "week", "card"]

    /// A widget spec with one slot, shown in the given families.
    static func single(_ component: String, families: [SurfaceFamily]) -> JSONValue {
        ComponentSamples.single(component, families: families)!
    }

    /// Every level at its most permissive, so component fixtures validate in every family.
    static let openDial = GenerativityDial(levels: Dictionary(uniqueKeysWithValues: SurfaceFamily.allCases.map { ($0.rawValue, 3) }))
}
