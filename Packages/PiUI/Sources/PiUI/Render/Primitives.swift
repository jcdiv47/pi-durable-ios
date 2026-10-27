import Charts
import SwiftUI
import WidgetKit

/// Layer 0: draws a `Custom` slot's primitive tree. Unknown nodes draw nothing, so an older renderer
/// degrades instead of failing.
struct NodeView: View {
    let node: JSONValue
    @Environment(\.surface) private var surface
    @Environment(\.surfaceData) private var data
    @Environment(\.surfaceIsStill) private var still

    var body: some View {
        primitive.modifier(NodeModifiers(node: node, tinted: surface.tinted))
    }

    private var children: [JSONValue] { node["children"]?.array ?? [] }
    private var color: Color? { node["color"]?.string.map { surface.tinted ? .primary : Palette.color($0) } }

    @ViewBuilder private var primitive: some View {
        switch node["t"]?.string {
        case "VStack":
            VStack(alignment: horizontal, spacing: spacing) { childViews }
        case "HStack":
            HStack(alignment: vertical, spacing: spacing) { childViews }
        case "ZStack":
            ZStack(alignment: alignment) { childViews }
        case "Text":
            text.font(font).fontWeight(weight).fontDesign(design).lineLimit(node["lineLimit"]?.number.map { Int($0) }).foregroundStyle(color ?? .primary)
        case "Image":
            Image(systemName: node["symbol"]?.string ?? "questionmark")
                .font(.system(size: CGFloat(node["size"]?.number ?? 17)))
                .foregroundStyle(color ?? .primary)
        case "Spacer":
            Spacer(minLength: node["minLength"]?.number.map { CGFloat($0) })
        case "Divider":
            Divider()
        case "Gauge":
            gauge
        case "Progress":
            // Drawn, not a ProgressView: ImageRenderer cannot draw platform controls, and previews must match.
            let total = max(node["total"]?.number ?? 1, 0.0001)
            let fraction = min(max((data.number(node["value"]) ?? 0) / total, 0), 1)
            Capsule()
                .fill((color ?? .accentColor).opacity(0.22))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color ?? .accentColor).frame(width: proxy.size.width * fraction).widgetAccentable()
                    }
                }
                .frame(height: 6)
        case "Chart":
            chart
        case "Link":
            if let url = node["url"]?.string.flatMap(URL.init(string:)) {
                if still { VStack(spacing: spacing) { childViews } } else { Link(destination: url) { VStack(spacing: spacing) { childViews } } }
            }
        default:
            EmptyView()
        }
    }

    private var childViews: some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in NodeView(node: child) }
    }

    private var spacing: CGFloat? { node["spacing"]?.number.map { CGFloat($0) } }

    private var horizontal: HorizontalAlignment {
        switch node["align"]?.string {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }

    private var vertical: VerticalAlignment {
        switch node["align"]?.string {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }

    private var alignment: Alignment {
        switch node["align"]?.string {
        case "leading": .leading
        case "trailing": .trailing
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }

    private var text: Text {
        if let style = node["dateStyle"]?.string, let date = data.date(node["text"]) {
            switch style {
            case "timer": return Text(date, style: .timer)
            case "date": return Text(date, style: .date)
            case "time": return Text(date, style: .time)
            default: return Text(date, style: .relative)
            }
        }
        return Text(data.text(node["text"]) ?? placeholder)
    }

    private var font: Font {
        switch node["font"]?.string {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "title3": .title3
        case "headline": .headline
        case "callout": .callout
        case "subheadline": .subheadline
        case "footnote": .footnote
        case "caption": .caption
        case "caption2": .caption2
        default: .body
        }
    }

    private var weight: Font.Weight? {
        switch node["weight"]?.string {
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        default: nil
        }
    }

    private var design: Font.Design? {
        switch node["design"]?.string {
        case "rounded": .rounded
        case "monospaced": .monospaced
        case "serif": .serif
        default: nil
        }
    }

    @ViewBuilder private var gauge: some View {
        let low = node["min"]?.number ?? 0
        let high = max(node["max"]?.number ?? 1, low + 0.0001)
        let value = min(max(data.number(node["value"]) ?? low, low), high)
        let gauge = Gauge(value: value, in: low ... high) {
            if let label = data.text(node["label"]) { Text(label) }
        }
        .tint(color ?? .accentColor)
        .widgetAccentable()
        if node["style"]?.string == "linear" { gauge.gaugeStyle(.accessoryLinearCapacity) } else { gauge.gaugeStyle(.accessoryCircularCapacity) }
    }

    private var chart: some View {
        let values = data.series(node["series"]).values
        let tint = color ?? .accentColor
        let kind = node["kind"]?.string ?? "line"
        return Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                switch kind {
                case "bar": BarMark(x: .value("x", index), y: .value("y", value)).foregroundStyle(tint)
                case "area": AreaMark(x: .value("x", index), y: .value("y", value)).foregroundStyle(tint.opacity(0.5))
                case "point": PointMark(x: .value("x", index), y: .value("y", value)).foregroundStyle(tint)
                case "sector": SectorMark(angle: .value("v", value), innerRadius: .ratio(0.55)).foregroundStyle(by: .value("i", "\(index)"))
                default: LineMark(x: .value("x", index), y: .value("y", value)).foregroundStyle(tint)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .widgetAccentable()
    }
}

/// Modifiers every node may carry: padding, background, cornerRadius, opacity, fill.
struct NodeModifiers: ViewModifier {
    let node: JSONValue
    let tinted: Bool

    func body(content: Content) -> some View {
        let fill = node["fill"]?.bool == true
        let radius = CGFloat(node["cornerRadius"]?.number ?? 0)
        content
            .frame(maxWidth: fill ? .infinity : nil, maxHeight: fill ? .infinity : nil)
            .padding(CGFloat(node["padding"]?.number ?? 0))
            .background {
                if let background = node["background"]?.string {
                    RoundedRectangle(cornerRadius: radius).fill(tinted ? Color.primary.opacity(0.15) : Palette.color(background))
                }
            }
            .opacity(node["opacity"]?.number ?? 1)
    }
}
