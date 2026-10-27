import Foundation

/// One sample slot per catalog component, with sample data for its bindings (`components.json`). The component
/// gallery shows them, and the snapshot tests draw them, so the gallery is what the reference sheets check.
public enum ComponentSamples {
    static let file: JSONValue = {
        guard let url = Bundle.module.url(forResource: "components", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONValue(json: data)
        else { return [:] }
        return value
    }()

    /// Native and `$doc` values the sample slots bind, at a fixed morning.
    public static var data: SurfaceData {
        SurfaceData(
            native: file["native"]?.object ?? [:],
            doc: file["doc"]?.object ?? [:],
            now: file["now"]?.string.flatMap(DateParsing.parse) ?? .now
        )
    }

    /// The sample slot for `component`; nil for a component without one (the tests require one for each).
    public static func slot(_ component: String) -> JSONValue? { file["slots"]?[component] }

    /// A widget spec with the sample slot alone, in `families`.
    public static func single(_ component: String, families: [SurfaceFamily]) -> JSONValue? {
        guard let slot = slot(component) else { return nil }
        return ["schema": 1, "title": .string(component), "surface": "widget", "families": .array(families.map { .string($0.rawValue) }), "slots": [slot]]
    }
}
