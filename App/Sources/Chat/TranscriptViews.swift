import PiUI
import SwiftUI

/// One committed transcript entry.
struct TranscriptItemView: View {
    let item: DisplayItem
    let state: ConversationState
    let store: ChatStore
    var resent = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(item.text ?? "")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: .rect(cornerRadius: 18))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
        case .assistant:
            AssistantView(
                text: item.text ?? "",
                thinking: item.thinking ?? "",
                toolCalls: item.toolCalls ?? [],
                state: state,
                store: store,
                streaming: false
            )
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
            // Shown inside its call's card; a result whose call is not in view is shown on its own.
            if !state.items.contains(where: { $0.toolCalls?.contains { $0.id == item.callId } == true }) {
                ToolCallCard(call: ToolCallItem(id: item.callId ?? "", name: item.toolName ?? "tool", arguments: "{}"), result: item, live: nil, approval: nil, store: store)
            }
        case .notice:
            Text(item.text ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The streamed partial answer and running tools of the current run.
struct LiveView: View {
    let state: ConversationState
    let store: ChatStore

    var body: some View {
        let live = state.live
        if let generation = live.generation {
            AssistantView(text: generation.text, thinking: generation.thinking, toolCalls: generation.toolCalls, state: state, store: store, streaming: true)
            if let retry = generation.retry {
                Label("Retrying: \(retry.error)", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if live.busy, live.tools.allSatisfy({ $0.status == "done" }) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if live.compacting {
            Label("Summarizing earlier messages…", systemImage: "rectangle.compress.vertical").font(.caption).foregroundStyle(.secondary)
        }
        if let error = live.compactionError {
            Label("Summarizing failed: \(error)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct AssistantView: View {
    let text: String
    let thinking: String
    let toolCalls: [ToolCallItem]
    let state: ConversationState
    let store: ChatStore
    let streaming: Bool
    @State private var showThinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !thinking.isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    Text(thinking).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                } label: {
                    Label(streaming && text.isEmpty ? "Thinking…" : "Thought", systemImage: "brain")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !text.isEmpty {
                Text(markdown(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if streaming, thinking.isEmpty, toolCalls.isEmpty {
                ProgressView().controlSize(.small)
            }
            ForEach(toolCalls, id: \.id) { call in
                ToolCallCard(
                    call: call,
                    result: state.results[call.id],
                    live: state.liveTool(call.id),
                    approval: store.approvals.first { $0.conversationId == state.id && $0.callId == call.id },
                    store: store
                )
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct ToolCallCard: View {
    let call: ToolCallItem
    let result: DisplayItem?
    let live: LiveTool?
    let approval: ApprovalRequest?
    let store: ChatStore
    @State private var expanded = false

    private var status: (String, Color, String) {
        if let result {
            return result.isError == true ? ("xmark.octagon.fill", .red, "Failed") : ("checkmark.circle.fill", .green, "Done")
        }
        if approval != nil { return ("hand.raised.fill", .orange, "Waiting for approval") }
        if let live, live.status == "running" { return ("gearshape.2", .blue, "Running") }
        return ("clock", .secondary, "Pending")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: status.0).foregroundStyle(status.1)
                    Text(call.name).font(.subheadline.monospaced().weight(.medium))
                    Spacer()
                    if result == nil, approval == nil, live?.status == "running" { ProgressView().controlSize(.mini) }
                    Text(status.2).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if let surface = result?.surface {
                if state(for: surface) {
                    SurfaceStrip(surface: surface, store: store)
                } else {
                    Text("\(surface.id) version \(surface.version); newer below").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let approval {
                HStack {
                    Button("Allow") { Task { await store.answer(approval, allow: true) } }.buttonStyle(.borderedProminent).tint(.green)
                    Button("Deny", role: .destructive) { Task { await store.answer(approval, allow: false) } }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            if expanded {
                Text(prettyJSON(call.arguments)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let output = result?.text ?? live?.output, !output.isEmpty {
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

    /// Whether this call holds the surface's newest version in the conversation.
    private func state(for surface: SurfaceRef) -> Bool {
        store.states[surface.conversationId]?.latestSurfaceCall[surface.id].map { $0 == call.id } ?? true
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
