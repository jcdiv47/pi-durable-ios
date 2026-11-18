import PiUI
import SwiftUI

/// Settings › Widgets › Chat Components: the tokens and the pieces the conversation is drawn with, on sample data, in
/// either appearance. Where to look after changing `PiDesign`.
struct ChatComponentsGallery: View {
    @State private var dark = false
    @State private var meter = 0.62
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Palette") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(Self.swatches, id: \.name) { swatch in
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: PiDesign.Radius.chip, style: .continuous)
                                    .fill(swatch.color)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: PiDesign.Radius.chip, style: .continuous)
                                            .strokeBorder(PiDesign.Palette.hairline, lineWidth: 1)
                                    }
                                    .frame(height: 44)
                                Text(swatch.name).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                section("Radii and elevation") {
                    HStack(spacing: 10) {
                        ForEach(Self.radii, id: \.name) { radius in
                            Text(radius.name)
                                .font(.caption2.monospaced())
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .piSurface(radius.name == "window" ? .raised : .card, radius: radius.value)
                        }
                    }
                }
                section("Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ToolStatus.allCases, id: \.self) { status in
                            HStack(spacing: 8) {
                                ToolStatusIcon(status: status)
                                Text(status.label).font(PiDesign.Typeface.label)
                            }
                        }
                    }
                }
                section("Shimmer") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "brain")
                            ShimmerText(text: "Thinking")
                        }
                        .font(PiDesign.Typeface.label)
                        .foregroundStyle(.secondary)
                        .piChip()
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            ShimmerText(text: "Working 12s · 3 steps")
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .font(PiDesign.Typeface.label)
                        .foregroundStyle(.secondary)
                        .piChip()
                        HStack(spacing: 8) {
                            Image(systemName: "hand.raised.fill").foregroundStyle(PiDesign.Palette.warning)
                            Text("Waiting for you")
                        }
                        .font(PiDesign.Typeface.label)
                        .piChip(tint: PiDesign.Palette.warning)
                    }
                }
                section("Tool chips") {
                    ToolChips(chips: [
                        ("1", "web_search", .done),
                        ("2", "web_fetch", .done),
                        ("3", "ssh_exec", .running),
                        ("4", "calendar_create_event", .waiting),
                        ("5", "health_query", .failed),
                    ])
                }
                section("Context cards") {
                    ContextCards(sources: Self.sources)
                }
                section("Diff") {
                    DiffView(Self.diff)
                }
                section("Records table") {
                    ToolOutputView(output: Self.records, isError: false)
                }
                section("Markdown") {
                    MarkdownText(source: Self.markdown)
                }
                section("Result card") {
                    ResultCardShell(source: "Sample", symbol: "sparkles", tint: .indigo, title: "A result card", subtitle: "Header, share, expand", share: "Sample") { _ in
                        Text("Apple tool results draw in this frame: Reminders, Calendar, Health, Location, Web and Photos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                section("Pi's card") {
                    // A card Pi designs (PiUI), drawn with the same tokens as the result card above.
                    FramedSurface(spec: Self.piCard, family: .card, appearance: dark ? .dark : .light, data: ComponentSamples.data, fill: true)
                }
                section("Context meter") {
                    VStack(alignment: .leading, spacing: 10) {
                        PiMeter(value: meter).frame(width: 120)
                        Slider(value: $meter, in: 0 ... 1)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Chat Components")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(dark ? "Light" : "Dark", systemImage: dark ? "sun.max" : "moon") { dark.toggle() }
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(dark ? Color.black : Color.white)
        .onAppear { dark = systemScheme == .dark }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).piKicker()
            content()
        }
    }

    // MARK: Samples

    private static let swatches: [(name: String, color: Color)] = [
        ("surface", PiDesign.Palette.surface),
        ("sunken", PiDesign.Palette.sunken),
        ("raised", PiDesign.Palette.raised),
        ("hairline", PiDesign.Palette.hairlineStrong),
        ("accent", PiDesign.Palette.accent),
        ("success", PiDesign.Palette.success),
        ("warning", PiDesign.Palette.warning),
        ("danger", PiDesign.Palette.danger),
    ]

    private static let radii: [(name: String, value: CGFloat)] = [
        ("chip", PiDesign.Radius.chip),
        ("control", PiDesign.Radius.control),
        ("card", PiDesign.Radius.card),
        ("window", PiDesign.Radius.window),
    ]

    private static let sources = [
        ContextSource(id: "1", kind: "Skill", title: "trip-planner", subtitle: "Instructions", symbol: "book.closed.fill", tint: .indigo, url: nil),
        ContextSource(id: "2", kind: "Skill file", title: "packing.md", subtitle: "trip-planner", symbol: "doc.text.fill", tint: .indigo, url: nil),
        ContextSource(id: "3", kind: "Web page", title: "developer.apple.com", subtitle: "/documentation/swiftui", symbol: "globe", tint: .teal, url: URL(string: "https://developer.apple.com/documentation/swiftui")),
    ]

    private static let diff = """
    diff --git a/Sources/Greeting.swift b/Sources/Greeting.swift
    --- a/Sources/Greeting.swift
    +++ b/Sources/Greeting.swift
    @@ -3,6 +3,7 @@ import Foundation
     struct Greeting {
         let name: String
    -    var text: String { "Hello, " + name }
    +    var text: String { "Hello, \\(name)!" }
    +    var short: String { "Hi" }
     }
    """

    private static let records = """
    [{"host":"nas","load":0.42,"disk":"71%","up":true},{"host":"pi-hole","load":0.08,"disk":"23%","up":true},{"host":"backup","load":null,"disk":"—","up":false}]
    """

    /// Header, stats, a checklist, a badge and buttons from the catalog's sample slots, as one chat card.
    private static let piCard: SurfaceSpec = {
        let slots = ["Header", "StatGrid", "Checklist", "Badge", "ActionRow"].compactMap(ComponentSamples.slot)
        return SurfaceSpec(["schema": 1, "title": "Sample", "surface": "card", "families": ["card"], "slots": .array(slots)])
    }()

    private static let markdown = """
    | Model | Context | Price |
    |:--|--:|--:|
    | Flash | 128K | $0.10 |
    | Pro | 1M | $1.25 |

    ```swift
    let total = buckets.reduce(0, +)
    ```
    """
}
