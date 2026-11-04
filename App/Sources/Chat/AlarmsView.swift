import AlarmKit
import PiAppleTools
import SwiftUI

/// Settings › Alarms & Timers (`pidurable://alarms`, where a timer's Live Activity opens): the alarms and timers Pi set,
/// each counting down to when it rings, and swipe to cancel. The Clock app never shows them; iOS lists an app's
/// alarms only to that app.
struct AlarmsView: View {
    @State private var alarms: [PiAlarms.Summary] = PiAlarms.current()
    @State private var error: String?

    var body: some View {
        List {
            if alarms.isEmpty {
                ContentUnavailableView("No Alarms", systemImage: "alarm", description: Text("Ask Pi to wake you up or to set a timer."))
            }
            ForEach(alarms) { alarm in
                AlarmRow(alarm: alarm)
                    .swipeActions {
                        Button("Cancel", systemImage: "trash", role: .destructive) { cancel(alarm) }
                    }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("Alarms & Timers")
        .task {
            for await all in AlarmManager.shared.alarmUpdates {
                alarms = PiAlarms.summaries(all)
            }
        }
    }

    private func cancel(_ alarm: PiAlarms.Summary) {
        do {
            try PiAlarms.cancel(alarm.id)
            alarms.removeAll { $0.id == alarm.id }
        } catch {
            self.error = "Could not cancel \u{201C}\(alarm.label)\u{201D}: \(error.localizedDescription)"
        }
    }
}

private struct AlarmRow: View {
    let alarm: PiAlarms.Summary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alarm.ringing ? "bell.and.waves.left.and.right.fill" : alarm.isTimer ? "timer" : "alarm")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.label).font(.headline).lineLimit(2)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            remaining.font(.title3.monospacedDigit()).foregroundStyle(alarm.ringing ? .orange : .primary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var remaining: some View {
        if alarm.ringing {
            Text("Ringing")
        } else if let next = alarm.next {
            // A live countdown under a day away; further out, how long until it rings.
            if next.timeIntervalSinceNow < 86_400 {
                Text(timerInterval: Date.now...max(Date.now, next), countsDown: true).multilineTextAlignment(.trailing)
            } else {
                Text(next, style: .relative)
            }
        } else {
            Text(alarm.isTimer ? "Paused" : "—").foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        guard let next = alarm.next else { return alarm.isTimer ? "Timer" : "Alarm" }
        let time = next.formatted(date: .omitted, time: .shortened)
        if !alarm.weekdays.isEmpty {
            let days = alarm.weekdays.count == 7 ? "Every day"
                : Set(alarm.weekdays) == ["monday", "tuesday", "wednesday", "thursday", "friday"] ? "Weekdays"
                : Set(alarm.weekdays) == ["saturday", "sunday"] ? "Weekends"
                : alarm.weekdays.map { $0.prefix(3).capitalized }.joined(separator: ", ")
            return "\(time), \(days)"
        }
        let day = Calendar.current.isDateInToday(next) ? "Today" : Calendar.current.isDateInTomorrow(next) ? "Tomorrow"
            : next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return alarm.isTimer ? "Timer, rings at \(time)" : "\(day), \(time)"
    }
}
