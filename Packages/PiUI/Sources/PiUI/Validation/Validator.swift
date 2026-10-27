import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One problem, at a JSON Pointer into the spec (`/slots/1/goal`), worded for the model to fix.
public struct ValidationIssue: Codable, Sendable, Hashable {
    public let path: String
    public let message: String
}

public struct ValidationReport: Codable, Sendable, Hashable {
    public var errors: [ValidationIssue] = []
    public var warnings: [ValidationIssue] = []
    /// Data sources the spec binds, e.g. `health.stepsToday`, `doc.nudge`.
    public var sources: [String] = []
    /// Permissions the bound sources need (`health`, `calendar`, `reminders`).
    public var permissions: [String] = []
    /// `Custom` trees as JSON, for the tuning log.
    public var customTrees: [String] = []

    public var valid: Bool { errors.isEmpty }
}

/// Checks a spec against the catalog, the families' slot limits and the dial. Errors make a spec unpublishable;
/// warnings point at likely layout trouble (truncation, dropped slots).
public struct SurfaceValidator: Sendable {
    public var dial: GenerativityDial
    /// Keys `set_value` has stored; a `$doc` binding to any other key warns. nil skips the check.
    public var docKeys: Set<String>?
    public var symbolExists: @Sendable (String) -> Bool

    public init(dial: GenerativityDial = .init(), docKeys: Set<String>? = nil, symbolExists: @escaping @Sendable (String) -> Bool = SurfaceValidator.systemSymbolExists) {
        self.dial = dial
        self.docKeys = docKeys
        self.symbolExists = symbolExists
    }

    public static let systemSymbolExists: @Sendable (String) -> Bool = { name in
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        true
        #endif
    }

    static let topLevelKeys: Set<String> = ["schema", "id", "title", "surface", "families", "layout", "slots", "tint", "tapAction", "refresh"]

    public func validate(_ spec: JSONValue) -> ValidationReport {
        var run = Run(validator: self)
        run.check(spec)
        var report = run.report
        report.sources = Array(Set(report.sources)).sorted()
        report.permissions = Array(Set(report.permissions)).sorted()
        return report
    }

    struct Run {
        let validator: SurfaceValidator
        var report = ValidationReport()

        mutating func error(_ path: String, _ message: String) { report.errors.append(.init(path: path, message: message)) }
        mutating func warn(_ path: String, _ message: String) { report.warnings.append(.init(path: path, message: message)) }

        mutating func check(_ spec: JSONValue) {
            guard let fields = spec.object else { return error("", "The spec must be a JSON object, got \(spec.typeName)") }
            for key in fields.keys.sorted() where !SurfaceValidator.topLevelKeys.contains(key) {
                warn("/\(key)", "Unknown key \(key) is ignored. Spec keys: \(SurfaceValidator.topLevelKeys.sorted().joined(separator: ", "))")
            }
            if let schema = fields["schema"], schema.number != Double(SurfaceSpec.schemaVersion) {
                error("/schema", "schema must be \(SurfaceSpec.schemaVersion)")
            }
            if let title = fields["title"] {
                if let text = title.string { if text.count > 40 { warn("/title", "Keep the title under 40 characters; the widget picker truncates it") } }
                else { error("/title", "title must be a string") }
            }
            let surface = fields["surface"]?.string ?? "widget"
            if surface != "widget", surface != "card" { error("/surface", "surface must be \"widget\" or \"card\"") }
            let families = checkFamilies(fields["families"], card: surface == "card")
            if let layout = fields["layout"], !(layout.string.map(Catalog.layouts.contains) ?? false) {
                error("/layout", "layout must be one of \(Catalog.layouts.joined(separator: ", "))")
            }
            if let tint = fields["tint"] { checkLiteral(tint, .color, path: "/tint") }
            if let tap = fields["tapAction"] { checkTap(tap) }
            if let refresh = fields["refresh"] { checkRefresh(refresh) }

            guard let slots = fields["slots"]?.array, !slots.isEmpty else {
                return error("/slots", "slots must be a non-empty array of components, e.g. [{\"c\": \"MetricTile\", \"value\": \"$health.stepsToday\", \"label\": \"Steps\"}]")
            }
            for (index, slot) in slots.enumerated() { checkSlot(slot, path: "/slots/\(index)", families: families) }
            guard report.errors.isEmpty else { return }
            let parsed = SurfaceSpec(spec)
            for family in families { checkFamily(family, parsed) }
        }

        mutating func checkFamilies(_ value: JSONValue?, card: Bool) -> [SurfaceFamily] {
            if card {
                if value != nil { warn("/families", "A card has no families; it is sized to the chat") }
                return [.card]
            }
            let names = SurfaceFamily.widgetFamilies.map(\.rawValue).joined(separator: ", ")
            guard let list = value?.array, !list.isEmpty else {
                error("/families", "A widget needs families: one or more of \(names)")
                return []
            }
            var families: [SurfaceFamily] = []
            for (index, item) in list.enumerated() {
                guard let family = item.string.flatMap(SurfaceFamily.init(rawValue:)), family != .card else {
                    error("/families/\(index)", "Unknown family \(item.display). Families: \(names)")
                    continue
                }
                if families.contains(family) { warn("/families/\(index)", "\(family.rawValue) is listed twice") }
                else { families.append(family) }
            }
            return families
        }

        mutating func checkTap(_ tap: JSONValue) {
            guard let fields = tap.object, fields.count == 1 else {
                return error("/tapAction", "tapAction is {\"url\": \"https://…\"} or {\"open\": \"conversation\"}")
            }
            if let open = fields["open"] {
                if open.string != "conversation" { error("/tapAction/open", "open must be \"conversation\"") }
            } else if let url = fields["url"] {
                checkLiteral(url, .url, path: "/tapAction/url")
            } else {
                error("/tapAction", "tapAction is {\"url\": \"https://…\"} or {\"open\": \"conversation\"}")
            }
        }

        mutating func checkRefresh(_ refresh: JSONValue) {
            guard let fields = refresh.object else { return error("/refresh", "refresh is {\"native\": \"30m\"}") }
            if let native = fields["native"], SurfaceSpec.minutes(native.string) == nil {
                error("/refresh/native", "native is a duration like \"15m\" or \"2h\" (at least 5 minutes)")
            }
            if fields["agent"] != nil {
                warn("/refresh/agent", "refresh.agent is not read; to refresh $doc values on a timetable, call schedule_task with a prompt that calls set_value")
            }
        }

        mutating func checkSlot(_ slot: JSONValue, path: String, families: [SurfaceFamily]) {
            guard var props = slot.object else { return error(path, "A slot is a component object like {\"c\": \"Ring\", …}, got \(slot.typeName)") }
            let names = Catalog.components.map(\.name).joined(separator: ", ")
            guard let name = props.removeValue(forKey: "c")?.string else { return error("\(path)/c", "Each slot needs \"c\": the component name (\(names))") }
            guard let component = Catalog.component(name) else { return error("\(path)/c", "Unknown component \(name). Components: \(names)") }
            if let only = props.removeValue(forKey: "families") {
                let list = only.array?.compactMap { $0.string.flatMap(SurfaceFamily.init(rawValue:)) } ?? []
                if list.isEmpty || list.count != only.array?.count {
                    error("\(path)/families", "A slot's families is a non-empty list of the spec's families")
                } else {
                    for family in list where !families.contains(family) {
                        warn("\(path)/families", "\(family.rawValue) is not one of the spec's families")
                    }
                    for family in list where !component.families.contains(family) {
                        error("\(path)/families", "\(name) does not support \(family.rawValue); it supports \(sortedNames(component.families))")
                    }
                }
            }
            for def in component.props where def.required && props[def.name] == nil {
                error("\(path)/\(def.name)", "\(name) needs \(def.name) (\(def.type.summary))")
            }
            for key in props.keys.sorted() {
                guard let def = component.prop(key) else {
                    error("\(path)/\(key)", "\(name) has no prop \(key). Its props: \(component.props.map(\.name).joined(separator: ", "))")
                    continue
                }
                checkValue(props[key]!, def, path: "\(path)/\(key)")
            }
            if name == "Ring", let goal = props["goal"]?.number, goal <= 0 { error("\(path)/goal", "goal must be greater than 0") }
            if name == "ActionRow" { checkActions(props["actions"]?.array ?? [], path: "\(path)/actions") }
            if name == "Custom", let tree = props["tree"] { report.customTrees.append(tree.jsonText) }
        }

        /// Each button does exactly one thing.
        mutating func checkActions(_ actions: [JSONValue], path: String) {
            for (index, action) in actions.enumerated() {
                let effects = ["url", "prompt", "set"].filter { action[$0] != nil }
                if effects.count != 1 {
                    error("\(path)/\(index)", "A button needs exactly one of url, prompt or set, got \(effects.isEmpty ? "none" : effects.joined(separator: ", "))")
                }
                if let key = action["set"]?.string {
                    if key.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) == nil { error("\(path)/\(index)/set", "set is a $doc key: letters, digits and _") }
                    if action["value"] == nil { error("\(path)/\(index)/value", "A set button needs the value to store") }
                } else if action["value"] != nil {
                    warn("\(path)/\(index)/value", "value is only used by set buttons")
                }
            }
        }

        mutating func checkValue(_ value: JSONValue, _ def: PropDef, path: String) {
            if let text = value.string, let binding = DataSources.binding(text) {
                guard def.bindable else { return error(path, "\(def.name) takes a literal \(def.type.summary), not a data binding") }
                return checkBinding(binding, text: text, type: def.type, path: path)
            }
            checkLiteral(value, def.type, path: path)
        }

        mutating func checkBinding(_ binding: DataSources.Binding, text: String, type: PropType, path: String) {
            switch DataSources.kind(of: binding) {
            case let .failure(failure):
                error(path, failure.message)
            case let .success(kind):
                guard kind.fits(type) else {
                    return error(path, "\(text) is \(kind.rawValue == "item" ? "one item" : "a \(kind.rawValue)"), but this prop takes \(type.summary)")
                }
                report.sources.append(binding.source)
                if binding.isDoc {
                    let key = String(binding.source.dropFirst(4))
                    if let keys = validator.docKeys, !keys.contains(key) {
                        warn(path, "No value is stored under \(key) yet; set it with set_value or the widget shows a placeholder")
                    }
                } else if let permission = DataSources.source(binding.source)?.permission, permission != .none {
                    report.permissions.append(permission.rawValue)
                }
            }
        }

        mutating func checkLiteral(_ value: JSONValue, _ type: PropType, path: String) {
            switch type {
            case .number:
                if value.number == nil { error(path, "Expected a number, got \(value.typeName)") }
            case .string:
                if value.string == nil, value.number == nil { error(path, "Expected a string, got \(value.typeName)") }
            case .text:
                if value.string == nil, value.number == nil { error(path, "Expected a number or a string, got \(value.typeName)") }
            case .bool:
                if value.bool == nil { error(path, "Expected true or false, got \(value.typeName)") }
            case .date:
                if value.string.flatMap(DateParsing.parse) == nil { error(path, "Expected an ISO 8601 date-time with a UTC offset, e.g. 2026-10-27T09:30:00+08:00") }
            case .color:
                if let name = value.string {
                    if !Palette.names.contains(name) { error(path, "Unknown color \(name). Colors: \(Palette.names.joined(separator: ", "))") }
                } else {
                    error(path, "Expected a color name")
                }
            case .symbol:
                if let name = value.string {
                    if !validator.symbolExists(name) { error(path, "\(name) is not an SF Symbol on this iPhone; try a common one like \"star.fill\"") }
                } else {
                    error(path, "Expected an SF Symbol name")
                }
            case .url:
                if value.string.flatMap(URL.init(string:))?.scheme == nil { error(path, "Expected an absolute URL") }
            case let .oneOf(options):
                if !(value.string.map(options.contains) ?? false) { error(path, "Expected one of \(options.joined(separator: ", "))") }
            case .series:
                let values = value.array ?? value["values"]?.array
                if values == nil || values!.contains(where: { $0.number == nil }) {
                    error(path, "Expected an array of numbers, or {\"values\": [numbers], \"labels\": [strings]}")
                } else if values!.count < 2 {
                    warn(path, "A series needs at least 2 values to draw")
                }
            case .items:
                guard let items = value.array else { return error(path, "Expected an array of {title, subtitle?, date?, done?}") }
                for (index, item) in items.enumerated() {
                    guard let fields = item.object, fields["title"]?.string != nil else {
                        error("\(path)/\(index)", "Each item needs a title")
                        continue
                    }
                    if let date = fields["date"], date.string.flatMap(DateParsing.parse) == nil { error("\(path)/\(index)/date", "Expected an ISO 8601 date-time") }
                }
            case .stringList:
                if value.array?.allSatisfy({ $0.string != nil }) != true { error(path, "Expected an array of strings") }
            case let .list(fields, min, max):
                guard let items = value.array else { return error(path, "Expected an array of \(min)–\(max) objects") }
                if items.count < min || items.count > max { error(path, "Expected \(min)–\(max) entries, got \(items.count)") }
                for (index, item) in items.enumerated() {
                    guard let object = item.object else {
                        error("\(path)/\(index)", "Expected an object")
                        continue
                    }
                    for def in fields where def.required && object[def.name] == nil { error("\(path)/\(index)/\(def.name)", "Needs \(def.name)") }
                    for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                        guard let def = fields.first(where: { $0.name == key }) else {
                            error("\(path)/\(index)/\(key)", "Unknown field \(key); fields are \(fields.map(\.name).joined(separator: ", "))")
                            continue
                        }
                        checkValue(value, def, path: "\(path)/\(index)/\(key)")
                    }
                }
            case .node:
                _ = checkNode(value, path: path, depth: 0)
            case .json:
                break
            }
        }

        /// Returns the node count of the subtree.
        mutating func checkNode(_ node: JSONValue, path: String, depth: Int) -> Int {
            guard depth < 12 else {
                error(path, "Custom trees may nest at most 12 levels")
                return 1
            }
            let types = Primitives.nodes.map(\.type).joined(separator: ", ")
            guard var fields = node.object, let type = fields.removeValue(forKey: "t")?.string else {
                error(path, "A primitive node is {\"t\": type, …}; types: \(types)")
                return 1
            }
            guard let def = Primitives.node(type) else {
                error("\(path)/t", "Unknown primitive \(type). Types: \(types)")
                return 1
            }
            var count = 1
            let children = fields.removeValue(forKey: "children")
            if def.hasChildren {
                if let list = children?.array {
                    for (index, child) in list.enumerated() { count += checkNode(child, path: "\(path)/children/\(index)", depth: depth + 1) }
                } else {
                    error("\(path)/children", "\(type) needs children: an array of nodes")
                }
            } else if children != nil {
                error("\(path)/children", "\(type) has no children")
            }
            for prop in def.props where prop.required && fields[prop.name] == nil {
                error("\(path)/\(prop.name)", "\(type) needs \(prop.name) (\(prop.type.summary))")
            }
            for key in fields.keys.sorted() {
                guard let prop = def.props.first(where: { $0.name == key }) ?? Primitives.modifiers.first(where: { $0.name == key }) else {
                    let known = (def.props + Primitives.modifiers).map(\.name).joined(separator: ", ")
                    error("\(path)/\(key)", "\(type) has no prop \(key). Props: \(known)")
                    continue
                }
                checkValue(fields[key]!, prop, path: "\(path)/\(key)")
            }
            return count
        }

        mutating func checkFamily(_ family: SurfaceFamily, _ spec: SurfaceSpec) {
            let level = validator.dial.level(family)
            let visible = spec.visibleSlots(family)
            let name = family.rawValue
            let intended = spec.slots.enumerated().filter { $0.element.families?.contains(family) ?? true }
            for (index, slot) in intended where Catalog.component(slot.component)?.families.contains(family) == false {
                warn("/slots/\(index)", "\(slot.component) is skipped in \(name), which it does not support")
            }
            guard !visible.isEmpty else {
                return error("/families", "\(name) would show nothing: none of its slots support it. Add a slot for it, or drop the family")
            }
            if let limit = family.slotLimit {
                let fitting = intended.filter { Catalog.component($0.element.component)?.families.contains(family) == true }
                if fitting.count > limit {
                    let dropped = fitting.dropFirst(limit).map { "\($0.element.component) (/slots/\($0.offset))" }.joined(separator: ", ")
                    if spec.slots.count > limit, spec.families.count == 1 {
                        error("/slots", "\(name) allows \(limit) slot\(limit == 1 ? "" : "s"), got \(fitting.count)")
                    } else {
                        warn("/slots", "\(name) shows only its first \(limit) slot\(limit == 1 ? "" : "s"); it drops \(dropped). Limit slots to families with \"families\": [...]")
                    }
                }
            }
            switch level {
            case .template:
                let arrangement = visible.map(\.component)
                let presets = GenerativityDial.presets[family] ?? []
                if !presets.contains(arrangement) {
                    error("/slots", "\(name) is at level 0 (Template): its slots must be one of these presets, in order: \(presets.map { "[\($0.joined(separator: ", "))]" }.joined(separator: " ")). Got [\(arrangement.joined(separator: ", "))]")
                }
            case .compose, .composePlus, .freeform:
                break
            }
            for slot in visible where slot.component == "Custom" {
                let index = spec.slots.firstIndex(of: slot) ?? 0
                if level.customNodeBudget == 0 {
                    error("/slots/\(index)", "Custom is not allowed in \(name) at level \(level.rawValue) (\(level.name)); use components\(spec.families.count > 1 ? ", or limit the Custom slot to other families" : "")")
                } else if let tree = slot["tree"] {
                    var counter = Run(validator: validator)
                    let nodes = counter.checkNode(tree, path: "", depth: 0)
                    if nodes > level.customNodeBudget {
                        error("/slots/\(index)/tree", "This Custom tree has \(nodes) nodes; \(name) at level \(level.rawValue) (\(level.name)) allows \(level.customNodeBudget)")
                    }
                }
            }
            checkText(family, spec)
        }

        /// Literal text longer than the component's budget for the family likely truncates.
        mutating func checkText(_ family: SurfaceFamily, _ spec: SurfaceSpec) {
            for slot in spec.visibleSlots(family) {
                guard let component = Catalog.component(slot.component), let budget = component.textBudget[family] else { continue }
                let index = spec.slots.firstIndex(of: slot) ?? 0
                for key in ["text", "label", "title", "caption", "value"] {
                    guard let text = slot[key]?.string, DataSources.binding(text) == nil, text.count > budget else { continue }
                    warn("/slots/\(index)/\(key)", "\(text.count) characters will likely truncate in \(family.rawValue) (about \(budget) fit)")
                }
            }
        }

        func sortedNames(_ families: Set<SurfaceFamily>) -> String {
            SurfaceFamily.allCases.filter(families.contains).map(\.rawValue).joined(separator: ", ")
        }
    }
}

enum DateParsing {
    /// ISO 8601 with an offset or `Z`, with or without fractional seconds, or a bare `yyyy-MM-dd` (local midnight).
    static func parse(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = text.count == 19 ? "yyyy-MM-dd'T'HH:mm:ss" : text.count == 16 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return day.date(from: text)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
