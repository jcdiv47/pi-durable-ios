import ActivityKit
import AppIntents
import PiUI
import SwiftUI
import WidgetKit

/// A conversation's run on the Lock Screen and in the Dynamic Island: what Pi is doing, for how long, and the buttons
/// that need the user (Allow / Deny an approval, Stop).
struct PiRunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiRunAttributes.self) { context in
            RunLockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .widgetURL(conversationURL(context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol).font(.title2).foregroundStyle(.orange).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let detail = context.state.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        RunButtons(attributes: context.attributes, state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundStyle(.orange)
            } compactTrailing: {
                if context.state.approval != nil {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                } else {
                    ElapsedText(state: context.state).monospacedDigit().frame(maxWidth: 44)
                }
            } minimal: {
                Image(systemName: context.state.approval != nil ? "hand.raised.fill" : context.state.symbol).foregroundStyle(.orange)
            }
            .widgetURL(conversationURL(context.attributes))
        }
    }

    private func conversationURL(_ attributes: PiRunAttributes) -> URL? {
        URL(string: "pidurable://conversation/\(attributes.conversationId)")
    }
}

struct RunLockScreenView: View {
    let attributes: PiRunAttributes
    let state: PiRunAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol).font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(state.status).font(.headline).lineLimit(1)
                }
                Spacer()
                ElapsedText(state: state).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let detail = state.detail {
                Text(detail).font(.subheadline).lineLimit(state.finished ? 3 : 2)
            }
            RunButtons(attributes: attributes, state: state)
        }
    }
}

/// Elapsed time ticks by itself while running; a finished run shows its total.
struct ElapsedText: View {
    let state: PiRunAttributes.ContentState

    var body: some View {
        if state.finished {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text(state.startedAt, style: .timer).multilineTextAlignment(.trailing)
        }
    }
}

struct RunButtons: View {
    let attributes: PiRunAttributes
    let state: PiRunAttributes.ContentState

    var body: some View {
        if let approval = state.approval {
            HStack(spacing: 8) {
                Button(intent: AnswerApprovalIntent(approvalId: approval.id, allow: false)) {
                    Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .tint(.red)
                Button(intent: AnswerApprovalIntent(approvalId: approval.id, allow: true)) {
                    Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
            .buttonStyle(.borderedProminent)
            .font(.caption.weight(.semibold))
        } else if !state.finished {
            Button(intent: StopRunIntent(conversationId: attributes.conversationId)) {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .font(.caption.weight(.semibold))
        }
    }
}
