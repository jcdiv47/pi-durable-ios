import Foundation

/// Answers the JS UI tools (`js/src/app/surfaces.ts`): one handler per `hostCall` name, JSON in and out. The
/// catalog, validator and renderer live only here, so the model's instructions, the checks and the widget
/// cannot drift apart. Specs themselves live in Pi documents; this host only checks, draws and exports them.
public final class SurfaceHost: Sendable {
    public typealias Tuning = @Sendable (TuningEvent) -> Void

    let store: SurfaceStore?
    let native: NativeData
    let dial: @Sendable () -> GenerativityDial
    let reload: @Sendable () -> Void
    let tuning: Tuning

    /// - Parameters:
    ///   - dial: read on every call, so Settings changes apply to the next tool call.
    ///   - tuning: the tuning log (spec "Generativity dial"): every validation, with its errors and Custom trees, and
    ///     every publish.
    public init(
        store: SurfaceStore? = .shared,
        native: NativeData = NativeData(),
        dial: @escaping @Sendable () -> GenerativityDial = { GenerativityDial() },
        reload: @escaping @Sendable () -> Void = SurfaceStore.reloadWidgets,
        tuning: @escaping Tuning = { _ in }
    ) {
        self.store = store
        self.native = native
        self.dial = dial
        self.reload = reload
        self.tuning = tuning
    }

    public static let handlers: Set<String> = ["ui.catalog", "ui.validate", "ui.preview", "ui.publish", "ui.unpublish", "ui.values", "ui.source"]

    public func handle(_ name: String, _ json: String) async throws -> String {
        let args = try JSONValue(json: json)
        let result: JSONValue
        switch name {
        case "ui.catalog": result = catalog(args)
        case "ui.validate": result = try encode(validate(args["spec"] ?? .null, docKeys: args["docKeys"]))
        case "ui.preview": result = try await preview(args)
        case "ui.publish": result = try publish(args)
        case "ui.unpublish": result = try unpublish(args)
        case "ui.values": result = try values(args)
        case "ui.source": result = try await source(args)
        default: throw SurfaceHostError("No UI handler named \(name)")
        }
        return result.jsonText
    }

    func catalog(_ args: JSONValue) -> JSONValue {
        let families = (args["families"]?.array ?? []).compactMap { $0.string.flatMap(SurfaceFamily.init(rawValue:)) }
        let dial = dial()
        return [
            "text": .string(CatalogText.describe(families: families, dial: dial)),
            "dial": .object(dial.record(SurfaceFamily.allCases).mapValues { .number(Double($0)) }),
        ]
    }

    func validate(_ spec: JSONValue, docKeys: JSONValue?) -> ValidationReport {
        let keys = docKeys?.array.map { Set($0.compactMap(\.string)) }
        let dial = dial()
        let report = SurfaceValidator(dial: dial, docKeys: keys).validate(spec)
        let parsed = SurfaceSpec(spec)
        let custom = parsed.families.filter { parsed.visibleSlots($0).contains { $0.component == "Custom" } }
        tuning(TuningEvent(
            kind: .validated, families: parsed.families.map(\.rawValue), levels: dial.record(parsed.families),
            errors: report.errors.map { "\($0.path): \($0.message)" }, customTrees: report.customTrees, customFamilies: custom.map(\.rawValue)
        ))
        return report
    }

    func preview(_ args: JSONValue) async throws -> JSONValue {
        guard let raw = args["spec"] else { throw SurfaceHostError("preview needs a spec") }
        let spec = SurfaceSpec(raw)
        let report = SurfaceValidator(dial: dial()).validate(raw)
        var families = (args["families"]?.array ?? []).compactMap { $0.string.flatMap(SurfaceFamily.init(rawValue:)) }.filter(spec.families.contains)
        if families.isEmpty { families = spec.families }
        var appearances = (args["appearances"]?.array ?? []).compactMap { $0.string.flatMap(SurfaceAppearance.init(rawValue:)) }
        if appearances.isEmpty { appearances = [.light] }
        let data = SurfaceData(native: await native.read(Set(report.sources)), doc: args["doc"]?.object ?? [:])
        let missing = report.sources.filter { data.resolve(.string("$\($0)")) == nil }

        let render = args["images"]?.bool ?? true
        var images: [JSONValue] = []
        var warnings: [JSONValue] = []
        for family in families {
            // The Lock Screen draws accessories one way only, so one image each.
            for appearance in render ? (family.isAccessory ? [.tinted] : appearances) : [] {
                let image = await MainActor.run { SurfacePreview.png(spec, family: family, appearance: appearance, data: data) }
                guard let image else { continue }
                images.append([
                    "family": .string(family.rawValue), "appearance": .string(appearance.rawValue),
                    "png": .string(image.png.base64EncodedString()), "width": .number(Double(image.width)), "height": .number(Double(image.height)),
                ])
            }
            let layout = await MainActor.run { SurfacePreview.layoutWarnings(spec, family: family, data: data) }
            warnings.append(contentsOf: layout.map(JSONValue.string))
        }
        return [
            "images": .array(images),
            "warnings": .array(warnings),
            "missing": .array(missing.map(JSONValue.string)),
            "errors": .array(report.errors.map { .string("\($0.path): \($0.message)") }),
        ]
    }

    func publish(_ args: JSONValue) throws -> JSONValue {
        guard let store else { throw SurfaceHostError("The App Group container is unavailable, so widgets cannot read surfaces") }
        guard let spec = args["spec"], let publishedId = args["publishedId"]?.string, let surfaceId = args["surfaceId"]?.string,
              let conversationId = args["conversationId"]?.number, let version = args["version"]?.number
        else { throw SurfaceHostError("publish needs publishedId, surfaceId, conversationId, version and spec") }
        let report = SurfaceValidator(dial: dial()).validate(spec)
        guard report.valid else {
            throw SurfaceHostError("The spec is invalid: \(report.errors.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
        }
        let parsed = SurfaceSpec(spec)
        try store.publish(PublishedSurface(
            publishedId: publishedId, conversationId: Int(conversationId), surfaceId: surfaceId, version: Int(version),
            publishedAt: .now, dial: dial().record(parsed.families), spec: spec
        ))
        reload()
        tuning(TuningEvent(kind: .published, families: parsed.families.map(\.rawValue), levels: dial().record(parsed.families), detail: "\(publishedId) v\(Int(version))"))
        return ["publishedId": .string(publishedId), "families": .array(parsed.families.map { .string($0.rawValue) })]
    }

    func unpublish(_ args: JSONValue) throws -> JSONValue {
        guard let store, let publishedId = args["publishedId"]?.string else { throw SurfaceHostError("unpublish needs publishedId") }
        try store.unpublish(publishedId)
        reload()
        return ["removed": true]
    }

    func values(_ args: JSONValue) throws -> JSONValue {
        guard let store else { throw SurfaceHostError("The App Group container is unavailable") }
        try store.writeValues(args["values"]?.object ?? [:])
        reload()
        return ["written": true]
    }

    func source(_ args: JSONValue) async throws -> JSONValue {
        guard let text = args["source"]?.string, let binding = DataSources.binding(text.hasPrefix("$") ? text : "$\(text)") else {
            throw SurfaceHostError("source must look like $health.stepsToday")
        }
        if binding.isDoc { return ["exists": true, "kind": "any", "permission": "none", "authorization": "notApplicable"] }
        guard let source = DataSources.source(binding.source) else {
            return ["exists": false, "known": .array(DataSources.sources.map { .string("$\($0.name)") })]
        }
        let authorization = await native.authorize(source)
        let value = await native.read([source.name])[source.name]
        return [
            "exists": true, "kind": .string(source.kind.rawValue), "permission": .string(source.permission.rawValue),
            "authorization": .string(authorization.rawValue), "value": value ?? .null,
        ]
    }

    private func encode(_ value: some Encodable) throws -> JSONValue {
        try JSONValue(json: JSONEncoder().encode(value))
    }
}

public struct SurfaceHostError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
