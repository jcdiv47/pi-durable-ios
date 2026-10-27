import SwiftUI
import WidgetKit

/// Draws a spec in one family. Shared by the widget, chat cards and `ImageRenderer` previews; it never
/// depends on the dial, so a spec looks the same wherever it was validated.
public struct SurfaceView: View {
    let spec: SurfaceSpec
    let data: SurfaceData
    let environment: SurfaceEnvironment

    public init(spec: SurfaceSpec, family: SurfaceFamily, data: SurfaceData, tinted: Bool = false, inWidget: Bool = false) {
        self.spec = spec
        self.data = data
        environment = SurfaceEnvironment(family: family, tinted: tinted, inWidget: inWidget, tint: spec.tint)
    }

    public var body: some View {
        let slots = spec.visibleSlots(environment.family)
        content(slots)
            .environment(\.surface, environment)
            .environment(\.surfaceData, data)
    }

    @ViewBuilder private func content(_ slots: [SurfaceSpec.Slot]) -> some View {
        switch environment.family {
        case .accessoryInline, .accessoryCircular:
            if let slot = slots.first { SlotView(slot: slot) } else { EmptySurface() }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in SlotView(slot: slot) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .card:
            if slots.isEmpty { EmptySurface() } else { SlotLayout(slots: slots, layout: spec.layout ?? "stack", fill: false) }
        case .systemSmall, .systemMedium, .systemLarge:
            if slots.isEmpty {
                EmptySurface()
            } else {
                SlotLayout(slots: slots, layout: spec.layout ?? (environment.family == .systemMedium && slots.count > 1 ? "split" : "stack"), fill: true)
            }
        }
    }
}

/// The surface's background: the widget passes it to `containerBackground`; previews and cards draw it.
public struct SurfaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        colorScheme == .dark ? Color(white: 0.11) : Color.white
    }
}

struct EmptySurface: View {
    @Environment(\.surface) private var surface

    var body: some View {
        if surface.family == .accessoryInline {
            Label("Pi", systemImage: "sparkle")
        } else {
            VStack(spacing: 4) {
                Image(systemName: "sparkle").font(.title3)
                if !surface.family.isAccessory {
                    Text("Nothing to show here").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SlotLayout: View {
    let slots: [SurfaceSpec.Slot]
    let layout: String
    /// Fill the family's fixed height (widgets) or size to content (cards).
    let fill: Bool

    var body: some View {
        switch layout {
        case "row":
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    SlotView(slot: slot).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
                }
            }
        case "split" where slots.count > 1:
            HStack(alignment: .top, spacing: 14) {
                SlotView(slot: slots[0]).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(slots.dropFirst().enumerated()), id: \.offset) { _, slot in SlotView(slot: slot) }
                    if fill { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            }
        case "grid":
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: slots.count, by: 2)), id: \.self) { index in
                    GridRow {
                        SlotView(slot: slots[index]).frame(maxWidth: .infinity, alignment: .topLeading)
                        if index + 1 < slots.count {
                            SlotView(slot: slots[index + 1]).frame(maxWidth: .infinity, alignment: .topLeading)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        default:
            if fill, slots.count == 1 {
                SlotView(slot: slots[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.slotFills, true)
            } else {
                stack
            }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    SlotView(slot: slot).frame(maxWidth: .infinity, alignment: .leading)
                }
            if fill { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
    }
}

/// One slot: its component, adapted to the family in the environment.
struct SlotView: View {
    let slot: SurfaceSpec.Slot
    @Environment(\.surfaceData) private var data

    var body: some View {
        let reader = SlotReader(slot: slot, data: data)
        switch slot.component {
        case "MetricTile": MetricTileView(r: reader)
        case "Ring": RingView(r: reader)
        case "Sparkline": SparklineView(r: reader)
        case "BarStrip": BarStripView(r: reader)
        case "NextUp": NextUpView(r: reader)
        case "Countdown": CountdownView(r: reader)
        case "Checklist": ChecklistView(r: reader)
        case "Timeline": TimelineListView(r: reader)
        case "Quote": QuoteView(r: reader)
        case "StatGrid": StatGridView(r: reader)
        case "Header": HeaderView(r: reader)
        case "Badge": BadgeView(r: reader)
        case "ActionRow": ActionRowView(r: reader)
        case "ImageCard": ImageCardView(r: reader)
        case "Custom": if let tree = slot["tree"] { NodeView(node: tree) }
        default: EmptyView()
        }
    }
}

/// Typed reads of a slot's props through the data.
struct SlotReader {
    let slot: SurfaceSpec.Slot
    let data: SurfaceData

    func text(_ key: String) -> String? { data.text(slot[key]) }
    func number(_ key: String) -> Double? { data.number(slot[key]) }
    func date(_ key: String) -> Date? { data.date(slot[key]) }
    func bool(_ key: String) -> Bool? { data.bool(slot[key]) }
    func series(_ key: String) -> (values: [Double], labels: [String]) { data.series(slot[key]) }
    func items(_ key: String) -> [SurfaceItem] { data.items(slot[key]) }
    /// A literal option (`trend`, `style`, symbols): never bound.
    func literal(_ key: String) -> String? { slot[key]?.string }
    func int(_ key: String) -> Int? { slot[key]?.number.map { Int($0) } }
}

extension View {
    /// The component's color, or the system tint when the Lock Screen draws in one color.
    @ViewBuilder func surfaceTint(_ color: Color, _ environment: SurfaceEnvironment) -> some View {
        if environment.tinted {
            foregroundStyle(.primary).widgetAccentable()
        } else {
            foregroundStyle(color)
        }
    }
}

extension SurfaceEnvironment {
    func tint(_ slotTint: String?, default fallback: Color) -> Color {
        tinted ? .primary : Palette.color(slotTint ?? tint, default: fallback)
    }
}
