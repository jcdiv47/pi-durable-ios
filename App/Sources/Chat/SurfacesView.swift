import PiUI
import SwiftUI

/// Surfaces on the Home Screen and Lock Screen, and the generativity dial (a debug setting).
struct SurfacesView: View {
    @Bindable var store: ChatStore
    @Binding var path: [Route]

    var body: some View {
        Form {
            Section {
                if store.published.isEmpty {
                    Text("Nothing published yet. Ask Pi to design a widget, then add the Pi widget to your Home Screen or Lock Screen and choose it in the widget's settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.published) { entry in
                    NavigationLink(value: Route.surface(entry.publishedId)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.headline)
                            Text(entry.families.compactMap(SurfaceFamily.init(rawValue:)).map(\.displayName).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Version \(entry.version) · \(Date(timeIntervalSince1970: entry.publishedAt / 1000), format: .relative(presentation: .named))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "rectangle.badge.minus", role: .destructive) {
                            Task { await store.unpublish(entry.publishedId) }
                        }
                    }
                }
            } header: {
                Text("Published")
            }

            Section {
                ForEach(SurfaceFamily.allCases) { family in
                    Picker(selection: Binding(get: { store.dial.level(family) }, set: { store.dial.set($0, for: family) })) {
                        ForEach(DialLevel.allCases, id: \.self) { level in
                            Text("\(level.rawValue) · \(level.name)").tag(level)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(family.displayName)
                            if store.dial.level(family) != GenerativityDial.defaults[family] {
                                Text("Default \(GenerativityDial.defaults[family]?.name ?? "")").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Button("Reset to defaults") { store.dial = GenerativityDial() }
                    .disabled(store.dial == GenerativityDial())
            } header: {
                Text("Design level (debug)")
            } footer: {
                Text("How freely Pi designs each surface: 0 picks a preset, 1 arranges components, 2 adds small custom layouts, 3 builds custom layouts. Applies from the next tool call; published widgets keep their design.")
            }
        }
        .navigationTitle("Widgets")
        .task { await store.refreshPublished() }
        .refreshable { await store.refreshPublished() }
    }
}

/// One published surface as each of its families shows it, in light, dark and tinted.
struct SurfaceDetailView: View {
    let store: ChatStore
    let publishedId: String
    @Binding var path: [Route]
    @State private var appearance = SurfaceAppearance.light
    @State private var surface: PublishedSurface?

    var body: some View {
        ScrollView {
            if let surface {
                let spec = surface.parsed
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(SurfaceAppearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(spec.families) { family in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(family.displayName).font(.subheadline.weight(.semibold))
                            FramedSurface(spec: spec, family: family, appearance: appearance, data: store.surfaceData)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Button("Open the conversation", systemImage: "bubble.left") {
                        path.append(.conversation(surface.conversationId))
                    }
                    Button("Remove from widgets", systemImage: "rectangle.badge.minus", role: .destructive) {
                        Task {
                            await store.unpublish(publishedId)
                            path.removeLast()
                        }
                    }
                    DisclosureGroup("Spec (version \(surface.version))") {
                        Text(String(decoding: surface.spec.data(pretty: true), as: UTF8.self))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("Not published", systemImage: "rectangle.dashed")
            }
        }
        .navigationTitle(surface?.parsed.title ?? "Widget")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            surface = SurfaceStore.shared?.surface(publishedId)
            await store.refreshSurfaceData(force: true)
        }
    }
}
