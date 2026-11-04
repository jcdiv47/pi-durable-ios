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
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nothing published yet. Ask Pi to design a widget, then add the Pi widget to your Home Screen or Lock Screen and choose it in the widget's settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Design a Widget", systemImage: "square.and.pencil") {
                            Task { await store.compose("Make a Home Screen widget that shows ") }
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(store.published) { entry in
                    NavigationLink(value: Route.surface(entry.publishedId)) {
                        PublishedRow(entry: entry, store: store)
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
                NavigationLink(value: Route.gallery) { SettingsRow("Component Gallery", systemImage: "square.grid.3x3.fill", tint: .blue) }
                NavigationLink(value: Route.tuning) { SettingsRow("Design Tuning", systemImage: "slider.horizontal.3", tint: .gray) }
            } footer: {
                Text("Every component Pi can use, in each size, and what the log of Pi's designs says about the levels below.")
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

/// A published widget: how it looks (its first Home Screen size, drawn small), its title, and where it can go.
private struct PublishedRow: View {
    let entry: PublishedEntry
    let store: ChatStore
    @Environment(\.colorScheme) private var colorScheme

    private var families: [SurfaceFamily] { entry.families.compactMap(SurfaceFamily.init(rawValue:)) }

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.headline)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Version \(entry.version) · \(Date(timeIntervalSince1970: entry.publishedAt / 1000), format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// "Home Screen: small, medium · Lock Screen" rather than every family's full name.
    private var summary: String {
        let home = families.filter { !$0.isAccessory && $0 != .card }.map { $0.displayName.replacingOccurrences(of: "Home Screen ", with: "") }
        var parts: [String] = []
        if !home.isEmpty { parts.append("Home Screen: \(home.joined(separator: ", "))") }
        if families.contains(where: \.isAccessory) { parts.append("Lock Screen") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var thumbnail: some View {
        let height: CGFloat = 64
        if let family = families.first(where: { !$0.isAccessory && $0 != .card }), let surface = SurfaceStore.shared?.surface(entry.publishedId) {
            let size = family.size
            let scale = height / size.height
            FramedSurface(spec: surface.parsed, family: family, appearance: colorScheme == .dark ? .dark : .light, data: store.surfaceData)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: height, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            SettingsIcon(systemImage: "lock.rectangle", tint: .indigo, size: 44)
        }
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
