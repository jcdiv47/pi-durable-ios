import PiUI
import SwiftUI

/// A transcript entry as the conversation shows it: messages as they are, and each stretch of tool calls folded into one
/// "Worked" row, with the cards its results draw under it.
enum TranscriptRow: Identifiable {
    /// `resent`: an answer cut off by a crash or eviction, which Pi then asked for again.
    case item(DisplayItem, resent: Bool)
    /// Tool-calling answers in a row, and their results (looked up by call ID).
    case work(id: Int, steps: [DisplayItem])

    var id: Int {
        switch self {
        case let .item(item, _): item.id
        // An answer with text and calls is both an item and the start of a work row.
        case let .work(id, _): -id
        }
    }

    static func rows(_ items: [DisplayItem]) -> [TranscriptRow] {
        let calls = Set(items.flatMap { $0.toolCalls ?? [] }.map(\.id))
        var rows: [TranscriptRow] = []
        for (index, item) in items.enumerated() {
            switch item.kind {
            case .assistant:
                let hasCalls = !(item.toolCalls ?? []).isEmpty
                let stopped = ["aborted", "error", "length"].contains(item.stopReason ?? "")
                let shown = !(item.text ?? "").isEmpty || !(item.thinking ?? "").isEmpty || !hasCalls || stopped
                if shown {
                    let resent = item.stopReason == "aborted" && index + 1 < items.count && items[index + 1].kind == .assistant
                    rows.append(.item(item, resent: resent))
                }
                guard hasCalls else { continue }
                if !shown, case let .work(id, steps)? = rows.last {
                    rows[rows.count - 1] = .work(id: id, steps: steps + [item])
                } else {
                    rows.append(.work(id: item.id, steps: [item]))
                }
            case .toolResult:
                // Results show with their calls; one whose call is not in view shows on its own.
                if !calls.contains(item.callId ?? "") { rows.append(.item(item, resent: false)) }
            default:
                rows.append(.item(item, resent: false))
            }
        }
        return rows
    }

    /// The answers that end a turn: an assistant message with text whose next row is the user's (or nothing, once the run
    /// is over). These get the Copy, Share and Fork buttons; answers in the middle of a turn keep them in the long-press menu.
    static func turnEnds(_ rows: [TranscriptRow], busy: Bool) -> Set<Int> {
        var ends: Set<Int> = []
        for (index, row) in rows.enumerated() {
            guard case let .item(item, _) = row, item.kind == .assistant, !(item.text ?? "").isEmpty else { continue }
            let next = rows.dropFirst(index + 1).first
            switch next {
            case nil: if !busy { ends.insert(item.id) }
            case let .item(following, _)? where following.kind == .user: ends.insert(item.id)
            default: break
            }
        }
        return ends
    }
}

/// Under an answer that ends a turn: Copy (which turns into a check for a moment), Share and Fork, small and quiet so
/// they read as tools for the answer above, not as part of it.
struct AnswerActions: View {
    let text: String
    let fork: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel(copied ? "Copied" : "Copy")
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Share")
            Button(action: fork) {
                Image(systemName: "arrow.triangle.branch")
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Fork from here")
        }
        .buttonStyle(.plain)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.leading, -8)
        .padding(.top, -6)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .accessibilityIdentifier("answer.actions")
    }
}

/// One committed transcript entry.
struct TranscriptItemView: View {
    let item: DisplayItem
    let state: ConversationState
    let store: ChatStore
    var resent = false

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 3) {
                if let origin = item.origin {
                    Label(origin, systemImage: originSymbol(origin)).font(.caption2).foregroundStyle(.secondary)
                }
                if let skill = item.skill {
                    SentSkillChip(store: store, name: skill)
                }
                if let attachments = item.attachments, !attachments.isEmpty {
                    SentAttachments(attachments: attachments)
                }
                if (item.attachments == nil && item.skill == nil) || !(item.text ?? "").isEmpty {
                    HStack {
                        Spacer(minLength: 48)
                        Text(item.text ?? "")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(item.origin == nil ? Color.accentColor : Color.indigo, in: .rect(cornerRadius: 18))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                }
            }
        case .assistant:
            AssistantView(text: item.text ?? "", thinking: item.thinking ?? "", streaming: false)
            if item.stopReason == "aborted" && resent {
                Label("Interrupted when Pi was closed; asked again", systemImage: "arrow.clockwise.circle").font(.caption).foregroundStyle(.secondary)
            } else if item.stopReason == "aborted" {
                Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
            } else if item.stopReason == "error" {
                Label(item.error ?? "The model request failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if item.stopReason == "length" {
                Label("The answer hit the length limit", systemImage: "scissors").font(.caption).foregroundStyle(.secondary)
            }
        case .toolResult:
            ToolCallCard(call: ToolCallItem(id: item.callId ?? "", name: item.toolName ?? "tool", arguments: "{}"), result: item, live: nil, approval: nil, store: store)
        case .notice:
            Text(item.text ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A user message's attachments above its bubble: images open full size, links open like any link (Settings › Links).
private struct SentAttachments: View {
    let attachments: [DisplayAttachment]
    @State private var viewing: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    switch attachment.look {
                    case let .image(file):
                        AttachmentChip(look: .image(file: file), height: 120)
                            .onTapGesture { viewing = file }
                            .accessibilityAddTraits(.isButton)
                    case let .link(_, url):
                        AttachmentChip(look: attachment.look)
                            .onTapGesture { openURL(url) }
                            .accessibilityAddTraits(.isLink)
                    case .text:
                        AttachmentChip(look: attachment.look)
                    }
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .scrollIndicators(.hidden)
        .padding(.leading, 48)
        .sheet(item: Binding(get: { viewing.map(ViewedImage.init) }, set: { viewing = $0?.id })) { image in
            NavigationStack {
                AttachmentImage(file: image.id, maxPixel: 2400, fit: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { viewing = nil }
                        }
                    }
            }
        }
    }

    private struct ViewedImage: Identifiable {
        let id: String
    }
}

private func originSymbol(_ origin: String) -> String {
    if origin.hasPrefix("Widget") { return "square.grid.2x2" }
    if origin.hasPrefix("Scheduled") || origin.hasPrefix("Run now") { return "clock.arrow.circlepath" }
    if origin.hasPrefix("Notification") { return "bell" }
    if origin.hasPrefix("Share") { return "square.and.arrow.up" }
    return "waveform"
}

/// A stretch of tool calls as one row: "Worked 11s · 2 steps", which opens to each call's card. Calls waiting for
/// approval stay open, and the results' cards (native ones and the agent's surfaces) always show under it.
struct WorkRow: View {
    let steps: [DisplayItem]
    let state: ConversationState
    let store: ChatStore
    @State private var expanded = false
    @Environment(\.holdTranscriptPosition) private var holdPosition

    var body: some View {
        let calls = steps.flatMap { $0.toolCalls ?? [] }
        let results = calls.compactMap { state.results[$0.id] }
        // Only an unfinished row reads the live state, so finished rows are not redrawn with every streamed frame.
        let running = results.count < calls.count && state.live.busy
        let waiting = Set(store.approvals.filter { $0.conversationId == state.id }.map(\.callId))
        VStack(alignment: .leading, spacing: 10) {
            Button {
                holdPosition()
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().controlSize(.mini)
                    } else {
                        let failed = results.contains(where: \.isFailure)
                        Image(systemName: failed ? "exclamationmark.triangle" : results.contains(where: \.isDeclined) ? "hand.raised" : "apple.terminal")
                            .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    if running, let start = steps.first?.date {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(summary(calls: calls, results: results, running: true, seconds: context.date.timeIntervalSince(start)))
                        }
                    } else {
                        Text(summary(calls: calls, results: results, running: running, seconds: duration(results)))
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work.row")
            ForEach(calls.filter { expanded || waiting.contains($0.id) }, id: \.id) { call in
                ToolCallCard(
                    call: call,
                    result: state.results[call.id],
                    live: running ? state.liveTool(call.id) : nil,
                    approval: store.approvals.first { $0.conversationId == state.id && $0.callId == call.id },
                    store: store
                )
            }
            ForEach(calls, id: \.id) { call in
                if let result = state.results[call.id] { card(call, result) }
            }
        }
    }

    @ViewBuilder private func card(_ call: ToolCallItem, _ result: DisplayItem) -> some View {
        if let surface = result.surface {
            if store.states[surface.conversationId]?.latestSurfaceCall[surface.id].map({ $0 == call.id }) ?? true {
                SurfaceStrip(surface: surface, store: store)
            } else {
                Text("\(surface.id) version \(surface.version); newer below").font(.caption).foregroundStyle(.secondary)
            }
        } else if let content = ResultCardContent(call: call, result: result) {
            ResultCard(content: content, store: store)
        }
    }

    /// From the first answer to the last result; nil without timestamps (entries from before they were shown).
    private func duration(_ results: [DisplayItem]) -> TimeInterval? {
        guard let start = steps.first?.date, let end = results.compactMap(\.date).max(), end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    private func summary(calls: [ToolCallItem], results: [DisplayItem], running: Bool, seconds: TimeInterval?) -> String {
        let time = seconds.map { " \(Self.elapsed($0))" } ?? ""
        var parts = ["\(running ? "Working" : "Worked")\(time)", calls.count == 1 ? "1 step" : "\(calls.count) steps"]
        let failed = results.filter(\.isFailure).count
        if failed > 0 { parts.append("\(failed) failed") }
        let declined = results.filter(\.isDeclined).count
        if declined > 0 { parts.append("\(declined) declined") }
        return parts.joined(separator: " · ")
    }

    /// "8s", "1m 25s".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }
}

/// The streamed partial answer of the current run, and what the run is doing.
struct LiveView: View {
    let state: ConversationState
    let store: ChatStore

    var body: some View {
        let live = state.live
        if let generation = live.generation, !(generation.text.isEmpty && generation.thinking.isEmpty) {
            AssistantView(text: generation.text, thinking: generation.thinking, streaming: true)
        }
        if let retry = live.generation?.retry {
            Label("Retrying: \(retry.error)", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let error = live.compactionError {
            Label("Summarizing failed: \(error)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        if live.busy {
            LiveStatusRow(state: state, store: store)
        }
    }
}

/// The run's step and how long it has been going ("Thinking 8s", "Waiting for you"), the same words as its Live Activity.
struct LiveStatusRow: View {
    let state: ConversationState
    let store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let approval = store.approvals.first { $0.conversationId == state.id }
        let status = RunActivities.status(state.live, approval: approval)
        HStack(spacing: 10) {
            Image(systemName: approval != nil ? "hand.raised.fill" : status.symbol)
                .foregroundStyle(approval != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .symbolEffect(.pulse, isActive: approval == nil && !reduceMotion)
                .frame(width: 22)
            Text(approval != nil ? "Waiting for you" : status.status.replacingOccurrences(of: "…", with: ""))
                .lineLimit(1)
            Spacer()
            if let since = state.busySince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(WorkRow.elapsed(context.date.timeIntervalSince(since))).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(approval != nil ? AnyShapeStyle(.orange.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .capsule)
        .accessibilityIdentifier("live.status")
    }
}

struct AssistantView: View {
    let text: String
    let thinking: String
    let streaming: Bool
    @State private var showThinking = false
    @Environment(\.holdTranscriptPosition) private var holdPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !thinking.isEmpty {
                Button {
                    holdPosition()
                    withAnimation(.snappy(duration: 0.25)) { showThinking.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "brain")
                        Text(streaming && text.isEmpty ? "Thinking" : "Thought")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showThinking ? 90 : 0))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                }
                .buttonStyle(.plain)
                if showThinking {
                    Text(thinking).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !text.isEmpty {
                MarkdownText(source: text)
            }
        }
    }
}

struct ToolCallCard: View {
    let call: ToolCallItem
    let result: DisplayItem?
    let live: LiveTool?
    let approval: ApprovalRequest?
    let store: ChatStore
    @State private var expanded = false
    @Environment(\.holdTranscriptPosition) private var holdPosition

    private var status: (String, Color, String) {
        if let result {
            if result.isDeclined { return ("hand.raised.fill", .secondary, "Declined") }
            return result.isError == true ? ("xmark.octagon.fill", .red, "Failed") : ("checkmark.circle.fill", .green, "Done")
        }
        if approval != nil { return ("hand.raised.fill", .orange, "Waiting for approval") }
        if let live, live.status == "running" { return ("gearshape.2", .blue, "Running") }
        return ("clock", .secondary, "Pending")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                holdPosition()
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: status.0).foregroundStyle(status.1)
                    Text(call.name).font(.subheadline.monospaced().weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    if result == nil, approval == nil, live?.status == "running" { ProgressView().controlSize(.mini) }
                    Text(status.2).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if let approval {
                // A Code Mode script's call asks on the codemode row: name the script's tool and what it would do.
                Text("\(ToolTitles.action(for: approval.tool))?")
                    .font(.subheadline.weight(.semibold))
                if approval.tool != call.name {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From the script: \(approval.tool)").font(.caption.monospaced())
                        ForEach(ApprovalDetails.rows(approval.arguments), id: \.key) { row in
                            Text("\(row.label): \(row.value)").font(.caption).lineLimit(2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                // The same glass buttons as the approval sheet, Deny first as there.
                GlassEffectContainer {
                    HStack {
                        Button("Deny", role: .destructive) { Task { await store.answer(approval, allow: false) } }.buttonStyle(.glass)
                        Button("Allow") { Task { await store.answer(approval, allow: true) } }.buttonStyle(.glassProminent).tint(.green)
                    }
                }
                .controlSize(.small)
            }
            if expanded {
                Text(call.name == "codemode" ? scriptCode(call.arguments) : prettyJSON(call.arguments)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if result?.isDeclined == true {
                    Divider()
                    Text("You declined this, so Pi didn't run it.").font(.caption).foregroundStyle(.secondary)
                } else if let output = result?.text ?? live?.output, !output.isEmpty {
                    Divider()
                    Text(output)
                        .font(.caption.monospaced())
                        .foregroundStyle(result?.isError == true ? .red : .primary)
                        .textSelection(.enabled)
                        .lineLimit(40)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("tool.\(call.name)")
    }
}

/// A surface drawn in the chat: a card as is, a widget in each of its families, side by side.
struct SurfaceStrip: View {
    let surface: SurfaceRef
    let store: ChatStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let spec = surface.parsed
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(spec.families) { family in
                    VStack(alignment: .leading, spacing: 4) {
                        FramedSurface(spec: spec, family: family, appearance: colorScheme == .dark ? .dark : .light, data: store.surfaceData)
                        if family != .card {
                            Text(family.displayName).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollClipDisabled()
        .task { await store.refreshSurfaceData() }
        .accessibilityIdentifier("surface.\(surface.id)")
    }
}
