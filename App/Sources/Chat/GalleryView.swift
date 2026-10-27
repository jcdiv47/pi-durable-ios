import PiUI
import SwiftUI

/// Every component in the catalog, drawn from its sample slot (the same samples the snapshot tests check).
struct GalleryView: View {
    var body: some View {
        List(Catalog.components, id: \.name) { component in
            NavigationLink(value: Route.component(component.name)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.name).font(.headline)
                    Text(component.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .navigationTitle("Components")
    }
}

/// One component in each family it supports, its props, and its sample slot.
struct ComponentDetailView: View {
    let store: ChatStore
    let name: String
    @State private var appearance = SurfaceAppearance.light
    @State private var liveData = false

    var body: some View {
        if let component = Catalog.component(name) {
            let families = SurfaceFamily.allCases.filter(component.families.contains)
            let spec = ComponentSamples.single(name, families: families.filter { $0 != .card }).map(SurfaceSpec.init)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(component.purpose).font(.callout)
                    Picker("Appearance", selection: $appearance) {
                        ForEach(SurfaceAppearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Your data", isOn: $liveData)
                        .font(.subheadline)
                    if let spec {
                        ForEach(families) { family in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(family.displayName).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(levelNote(family)).font(.caption2).foregroundStyle(.secondary)
                                }
                                FramedSurface(spec: spec, family: family, appearance: appearance, data: data)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    props(component)
                    if let slot = ComponentSamples.slot(name) {
                        DisclosureGroup("Sample slot") {
                            Text(String(decoding: slot.data(pretty: true), as: UTF8.self))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: liveData) {
                if liveData { Task { await store.refreshSurfaceData(force: true) } }
            }
        } else {
            ContentUnavailableView("No component \(name)", systemImage: "square.dashed")
        }
    }

    /// The sample's `$doc` values stay, since your Pi may have none of the same names.
    private var data: SurfaceData {
        let sample = ComponentSamples.data
        guard liveData else { return sample }
        return SurfaceData(native: store.surfaceData.native, doc: sample.doc.merging(store.surfaceData.doc) { $1 })
    }

    /// Whether the agent may use the component there at the current design level.
    private func levelNote(_ family: SurfaceFamily) -> String {
        let level = store.dial.level(family)
        if name == "Custom", level.customNodeBudget == 0 { return "Not at level \(level.rawValue)" }
        if level == .template, !(GenerativityDial.presets[family] ?? []).contains(where: { $0.contains(name) }) { return "In no level 0 preset" }
        return "Level \(level.rawValue) · \(level.name)"
    }

    @ViewBuilder private func props(_ component: ComponentDef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Props").font(.headline)
            ForEach(component.props, id: \.name) { prop in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(prop.name).font(.subheadline.monospaced().weight(prop.required ? .semibold : .regular))
                        if prop.required { Text("required").font(.caption2).foregroundStyle(.orange) }
                        if prop.bindable { Text("$ bindable").font(.caption2).foregroundStyle(.blue) }
                    }
                    Text(prop.type.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !prop.help.isEmpty { Text(prop.help).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
