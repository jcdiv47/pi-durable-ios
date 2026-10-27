import PiUI
import SwiftUI

/// The tuning loop of the generativity dial (spec): what the log of validations and publishes says per family,
/// which Custom layouts repeat (candidates for components or presets) and which errors recur, with each family's
/// level next to its numbers so a suggestion can be acted on here.
struct TuningView: View {
    @Bindable var store: ChatStore
    @State private var summary: TuningSummary?
    @State private var confirmClear = false

    var body: some View {
        Form {
            if let summary {
                if summary.events == 0 {
                    Text("Nothing logged yet. Every design Pi checks (create_surface, patch_surface, validate_surface) and every publish is logged here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    overview(summary)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Design Tuning")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: TuningLog.shared.export(), preview: SharePreview("Pi tuning log")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Button("Clear", systemImage: "trash", role: .destructive) { confirmClear = true }
                    .disabled(summary?.events ?? 0 == 0)
            }
        }
        .confirmationDialog("Clear the tuning log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                TuningLog.shared.clear()
                reload()
            }
        }
        .task { reload() }
        .refreshable { reload() }
        .onChange(of: store.dial) { reload() }
    }

    private func reload() {
        summary = TuningSummary(TuningLog.shared.read(), dial: store.dial)
    }

    @ViewBuilder private func overview(_ summary: TuningSummary) -> some View {
        Section {
            if summary.suggestions.isEmpty {
                Text("No suggestions: no family fails often, and no Custom layout repeats yet.").foregroundStyle(.secondary)
            }
            ForEach(summary.suggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "lightbulb").font(.callout)
            }
        } header: {
            Text("Suggestions")
        } footer: {
            if let since = summary.since {
                Text("\(summary.events) events since \(since.formatted(date: .abbreviated, time: .shortened)).")
            }
        }

        Section {
            ForEach(summary.families) { stats in
                VStack(alignment: .leading, spacing: 6) {
                    Picker(stats.family.displayName, selection: Binding(get: { store.dial.level(stats.family) }, set: { store.dial.set($0, for: stats.family) })) {
                        ForEach(DialLevel.allCases, id: \.self) { level in Text("\(level.rawValue) · \(level.name)").tag(level) }
                    }
                    Text(numbers(stats)).font(.caption.monospacedDigit()).foregroundStyle(stats.failingOften ? .orange : .secondary)
                }
            }
        } header: {
            Text("Families")
        } footer: {
            Text("Numbers count designs made at each family's current level; changing a level starts its count again.")
        }

        if !summary.shapes.isEmpty {
            Section {
                ForEach(summary.shapes.prefix(20)) { shape in
                    DisclosureGroup {
                        CustomPreview(tree: shape.example)
                        Text(shape.example).font(.caption2.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shape.signature).font(.caption.monospaced())
                            Text("\(shape.count)× · \(shape.families.sorted().joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Custom layouts")
            } footer: {
                Text("Grouped by shape: node types and nesting, not text or values. A shape that keeps coming back is a candidate for a component or a preset.")
            }
        }

        if !summary.failures.isEmpty {
            Section("Recurring errors") {
                ForEach(summary.failures.prefix(30)) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.pattern).font(.caption)
                        Text("\(failure.count)×").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func numbers(_ stats: TuningSummary.FamilyStats) -> String {
        var parts = ["\(stats.validations) checked", "\(stats.failures) failed (\(Int((stats.failureRate * 100).rounded()))%)"]
        if stats.custom > 0 { parts.append("\(stats.custom) with Custom") }
        if stats.customRejected > 0 { parts.append("\(stats.customRejected) Custom refused") }
        parts.append("\(stats.publishes) published")
        return parts.joined(separator: " · ")
    }
}

/// A logged Custom tree, drawn as a chat card.
private struct CustomPreview: View {
    let tree: String

    var body: some View {
        if let data = tree.data(using: .utf8), let node = try? JSONValue(json: data) {
            let spec = SurfaceSpec(["surface": "card", "families": ["card"], "slots": [["c": "Custom", "tree": node]]])
            FramedSurface(spec: spec, family: .card, appearance: .light, data: ComponentSamples.data)
                .frame(maxWidth: .infinity)
        }
    }
}
