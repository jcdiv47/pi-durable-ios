/// What `list_components` tells the model: the spec format, each family's slots and dial level, the
/// components, the primitives (where a level allows them) and the data sources. Generated from the catalog,
/// so the description and the validator cannot disagree.
public enum CatalogText {
    public static func describe(families requested: [SurfaceFamily], dial: GenerativityDial) -> String {
        let families = requested.isEmpty ? SurfaceFamily.allCases : requested
        var lines: [String] = []
        lines.append("""
        A spec is JSON: {"title": "…", "surface": "widget" | "card", "families": [widget families], "layout": "stack" | "row" | "split" | "grid", \
        "slots": [{"c": "<Component>", …props, "families"?: [limit this slot to some families]}], "tint"?: color, \
        "tapAction"?: {"open": "conversation"} | {"url": "…"}, "refresh"?: {"native": "30m"}}.
        A card ("surface": "card") shows in this chat and has no families. Each family shows, in order, the slots whose component supports it, up to its slot limit.
        Props take literals or "$source" bindings, which the widget resolves on its own (no model call). Props marked "literal" cannot be bound.
        """)
        lines.append("\nFamilies (slots, dial level):")
        for family in families {
            let level = dial.level(family)
            let slots = family.slotLimit.map { "\($0) slot\($0 == 1 ? "" : "s")" } ?? "any number of slots"
            lines.append("- \(family.rawValue) — \(family.displayName); \(slots); level \(level.rawValue) \(level.name): \(level.rule)")
            if level == .template, let presets = GenerativityDial.presets[family] {
                lines.append("  presets: \(presets.map { "[\($0.joined(separator: ", "))]" }.joined(separator: " "))")
            }
        }
        lines.append("\nComponents (* required):")
        let custom = families.contains { dial.level($0).customNodeBudget > 0 }
        for component in Catalog.components where component.name != "Custom" || custom {
            let supported = families.filter(component.families.contains)
            guard !supported.isEmpty else { continue }
            let scope = supported.count == families.count ? "" : " [\(supported.map(\.rawValue).joined(separator: ", "))]"
            lines.append("- \(component.name)\(scope): \(component.purpose)")
            lines.append("  " + component.props.map(describe).joined(separator: "; "))
        }
        if custom {
            lines.append("\nCustom tree nodes, {\"t\": type, …}; every node also takes \(Primitives.modifiers.map(\.name).joined(separator: ", ")):")
            for node in Primitives.nodes {
                let props = node.props.map(describe) + (node.hasChildren ? ["children* (array of nodes)"] : [])
                lines.append("- \(node.type): \(props.isEmpty ? "no props" : props.joined(separator: "; "))")
            }
        }
        lines.append("\nData sources:")
        for source in DataSources.sources {
            let permission = source.permission == .none ? "" : " (needs \(source.permission.rawValue) permission)"
            lines.append("- $\(source.name) (\(source.kind.rawValue)): \(source.help)\(permission)")
        }
        lines.append("- $doc.<key>: a value you stored with set_value; use it for text or numbers you compute (summaries, nudges, goals)")
        lines.append("Fields of an item source: $calendar.next.title, .subtitle, .date, .end.")
        lines.append("Colors: \(Palette.names.joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    static func describe(_ prop: PropDef) -> String {
        var text = "\(prop.name)\(prop.required ? "*" : "") (\(prop.type.summary)\(prop.bindable ? "" : ", literal"))"
        if !prop.help.isEmpty { text += " \(prop.help)" }
        return text
    }
}
