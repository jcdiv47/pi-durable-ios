import SwiftUI

/// Assistant text as Markdown blocks: Foundation parses it (CommonMark with GitHub tables), SwiftUI lays out each block.
/// A single newline is a line break, as people and models write chat; inline styles and links stay attributed text.
struct MarkdownText: View {
    let source: String

    var body: some View {
        MarkdownBlocks(blocks: MarkdownDocument.blocks(source), depth: 0)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

indirect enum MarkdownBlock: Hashable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case code(String, language: String?)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    /// The first row is the header.
    case table(alignments: [ColumnAlignment], rows: [[AttributedString]])
    case rule

    enum ColumnAlignment: Hashable {
        case leading, center, trailing

        var alignment: HorizontalAlignment { self == .leading ? .leading : self == .center ? .center : .trailing }
    }
}

enum MarkdownDocument {
    /// Parsed documents by text. Bodies run on every frame; a long transcript would otherwise parse every answer again.
    @MainActor private static var cache: [String: [MarkdownBlock]] = [:]

    @MainActor
    static func blocks(_ source: String) -> [MarkdownBlock] {
        if let blocks = cache[source] { return blocks }
        let blocks = parse(source)
        if cache.count > 300 { cache.removeAll() }
        cache[source] = blocks
        return blocks
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        guard let document = try? AttributedString(
            markdown: source,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else { return [.paragraph(AttributedString(source))] }
        // Runs carry their block path, innermost first; rebuild the tree outermost first. Runs come in document order,
        // so a run's block is either its parent's last child or a new one.
        let root = Node(kind: nil, identity: -1)
        for run in document.runs {
            var text = AttributedString(document[run.range])
            if let inline = run.inlinePresentationIntent, inline.contains(.softBreak) || inline.contains(.lineBreak) {
                text = AttributedString("\n")
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                text.swiftUI.backgroundColor = Color.secondary.opacity(0.15)
            }
            var node = root
            for component in (run.presentationIntent?.components ?? []).reversed() {
                if let last = node.children.last, last.identity == component.identity {
                    node = last
                } else {
                    let child = Node(kind: component.kind, identity: component.identity)
                    node.children.append(child)
                    node = child
                }
            }
            node.text.append(text)
        }
        // Text outside any block (none in practice) reads as a paragraph.
        if !root.text.characters.isEmpty { root.children.insert(Node(kind: .paragraph, identity: -2, text: root.text), at: 0) }
        return root.children.compactMap(block)
    }

    private final class Node {
        let kind: PresentationIntent.Kind?
        let identity: Int
        var children: [Node] = []
        var text: AttributedString

        init(kind: PresentationIntent.Kind?, identity: Int, text: AttributedString = AttributedString()) {
            self.kind = kind
            self.identity = identity
            self.text = text
        }
    }

    private static func block(_ node: Node) -> MarkdownBlock? {
        switch node.kind {
        case let .header(level):
            return .heading(level: level, node.text)
        case let .codeBlock(language):
            var code = String(node.text.characters)
            if code.hasSuffix("\n") { code.removeLast() }
            return .code(code, language: language?.isEmpty == false ? language : nil)
        case .blockQuote:
            return .quote(node.children.compactMap(block))
        case .orderedList, .unorderedList:
            var start = 1
            if case let .listItem(ordinal) = node.children.first?.kind { start = ordinal }
            return .list(ordered: node.kind == .orderedList, start: start, items: node.children.map { $0.children.compactMap(block) })
        case let .table(columns):
            let alignments = columns.map { column -> MarkdownBlock.ColumnAlignment in
                switch column.alignment {
                case .center: .center
                case .right: .trailing
                default: .leading
                }
            }
            let rows = node.children.map { row in
                (0 ..< columns.count).map { column in
                    row.children.first { if case let .tableCell(index) = $0.kind { index == column } else { false } }?.text ?? AttributedString()
                }
            }
            return .table(alignments: alignments, rows: rows)
        case .thematicBreak:
            return .rule
        default:
            // Paragraphs, and anything this renderer has no layout for, as text.
            if !node.children.isEmpty, node.text.characters.isEmpty {
                let inner = node.children.compactMap(block)
                return inner.count == 1 ? inner[0] : .quote(inner)
            }
            return node.text.characters.isEmpty ? nil : .paragraph(node.text)
        }
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, depth: depth)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case let .paragraph(text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case let .heading(level, text):
            Text(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, depth == 0 ? 4 : 0)
        case let .code(code, language):
            CodeBlockView(code: code, language: language)
        case let .quote(blocks):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(.tertiary).frame(width: 3)
                MarkdownBlocks(blocks: blocks, depth: depth + 1).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(start + index)." : depth.isMultiple(of: 2) ? "•" : "◦")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: ordered ? 20 : 12, alignment: .trailing)
                        MarkdownBlocks(blocks: item, depth: depth + 1)
                    }
                }
            }
        case let .table(alignments, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                Text(cell)
                                    .fontWeight(index == 0 ? .semibold : nil)
                                    .gridColumnAlignment(column < alignments.count ? alignments[column].alignment : .leading)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .font(.subheadline)
                .padding(12)
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.callout.monospaced()).padding(12)
            }
        }
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}
