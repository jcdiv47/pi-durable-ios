import SwiftUI

// The chat's shared pieces, drawn with `PiDesign`'s tokens: a shimmering status label, a tool call's status, tool chips,
// context cards for what a run read, unified diffs, and tables. Settings › Widgets › Chat Components shows each one.

// MARK: - Shimmer

/// A label with a light sweeping across it while something is under way ("Thinking", "Working 8s"). Plain text when
/// inactive or with Reduce Motion on.
struct ShimmerText: View {
    let text: String
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = Text(text)
        if active, !reduceMotion {
            label
                .foregroundStyle(.secondary)
                .overlay {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        GeometryReader { geometry in
                            let width = max(geometry.size.width, 1)
                            LinearGradient(colors: [.clear, .primary.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: width * 0.5)
                                .offset(x: -width * 0.5 + phase * width * 1.5)
                        }
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
                .accessibilityLabel(text)
        } else {
            label
        }
    }
}

// MARK: - Tool status

/// Where a tool call is: the same words and colors on its chip, its card and its row.
enum ToolStatus: Hashable, CaseIterable {
    case pending, running, waiting, done, failed, declined

    init(result: DisplayItem?, waiting: Bool, live: LiveTool?) {
        if let result {
            self = result.isDeclined ? .declined : result.isError == true ? .failed : .done
        } else if waiting {
            self = .waiting
        } else if live?.status == "running" {
            self = .running
        } else {
            self = .pending
        }
    }

    var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .waiting: "Waiting for approval"
        case .done: "Done"
        case .failed: "Failed"
        case .declined: "Declined"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .running: "circle.dotted"
        case .waiting: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .declined: "hand.raised.slash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .declined: .secondary
        case .running: PiDesign.Palette.accent
        case .waiting: PiDesign.Palette.warning
        case .done: PiDesign.Palette.success
        case .failed: PiDesign.Palette.danger
        }
    }

    var finished: Bool { self == .done || self == .failed || self == .declined }
}

/// The status's symbol, or a small spinner while running.
struct ToolStatusIcon: View {
    let status: ToolStatus

    var body: some View {
        Group {
            if status == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(status.label)
    }
}

// MARK: - Tool chips

/// One tool call as a compact chip: what kind of tool, its name, and its status. A running stretch of work shows these
/// in a row, so the steps can be followed without opening it.
struct ToolChip: View {
    let name: String
    let status: ToolStatus

    var body: some View {
        let title = ToolTitles.title(for: name)
        HStack(spacing: 6) {
            Image(systemName: title.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(title.tint)
            Text(name)
                .font(PiDesign.Typeface.codeSmall)
                .lineLimit(1)
            ToolStatusIcon(status: status)
                .font(.caption2)
                .scaleEffect(0.85)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(PiDesign.Palette.sunken, in: .rect(cornerRadius: PiDesign.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PiDesign.Radius.chip, style: .continuous)
                .strokeBorder(status == .failed ? PiDesign.Palette.danger.opacity(0.4) : PiDesign.Palette.hairline, lineWidth: 1)
        }
        .animation(PiDesign.Motion.state, value: status)
        .accessibilityElement(children: .combine)
    }
}

struct ToolChips: View {
    let chips: [(id: String, name: String, status: ToolStatus)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    ToolChip(name: chip.name, status: chip.status)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("work.chips")
    }
}

// MARK: - Context cards

/// Something a run read to answer: a skill's instructions or file, a web page. Shown under its work row, so what the
/// answer drew on is visible without opening the steps.
struct ContextSource: Hashable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let url: URL?

    /// The source a finished call read, if it is one the chat names.
    init?(call: ToolCallItem, result: DisplayItem?) {
        guard let result, result.isError != true else { return nil }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "skill_read":
            guard let name = args["name"] as? String else { return nil }
            self.init(id: "skill:\(name)", kind: "Skill", title: name, subtitle: "Instructions", symbol: "book.closed.fill", tint: .indigo, url: nil)
        case "skill_file":
            guard let name = args["name"] as? String, let path = args["path"] as? String else { return nil }
            self.init(id: "skill:\(name)/\(path)", kind: "Skill file", title: (path as NSString).lastPathComponent, subtitle: name, symbol: "doc.text.fill", tint: .indigo, url: nil)
        case "web_fetch":
            guard let text = args["url"] as? String, let url = URL(string: text), let host = url.host() else { return nil }
            let path = url.path()
            self.init(
                id: "web:\(text)",
                kind: "Web page",
                title: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
                subtitle: path.isEmpty || path == "/" ? nil : path,
                symbol: "globe",
                tint: .teal,
                url: url
            )
        default:
            return nil
        }
    }

    init(id: String, kind: String, title: String, subtitle: String?, symbol: String, tint: Color, url: URL?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.url = url
    }

    /// The sources of a stretch of calls, in order, each once.
    static func sources(_ calls: [ToolCallItem], results: [String: DisplayItem]) -> [ContextSource] {
        var seen: Set<String> = []
        return calls.compactMap { ContextSource(call: $0, result: results[$0.id]) }.filter { seen.insert($0.id).inserted }
    }
}

struct ContextCards: View {
    let sources: [ContextSource]
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources) { source in
                    if let url = source.url {
                        Button { openURL(url) } label: { card(source) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isLink)
                    } else {
                        card(source)
                    }
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("work.context")
    }

    private func card(_ source: ContextSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: source.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(source.tint)
                .frame(width: 28, height: 28)
                .background(source.tint.opacity(0.14), in: .rect(cornerRadius: PiDesign.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(source.subtitle ?? source.kind).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 200, alignment: .leading)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .piSurface(.flat, radius: PiDesign.Radius.control)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.kind): \(source.title)")
    }
}

// MARK: - Diff

/// A unified diff, line by line: added and removed lines washed green and red, hunk headers in the accent, and the old
/// and new line numbers in a gutter.
struct DiffView: View {
    let lines: [Line]

    struct Line: Hashable {
        enum Kind { case header, hunk, added, removed, context }
        let kind: Kind
        let text: String
        let old: Int?
        let new: Int?
    }

    init(_ text: String) {
        lines = Self.parse(text)
    }

    /// Whether a tool's output or a code block reads as a unified diff.
    static func looksLikeDiff(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400)
        guard lines.contains(where: { $0.hasPrefix("@@ ") }) else { return false }
        return lines.contains { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }
    }

    static func parse(_ text: String) -> [Line] {
        var old = 0
        var new = 0
        var inHunk = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { substring in
            let line = String(substring)
            if line.hasPrefix("@@") {
                // @@ -12,7 +12,9 @@
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                inHunk = true
                return Line(kind: .hunk, text: line, old: nil, new: nil)
            }
            if !inHunk || line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                if line.hasPrefix("diff ") { inHunk = false }
                return Line(kind: .header, text: line, old: nil, new: nil)
            }
            if line.hasPrefix("+") {
                defer { new += 1 }
                return Line(kind: .added, text: line, old: nil, new: new)
            }
            if line.hasPrefix("-") {
                defer { old += 1 }
                return Line(kind: .removed, text: line, old: old, new: nil)
            }
            if line.hasPrefix("\\") { return Line(kind: .header, text: line, old: nil, new: nil) }
            defer {
                old += 1
                new += 1
            }
            return Line(kind: .context, text: line, old: old, new: new)
        }
    }

    var body: some View {
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("diff").font(PiDesign.Typeface.codeSmall).foregroundStyle(.secondary)
                Spacer()
                Text("+\(added)").foregroundStyle(PiDesign.Palette.success)
                Text("−\(removed)").foregroundStyle(PiDesign.Palette.danger)
            }
            .font(PiDesign.Typeface.codeSmall.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(PiDesign.Palette.sunken)
            Rectangle().fill(PiDesign.Palette.hairline).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .font(PiDesign.Typeface.codeSmall)
        .clipShape(.rect(cornerRadius: PiDesign.Radius.control, style: .continuous))
        .piSurface(.flat, radius: PiDesign.Radius.control)
        .accessibilityIdentifier("diff")
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
            Text(line.new.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(foreground(line.kind))
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .fixedSize()
        }
        .foregroundStyle(.tertiary)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
        .textSelection(.enabled)
    }

    private func foreground(_ kind: Line.Kind) -> Color {
        switch kind {
        case .header: .secondary
        case .hunk: PiDesign.Palette.accent
        case .added, .removed, .context: .primary
        }
    }

    private func background(_ kind: Line.Kind) -> Color {
        switch kind {
        case .added: PiDesign.Palette.added
        case .removed: PiDesign.Palette.removed
        default: .clear
        }
    }
}

// MARK: - Tables

/// Rows and columns: a header on a sunken band, hairlines between rows, tabular numbers, scrolling sideways when wide.
/// Markdown tables and JSON records (`RecordsTable`) both draw with it.
struct PiTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    var alignments: [HorizontalAlignment] = []
    /// The header row's height, for the band behind it (a GridRow takes no background of its own).
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        // A table that fits fills its card (the trailing spacer column takes the rest, so the band and lines reach the
        // edge); a wider one scrolls sideways.
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
        .piSurface(.flat, radius: PiDesign.Radius.control)
        .clipShape(.rect(cornerRadius: PiDesign.Radius.control, style: .continuous))
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                    Text(cell)
                        .font(PiDesign.Typeface.cell.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(column < alignments.count ? alignments[column] : .leading)
                        .padding(.vertical, 8)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                            headerHeight = max(headerHeight, height)
                        }
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Rectangle().fill(PiDesign.Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(PiDesign.Typeface.cell).padding(.vertical, 8)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(alignment: .top) {
            PiDesign.Palette.sunken.frame(height: headerHeight)
        }
    }
}

/// A tool's JSON output as a table, when it is a list of flat records (or an object holding one such list): up to
/// eight columns, in the order keys first appear.
struct RecordsTable: View {
    let columns: [String]
    let rows: [[String]]
    /// The records past `maxRows`, not drawn.
    let more: Int

    static let maxRows = 50

    init?(json text: String) {
        guard text.first == "[" || text.first == "{", let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        var list = value as? [Any]
        if list == nil, let object = value as? [String: Any] {
            let lists = object.values.compactMap { $0 as? [Any] }.filter { ($0.first as? [String: Any]) != nil }
            if lists.count == 1 { list = lists[0] }
        }
        guard let records = list?.compactMap({ $0 as? [String: Any] }), records.count >= 2, records.count == list?.count else { return nil }
        // JSONSerialization drops key order; the order keys first appear in the text is the tool's.
        func position(_ key: String) -> Int {
            text.range(of: "\"\(key)\"")?.lowerBound.utf16Offset(in: text) ?? .max
        }
        var columns: [String] = []
        for record in records {
            for key in record.keys.sorted(by: { position($0) < position($1) }) where !columns.contains(key) {
                // Only scalar values make a table; a nested value keeps the raw output.
                if let value = record[key], value is [Any] || value is [String: Any] { return nil }
                columns.append(key)
            }
        }
        guard !columns.isEmpty, columns.count <= 8 else { return nil }
        self.columns = columns
        rows = records.prefix(Self.maxRows).map { record in columns.map { Self.cell(record[$0]) } }
        more = max(0, records.count - Self.maxRows)
    }

    init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
        more = 0
    }

    private static func cell(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "—"
        case let number as NSNumber:
            // JSONSerialization's booleans are NSNumbers too; only CFBoolean ones read as Yes and No.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "Yes" : "No" }
            return number.stringValue
        case let string as String: return string.count > 80 ? String(string.prefix(79)) + "…" : string
        default: return "\(value!)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PiTable(
                header: columns.map { AttributedString(ApprovalDetails.label($0)) },
                rows: rows.map { $0.map { AttributedString($0) } }
            )
            if more > 0 {
                Text("\(more) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("records.table")
    }
}

// MARK: - Tool output

/// A tool's text output in its card: a diff as a diff, records as a table (with the JSON a tap away), anything else as
/// monospaced text.
struct ToolOutputView: View {
    let output: String
    let isError: Bool
    @State private var raw = false

    var body: some View {
        if !isError, DiffView.looksLikeDiff(output) {
            DiffView(output)
        } else if !isError, !raw, let table = RecordsTable(json: output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            VStack(alignment: .leading, spacing: 6) {
                table
                Button("Show JSON", systemImage: "curlybraces") { withAnimation(PiDesign.Motion.disclose) { raw = true } }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(output)
                .font(PiDesign.Typeface.codeSmall)
                .foregroundStyle(isError ? PiDesign.Palette.danger : .primary)
                .textSelection(.enabled)
                .lineLimit(40)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Gauge

/// A thin capsule filled to `value` (0…1), turning orange past 80% and red past 95%: how full a context is.
struct PiMeter: View {
    let value: Double

    var body: some View {
        let clamped = min(max(value, 0), 1)
        Capsule()
            .fill(PiDesign.Palette.sunken)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(tint).frame(width: max(geometry.size.width * clamped, clamped > 0 ? 3 : 0))
                }
            }
            .overlay { Capsule().strokeBorder(PiDesign.Palette.hairline, lineWidth: 0.5) }
            .frame(height: 4)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        value > 0.95 ? PiDesign.Palette.danger : value > 0.8 ? PiDesign.Palette.warning : PiDesign.Palette.accent.opacity(0.7)
    }
}
