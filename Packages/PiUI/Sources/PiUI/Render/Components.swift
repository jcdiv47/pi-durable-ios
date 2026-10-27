import Charts
import SwiftUI
import WidgetKit

// Layer 1 components. Each adapts to the family in `\.surface`: system families and cards get the full
// layout, accessories a compact one, `accessoryInline` a single line of text.

let placeholder = "—"

/// The circle behind accessoryCircular content: WidgetKit's inside a widget, a stand-in in previews.
struct CircularBackground: View {
    @Environment(\.surface) private var surface

    var body: some View {
        if surface.inWidget { AccessoryWidgetBackground() } else { Circle().fill(.white.opacity(0.16)) }
    }
}

struct SymbolLabel: View {
    let text: String
    let symbol: String?

    var body: some View {
        if let symbol { Label(text, systemImage: symbol) } else { Text(text) }
    }
}

struct MetricTileView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface
    @Environment(\.slotFills) private var fills

    var body: some View {
        let value = r.text("value") ?? placeholder
        let label = r.text("label") ?? ""
        let unit = r.text("unit")
        let symbol = r.literal("symbol")
        let tint = surface.tint(r.literal("tint"), default: .accentColor)
        switch surface.family {
        case .accessoryInline:
            SymbolLabel(text: [value, unit, label].compactMap { $0 }.joined(separator: " "), symbol: symbol)
        case .accessoryCircular:
            ZStack {
                CircularBackground()
                VStack(spacing: 0) {
                    if let symbol { Image(systemName: symbol).font(.caption).widgetAccentable() }
                    Text(value).font(.system(.title3, design: .rounded, weight: .bold)).minimumScaleFactor(0.4).lineLimit(1)
                    if symbol == nil, !label.isEmpty { Text(label).font(.system(size: 9)).lineLimit(1) }
                }
                .padding(6)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                SymbolLabel(text: label, symbol: symbol).font(.headline).widgetAccentable().lineLimit(1)
                valueText(value, unit, size: 26)
                trend
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let symbol { Image(systemName: symbol).surfaceTint(tint, surface) }
                    Text(label).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                if fills { Spacer(minLength: 0) }
                valueText(value, unit, size: surface.family == .systemSmall || fills ? 40 : 30)
                trend
            }
        }
    }

    private func valueText(_ value: String, _ unit: String?, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: size, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
            if let unit { Text(unit).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.secondary) }
        }
        .contentTransition(.numericText())
    }

    @ViewBuilder private var trend: some View {
        let delta = r.text("delta")
        if let direction = r.literal("trend") ?? (delta != nil ? "flat" : nil) {
            let (symbol, color): (String, Color) = switch direction {
            case "up": ("arrow.up.right", .green)
            case "down": ("arrow.down.right", .red)
            default: ("arrow.right", .secondary)
            }
            HStack(spacing: 2) {
                Image(systemName: symbol)
                if let delta { Text(delta) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(surface.tinted ? .secondary : color)
        }
    }
}

struct RingView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface
    @Environment(\.slotFills) private var fills

    var body: some View {
        let value = r.number("value")
        let goal = max(r.number("goal") ?? 1, 0.0001)
        let progress = min(max((value ?? 0) / goal, 0), 1)
        let label = r.text("label")
        let symbol = r.literal("symbol")
        let tint = surface.tint(r.literal("tint"), default: .green)
        let valueText = value.map(SurfaceData.formatNumber) ?? placeholder
        switch surface.family {
        case .accessoryCircular:
            Gauge(value: progress) {
                if let symbol { Image(systemName: symbol) }
            } currentValueLabel: {
                if let symbol { Image(systemName: symbol) } else { Text(valueText).minimumScaleFactor(0.4) }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Gauge(value: progress) {} currentValueLabel: {
                    if let symbol { Image(systemName: symbol) } else { Text("\(Int(progress * 100))%") }
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .scaleEffect(0.8)
                .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    if let label { Text(label).font(.headline).lineLimit(1) }
                    Text(valueText).font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                    Text("of \(SurfaceData.formatNumber(goal))\(r.text("unit").map { " \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(tint.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                    VStack(spacing: 0) {
                        if let symbol { Image(systemName: symbol).font(.caption).surfaceTint(tint, surface) }
                        Text(valueText).font(.system(.headline, design: .rounded, weight: .bold)).minimumScaleFactor(0.5).lineLimit(1)
                        Text("/ \(SurfaceData.formatNumber(goal))").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .padding(12)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: fills ? 220 : 120, maxHeight: fills ? 220 : 120)
                if let label { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
        }
    }
}

struct SparklineView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let series = r.series("series").values
        let tint = surface.tint(r.literal("tint"), default: .blue)
        let highlight = r.literal("highlight") ?? "last"
        let marked: Int? = switch highlight {
        case "max": series.indices.max { series[$0] < series[$1] }
        case "min": series.indices.min { series[$0] < series[$1] }
        case "none": nil
        default: series.indices.last
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if let label = r.text("label") { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                if let marked {
                    Text(SurfaceData.formatNumber(series[marked]) + (r.text("unit").map { " \($0)" } ?? ""))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .lineLimit(1)
                }
            }
            if series.count < 2 {
                Text(placeholder).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(Array(series.enumerated()), id: \.offset) { index, value in
                        AreaMark(x: .value("i", index), y: .value("v", value))
                            .foregroundStyle(.linearGradient(colors: [tint.opacity(surface.tinted ? 0.3 : 0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("i", index), y: .value("v", value))
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.catmullRom)
                    }
                    if let marked {
                        PointMark(x: .value("i", marked), y: .value("v", series[marked])).foregroundStyle(tint).symbolSize(30)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .widgetAccentable()
                .frame(minHeight: surface.family == .accessoryRectangular ? 24 : 36)
            }
        }
    }
}

struct BarStripView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let series = r.series("series")
        let labels = r.slot["labels"]?.array?.compactMap(\.string) ?? series.labels
        let tint = surface.tint(r.literal("tint"), default: .orange)
        let compact = surface.family == .accessoryRectangular
        VStack(alignment: .leading, spacing: 4) {
            if let label = r.text("label") { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
            if series.values.isEmpty {
                Text(placeholder).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(Array(series.values.enumerated()), id: \.offset) { index, value in
                        BarMark(x: .value("x", labels.indices.contains(index) ? "\(index)|\(labels[index])" : "\(index)|"), y: .value("y", value))
                            .foregroundStyle(index == series.values.count - 1 ? tint : tint.opacity(0.45))
                            .clipShape(.rect(cornerRadius: 3))
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    if compact || labels.isEmpty {
                        AxisMarks { _ in }
                    } else {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let key = value.as(String.self) { Text(key.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? "") }
                            }
                        }
                    }
                }
                .widgetAccentable()
                .frame(minHeight: compact ? 24 : 40)
            }
        }
    }
}

/// Today: "14:30"; later: "Thu 14:30". All-day and date-only items show the date only.
func shortTime(_ date: Date, now: Date) -> String {
    if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

struct NextUpView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let items = r.items("source")
        let tint = surface.tint(r.literal("tint"), default: .red)
        let countdown = r.slot["showCountdown"]?.bool ?? false
        let now = r.data.now
        switch surface.family {
        case .accessoryInline:
            if let item = items.first {
                if countdown, let date = item.date, date > now {
                    Label { Text("\(item.title) · \(Text(date, style: .relative))") } icon: { Image(systemName: "calendar") }
                } else {
                    Label("\(item.title)\(item.date.map { " · \(shortTime($0, now: now))" } ?? "")", systemImage: "calendar")
                }
            } else {
                Label("Nothing next", systemImage: "calendar")
            }
        case .accessoryCircular:
            ZStack {
                CircularBackground()
                VStack(spacing: 0) {
                    Image(systemName: "calendar").font(.caption).widgetAccentable()
                    if let date = items.first?.date {
                        Text(date, style: .time).font(.system(.caption, design: .rounded, weight: .bold)).minimumScaleFactor(0.5).lineLimit(1)
                    } else {
                        Text(placeholder)
                    }
                }
                .padding(6)
            }
        default:
            let max = r.int("maxItems") ?? defaultMax
            VStack(alignment: .leading, spacing: 6) {
                if surface.family != .accessoryRectangular || items.isEmpty {
                    Label(r.text("title") ?? "Up next", systemImage: "calendar")
                        .font(.caption.weight(.semibold))
                        .surfaceTint(tint, surface)
                        .lineLimit(1)
                }
                if items.isEmpty {
                    Text("Nothing coming up").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(items.prefix(max)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).widgetAccentable()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(surface.family == .accessoryRectangular ? .headline : .subheadline.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 4) {
                                if let date = item.date {
                                    if countdown, date > now { Text(date, style: .relative) } else { Text(shortTime(date, now: now)) }
                                }
                                if let subtitle = item.subtitle { Text(subtitle).lineLimit(1) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var defaultMax: Int {
        switch surface.family {
        case .accessoryRectangular: 1
        case .systemSmall, .systemMedium: 2
        default: 4
        }
    }
}

struct CountdownView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface
    @Environment(\.slotFills) private var fills

    var body: some View {
        let date = r.date("date")
        let label = r.text("label")
        let symbol = r.literal("symbol")
        let tint = surface.tint(r.literal("tint"), default: .purple)
        switch surface.family {
        case .accessoryInline:
            Label {
                if let date { Text("\(label.map { "\($0) " } ?? "")\(dateText(date))") } else { Text(label ?? placeholder) }
            } icon: {
                Image(systemName: symbol ?? "timer")
            }
        case .accessoryCircular:
            ZStack {
                CircularBackground()
                VStack(spacing: 0) {
                    Image(systemName: symbol ?? "timer").font(.caption).widgetAccentable()
                    if let date { dateText(date).font(.system(.caption, design: .rounded, weight: .bold)).multilineTextAlignment(.center).minimumScaleFactor(0.4).lineLimit(2) }
                }
                .padding(6)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                if let label {
                    SymbolLabel(text: label, symbol: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if fills { Spacer(minLength: 0) }
                if let date {
                    dateText(date)
                        .font(.system(size: surface.family == .accessoryRectangular ? 22 : 30, weight: .bold, design: .rounded))
                        .surfaceTint(tint, surface)
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                } else {
                    Text(placeholder).font(.title.bold())
                }
            }
        }
    }

    private func dateText(_ date: Date) -> Text {
        switch r.literal("style") {
        case "timer": Text(date, style: .timer)
        case "date": Text(date, style: .date)
        case "time": Text(date, style: .time)
        default: Text(date, style: .relative)
        }
    }
}

struct ChecklistView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface
    @Environment(\.surfaceActions) private var actions

    var body: some View {
        let items = r.items("items")
        let tint = surface.tint(r.literal("tint"), default: .orange)
        let max = r.int("maxItems") ?? (surface.family == .accessoryRectangular ? 2 : surface.family == .systemLarge || surface.family == .card ? 6 : 3)
        VStack(alignment: .leading, spacing: 5) {
            if let title = r.text("title"), surface.family != .accessoryRectangular {
                Text(title).font(.caption.weight(.semibold)).surfaceTint(tint, surface).lineLimit(1)
            }
            if items.isEmpty { Text("All done").font(.subheadline).foregroundStyle(.secondary) }
            // Rows of a $doc list flip their done; rows of $reminders.* complete the reminder.
            let binding = r.slot["items"]?.string
            let toggles = binding.flatMap(SurfaceSpec.docKey) != nil
            let reminders = binding.flatMap(SurfaceSpec.remindersSource) != nil
            ForEach(items.prefix(max)) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .surfaceTint(item.done ? tint : .secondary, surface)
                    Text(item.title)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .lineLimit(1)
                }
                .font(surface.family == .accessoryRectangular ? .caption : .subheadline)
                .surfaceAction(rowAction(item, toggles: toggles, reminders: reminders), actions)
            }
            if items.count > max {
                Text("+\(items.count - max) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func rowAction(_ item: SurfaceItem, toggles: Bool, reminders: Bool) -> String? {
        if toggles { return SurfaceAction.id(item: item.position, slot: r.slot.index) }
        if reminders, !item.done, let id = item.nativeId { return SurfaceAction.id(reminder: id, slot: r.slot.index) }
        return nil
    }
}

struct TimelineListView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let items = r.items("items")
        let tint = surface.tint(r.literal("tint"), default: .blue)
        let max = r.int("maxItems") ?? (surface.family == .accessoryRectangular ? 2 : surface.family == .systemLarge || surface.family == .card ? 6 : 3)
        let now = r.data.now
        VStack(alignment: .leading, spacing: 0) {
            if let title = r.text("title"), surface.family != .accessoryRectangular {
                Text(title).font(.caption.weight(.semibold)).surfaceTint(tint, surface).padding(.bottom, 4)
            }
            if items.isEmpty { Text("Nothing scheduled").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array(items.prefix(max).enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.date.map { shortTime($0, now: now) } ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: surface.family == .accessoryRectangular ? 38 : 44, alignment: .trailing)
                    VStack(spacing: 0) {
                        Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 4).widgetAccentable()
                        if index < min(items.count, max) - 1 { Rectangle().fill(tint.opacity(0.3)).frame(width: 1.5) }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        if let subtitle = item.subtitle, surface.family != .accessoryRectangular {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct QuoteView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let text = r.text("text") ?? placeholder
        let emphasis = r.literal("emphasis") ?? "primary"
        let symbol = r.literal("symbol")
        switch surface.family {
        case .accessoryInline:
            SymbolLabel(text: text, symbol: symbol)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                if let symbol { Image(systemName: symbol).font(.caption).widgetAccentable() }
                Text(text).font(.callout).lineLimit(3).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.title3).surfaceTint(surface.tint(nil, default: .accentColor), surface) }
                Text(text)
                    .font(font(for: text))
                    .foregroundStyle(emphasis == "secondary" ? AnyShapeStyle(.secondary) : emphasis == "accent" && !surface.tinted ? AnyShapeStyle(Palette.color(surface.tint)) : AnyShapeStyle(.primary))
                    .minimumScaleFactor(0.7)
                    .lineLimit(surface.family == .card ? nil : 8)
                if let attribution = r.text("attribution") {
                    Text("— \(attribution)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func font(for text: String) -> Font {
        let length = text.count
        if surface.family == .card { return .body }
        if length < 40 { return .system(.title3, design: .serif, weight: .semibold) }
        if length < 100 { return .system(.body, design: .serif, weight: .medium) }
        return .system(.subheadline, design: .serif)
    }
}

struct StatGridView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let entries = (r.slot["items"]?.array ?? []).prefix(4).map { item in
            (label: r.data.text(item["label"]) ?? "", value: r.data.text(item["value"]) ?? placeholder, unit: r.data.text(item["unit"]), symbol: item["symbol"]?.string)
        }
        let tint = surface.tint(r.literal("tint"), default: .accentColor)
        let compact = surface.family == .accessoryRectangular
        Grid(alignment: .leading, horizontalSpacing: compact ? 8 : 14, verticalSpacing: compact ? 2 : 10) {
            ForEach(Array(stride(from: 0, to: entries.count, by: 2)), id: \.self) { index in
                GridRow {
                    ForEach(entries[index ..< min(index + 2, entries.count)].indices, id: \.self) { at in
                        let entry = entries[at]
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 3) {
                                if let symbol = entry.symbol { Image(systemName: symbol).surfaceTint(tint, surface) }
                                Text(entry.label).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(compact ? .caption2 : .caption.weight(.medium))
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(entry.value).font(.system(compact ? .subheadline : .title3, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                                if let unit = entry.unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct HeaderView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let title = r.text("title") ?? ""
        let symbol = r.literal("symbol")
        let tint = surface.tint(r.literal("tint"), default: .accentColor)
        if surface.family == .accessoryInline {
            SymbolLabel(text: title, symbol: symbol)
        } else {
            HStack(alignment: .center, spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.headline).surfaceTint(tint, surface) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline).lineLimit(1)
                    if let subtitle = r.text("subtitle") { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if let updated = r.date("updatedAt") {
                    Text(updated, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct BadgeView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let text = r.text("text") ?? placeholder
        let symbol = r.literal("symbol")
        let tone = Palette.tone(r.literal("tone"))
        switch surface.family {
        case .accessoryInline:
            SymbolLabel(text: text, symbol: symbol)
        case .accessoryCircular:
            ZStack {
                CircularBackground()
                VStack(spacing: 1) {
                    if let symbol { Image(systemName: symbol).font(.title3).widgetAccentable() }
                    Text(text).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                }
                .padding(6)
            }
        default:
            SymbolLabel(text: text, symbol: symbol)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(surface.tinted ? AnyShapeStyle(.primary) : AnyShapeStyle(tone))
                .background(surface.tinted ? AnyShapeStyle(.primary.opacity(0.15)) : AnyShapeStyle(tone.opacity(0.16)), in: .capsule)
                .widgetAccentable()
        }
    }
}

struct ActionRowView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface
    @Environment(\.surfaceActions) private var handler
    @Environment(\.surfaceIsStill) private var still

    var body: some View {
        let actions = (r.slot["actions"]?.array ?? []).prefix(3)
        let tint = surface.tint(r.literal("tint"), default: .accentColor)
        HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                let title = r.data.text(action["title"]) ?? ""
                let content = SymbolLabel(text: title, symbol: action["symbol"]?.string)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(tint)
                    .background(tint.opacity(surface.tinted ? 0.2 : 0.14), in: .capsule)
                if let url = action["url"]?.string.flatMap(URL.init(string:)) {
                    if still { content } else { Link(destination: url) { content } }
                } else {
                    content.surfaceAction(SurfaceAction.id(button: index, slot: r.slot.index), handler)
                }
            }
        }
    }
}

struct ImageCardView: View {
    let r: SlotReader
    @Environment(\.surface) private var surface

    var body: some View {
        let symbol = r.literal("symbol") ?? "photo"
        let tint = surface.tint(r.literal("tint"), default: .accentColor)
        switch surface.family {
        case .accessoryCircular:
            ZStack {
                CircularBackground()
                Image(systemName: symbol).font(.title2).widgetAccentable()
            }
        case .accessoryRectangular:
            HStack {
                Image(systemName: symbol).font(.title).widgetAccentable()
                if let caption = r.text("caption") { Text(caption).font(.headline).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 64, maxHeight: 64)
                    .symbolRenderingMode(surface.tinted ? .monochrome : .hierarchical)
                    .surfaceTint(tint, surface)
                if let caption = r.text("caption") {
                    Text(caption).font(.subheadline.weight(.medium)).multilineTextAlignment(.center).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
