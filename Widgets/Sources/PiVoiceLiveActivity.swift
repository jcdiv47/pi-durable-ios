import ActivityKit
import AppIntents
import PiUI
import SwiftUI
import WidgetKit

/// Talk to Pi as a control: for the Action button (Settings › Action Button › Controls), Control Center and the Lock
/// Screen. It runs `TalkToPiIntent`, which listens without opening the app; a second press hangs up.
struct PiVoiceControl: ControlWidget {
    static let kind = "dev.jcdiv47.pidurable.voice"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: TalkToPiIntent()) {
                Label("Talk to Pi", systemImage: "waveform")
            }
        }
        .displayName("Talk to Pi")
        .description("Ask Pi something aloud. Pi does it and answers.")
    }
}

/// A voice session on the Lock Screen and in the Dynamic Island: what Pi is doing, the last thing said, Allow / Deny
/// when Pi waits for approval, and End.
struct PiVoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiVoiceAttributes.self) { context in
            VoiceLockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .widgetURL(Self.url(context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol).font(.title2).foregroundStyle(.tint).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceElapsed(attributes: context.attributes, state: context.state).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let line = context.state.line { Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        VoiceButtons(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.tint)
            } compactTrailing: {
                Image(systemName: context.state.approval != nil ? "hand.raised.fill" : context.state.symbol)
                    .foregroundStyle(context.state.approval != nil ? .orange : .secondary)
            } minimal: {
                Image(systemName: context.state.approval != nil ? "hand.raised.fill" : "waveform").foregroundStyle(.tint)
            }
            .widgetURL(Self.url(context.state))
        }
    }

    /// The voice screen while talking; once ended, the conversation, so a tap does not start listening again.
    static func url(_ state: PiVoiceAttributes.ContentState) -> URL? {
        if state.ended, let id = state.conversationId { return URL(string: "pidurable://conversation/\(id)") }
        return URL(string: "pidurable://voice")
    }
}

struct VoiceLockScreenView: View {
    let attributes: PiVoiceAttributes
    let state: PiVoiceAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol).font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Talking to Pi").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(state.status).font(.headline).lineLimit(1)
                }
                Spacer()
                VoiceElapsed(attributes: attributes, state: state).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let line = state.line {
                Text(line).font(.subheadline).lineLimit(2)
            }
            VoiceButtons(state: state)
        }
    }
}

private struct VoiceElapsed: View {
    let attributes: PiVoiceAttributes
    let state: PiVoiceAttributes.ContentState

    var body: some View {
        if state.ended {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text(attributes.startedAt, style: .timer).multilineTextAlignment(.trailing).frame(maxWidth: 52)
        }
    }
}

private struct VoiceButtons: View {
    let state: PiVoiceAttributes.ContentState

    var body: some View {
        if let approval = state.approval {
            VStack(alignment: .leading, spacing: 6) {
                Text(approval.action).font(.caption.weight(.semibold)).lineLimit(1)
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
            }
        } else if !state.ended {
            Button(intent: EndVoiceIntent()) {
                Label("End", systemImage: "xmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .font(.caption.weight(.semibold))
        }
    }
}
