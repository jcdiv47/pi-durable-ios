import AlarmKit
import PiUI
import SwiftUI
import WidgetKit

/// A Pi timer's countdown on the Lock Screen and in the Dynamic Island. AlarmKit starts and ends the Live Activity
/// itself (`AlarmTools` schedules the timer with a countdown); when the timer rings, iOS shows its own alert. A tap opens
/// Pi's Alarms page.
struct PiAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiAlarmAttributes.self) { context in
            AlarmLockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .widgetURL(Self.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "timer").font(.title2).foregroundStyle(context.attributes.tintColor).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AlarmRemaining(state: context.state).font(.title2.monospacedDigit()).foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(label(context.attributes)).font(.headline).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                AlarmRemaining(state: context.state).monospacedDigit().foregroundStyle(context.attributes.tintColor).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(context.attributes.tintColor)
            }
            .widgetURL(Self.url)
        }
    }

    static let url = URL(string: "pidurable://alarms")

    private func label(_ attributes: PiAlarmAttributes) -> String {
        attributes.metadata?.label ?? "Timer"
    }
}

struct AlarmLockScreenView: View {
    let attributes: PiAlarmAttributes
    let state: AlarmPresentationState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer").font(.title2).foregroundStyle(attributes.tintColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pi Timer").font(.caption).foregroundStyle(.secondary)
                Text(attributes.metadata?.label ?? "Timer").font(.headline).lineLimit(1)
            }
            Spacer()
            AlarmRemaining(state: state).font(.largeTitle.monospacedDigit().weight(.semibold)).foregroundStyle(attributes.tintColor)
        }
    }
}

/// The countdown ticks by itself; a paused timer shows what is left; a ringing one shows a bell.
struct AlarmRemaining: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true).multilineTextAlignment(.trailing)
        case .paused(let paused):
            Text(Duration.seconds(max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)), format: .time(pattern: .minuteSecond))
        case .alert:
            Image(systemName: "bell.and.waves.left.and.right.fill")
        @unknown default:
            EmptyView()
        }
    }
}
