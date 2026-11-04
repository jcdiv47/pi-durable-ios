#if os(iOS)
import AlarmKit
import CryptoKit
import Foundation
import PiUI
import SwiftUI

/// Pi's alarms, through AlarmKit: they ring like the Clock app's, through silent mode and Focus. The first call asks
/// for permission. iOS lists only this app's alarms, so `alarms_list` and `alarms_cancel` never see the Clock app's,
/// and the Clock app never shows Pi's: the app's Alarms page (`PiAlarms.summaries`) does. A timer (`afterSeconds`)
/// counts down on the Lock Screen and in the Dynamic Island (the widget extension's `PiAlarmLiveActivity`).
///
/// An alarm's ID is derived from the tool task's idempotency key, so a call that runs again after a crash finds the
/// alarm it already scheduled instead of adding a second one.
final class AlarmTools: Sendable {
    struct SetArguments: Decodable {
        let label: String
        /// A one-off alarm at this moment.
        let at: String?
        /// A timer: rings this many seconds from now.
        let afterSeconds: Double?
        /// A time of day, `HH:mm`: the next one, or every listed weekday.
        let time: String?
        let weekdays: [String]?
        let idempotencyKey: String
    }

    struct CancelArguments: Decodable {
        let id: String
    }

    func set(_ args: SetArguments) async throws -> [String: Any] {
        try await authorize()
        let id = Self.id(for: args.idempotencyKey)
        if let existing = try AlarmManager.shared.alarms.first(where: { $0.id == id }) {
            return ["alarm": describe(existing), "alreadyScheduled": true]
        }
        if let label = PiAlarms.labels()[id.uuidString] {
            return ["alarm": ["id": id.uuidString, "label": label], "alreadyScheduled": true, "note": "It has already rung or been cancelled."]
        }
        let label = args.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw AppleToolError("label is empty") }
        let kind = try Self.kind(args)
        let attributes = PiAlarmAttributes(presentation: Self.presentation(label, countdown: kind.isTimer), metadata: PiAlarmMetadata(label: label), tintColor: .orange)
        let configuration: AlarmManager.AlarmConfiguration<PiAlarmMetadata>
        switch kind {
        case .timer(let seconds): configuration = .timer(duration: seconds, attributes: attributes)
        case .alarm(let schedule): configuration = .alarm(schedule: schedule, attributes: attributes)
        }
        do {
            let alarm = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            if case .timer(let seconds) = kind { PiAlarms.setTimerEnd(Date.now.addingTimeInterval(seconds), for: id) }
            PiAlarms.setLabel(label, for: id)
            return ["alarm": describe(alarm)]
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw AppleToolError("Pi has as many alarms as iOS allows. Cancel one with alarms_cancel first.")
        }
    }

    func list() async throws -> [String: Any] {
        guard AlarmManager.shared.authorizationState == .authorized else { return ["alarms": [], "note": "Pi has not been allowed to set alarms yet."] }
        let alarms = try AlarmManager.shared.alarms
        return ["alarms": alarms.sorted { (PiAlarms.nextDate($0) ?? .distantFuture) < (PiAlarms.nextDate($1) ?? .distantFuture) }.map(describe)]
    }

    /// Cancelling an alarm that is already gone succeeds, so a replayed call is harmless.
    func cancel(_ args: CancelArguments) async throws -> [String: Any] {
        guard let id = UUID(uuidString: args.id) else { throw AppleToolError("id is not an alarm ID from alarms_list: \(args.id)") }
        guard AlarmManager.shared.authorizationState == .authorized,
              let alarm = try AlarmManager.shared.alarms.first(where: { $0.id == id })
        else { return ["cancelled": false, "id": args.id, "note": "No such alarm; it may have rung or been cancelled already."] }
        let described = describe(alarm)
        try AlarmManager.shared.cancel(id: id)
        return ["cancelled": true, "alarm": described]
    }

    // MARK: Permission

    private func authorize() async throws {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return
        case .denied: throw AppleToolError("Pi is not allowed to set alarms. The user can turn it on in Settings › Apps › Pi › Alarms & Timers.")
        case .notDetermined: break
        @unknown default: break
        }
        if try await AlarmManager.shared.requestAuthorization() != .authorized {
            throw AppleToolError("The user did not allow Pi to set alarms.")
        }
    }

    // MARK: Schedules

    enum Kind {
        case timer(TimeInterval)
        case alarm(Alarm.Schedule)

        var isTimer: Bool { if case .timer = self { true } else { false } }
    }

    static func id(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("pi-alarm:\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // a name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func kind(_ args: SetArguments, now: Date = .now) throws -> Kind {
        let given = [args.at != nil, args.afterSeconds != nil, args.time != nil].filter { $0 }.count
        guard given == 1 else { throw AppleToolError("Give exactly one of at, afterSeconds or time.") }
        if args.weekdays?.isEmpty == false, args.time == nil { throw AppleToolError("weekdays needs time.") }
        if let at = args.at {
            let date = try ISODate.parse(at, field: "at")
            guard date > now else { throw AppleToolError("at is in the past: \(at). Call current_time for the time.") }
            return .alarm(.fixed(date))
        }
        if let seconds = args.afterSeconds {
            guard seconds >= 1, seconds <= 7 * 86_400 else { throw AppleToolError("afterSeconds must be between 1 and 604800.") }
            return .timer(seconds)
        }
        let parts = args.time!.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            throw AppleToolError("time must be HH:mm, 24-hour: \(args.time!)")
        }
        let weekdays = try (args.weekdays ?? []).map(weekday)
        return .alarm(.relative(.init(time: .init(hour: parts[0], minute: parts[1]), repeats: weekdays.isEmpty ? .never : .weekly(weekdays))))
    }

    private static func weekday(_ name: String) throws -> Locale.Weekday {
        guard let day = PiAlarms.weekdayNames.first(where: { $0.0 == name.lowercased() })?.1 else {
            throw AppleToolError("Unknown weekday: \(name). Use monday … sunday.")
        }
        return day
    }

    private static func presentation(_ label: String, countdown: Bool) -> AlarmPresentation {
        let title = LocalizedStringResource(stringLiteral: label)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = .init(title: title)
        } else {
            alert = .init(title: title, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        return AlarmPresentation(alert: alert, countdown: countdown ? .init(title: title) : nil)
    }

    private func describe(_ alarm: Alarm) -> [String: Any] {
        let summary = PiAlarms.summary(alarm)
        var result: [String: Any] = ["id": alarm.id.uuidString, "state": "\(alarm.state)", "label": summary.label]
        if let next = summary.next { result["next"] = ISODate.format(next) }
        if summary.isTimer { result["timer"] = true }
        if case .relative(let relative) = alarm.schedule {
            result["time"] = String(format: "%02d:%02d", relative.time.hour, relative.time.minute)
        }
        if !summary.weekdays.isEmpty { result["weekdays"] = summary.weekdays }
        return result
    }
}

/// Pi's alarms for the app's Alarms page, and what AlarmKit does not give back: labels and timers' end times, kept in
/// the app's defaults by alarm ID. Labels are never removed: a label is also the record that an alarm was scheduled,
/// so a call replayed after its alarm rang does not set it again.
public enum PiAlarms {
    public struct Summary: Identifiable, Sendable {
        public let id: UUID
        public let label: String
        /// When it rings next; nil while a timer is paused or for a timer whose end was never recorded.
        public let next: Date?
        public let isTimer: Bool
        public let ringing: Bool
        /// Lowercase English weekday names a repeating alarm rings on.
        public let weekdays: [String]
    }

    private static let labelsKey = "pi.alarmLabels"
    private static let timerEndsKey = "pi.timerEnds"

    static let weekdayNames: [(String, Locale.Weekday)] = [
        ("monday", .monday), ("tuesday", .tuesday), ("wednesday", .wednesday), ("thursday", .thursday),
        ("friday", .friday), ("saturday", .saturday), ("sunday", .sunday),
    ]

    /// Pi's alarms, soonest first. Empty until the user allows alarms; never asks.
    public static func current() -> [Summary] {
        guard AlarmManager.shared.authorizationState == .authorized else { return [] }
        return summaries((try? AlarmManager.shared.alarms) ?? [])
    }

    public static func summaries(_ alarms: [Alarm]) -> [Summary] {
        alarms.map(summary).sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) }
    }

    public static func cancel(_ id: UUID) throws {
        try AlarmManager.shared.cancel(id: id)
    }

    static func summary(_ alarm: Alarm) -> Summary {
        var weekdays: [String] = []
        if case .relative(let relative) = alarm.schedule, case .weekly(let days) = relative.repeats {
            weekdays = days.compactMap { day in weekdayNames.first { $0.1 == day }?.0 }
        }
        return Summary(
            id: alarm.id,
            label: labels()[alarm.id.uuidString] ?? "Alarm",
            next: nextDate(alarm),
            isTimer: alarm.schedule == nil,
            ringing: alarm.state == .alerting,
            weekdays: weekdays
        )
    }

    /// When an alarm rings next, for sorting, the Alarms page and the model.
    static func nextDate(_ alarm: Alarm, now: Date = .now) -> Date? {
        switch alarm.schedule {
        case .fixed(let date): return date
        case .relative(let relative):
            let calendar = Calendar.current
            let time = DateComponents(hour: relative.time.hour, minute: relative.time.minute)
            switch relative.repeats {
            case .never:
                return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
            case .weekly(let days):
                let numbers = days.compactMap { day in weekdayNames.firstIndex { $0.1 == day }.map { ($0 + 1) % 7 + 1 } }
                return numbers.compactMap { number in
                    var components = time
                    components.weekday = number
                    return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
                }.min()
            @unknown default: return nil
            }
        case nil:
            return alarm.state == .paused ? nil : timerEnds()[alarm.id.uuidString].map(Date.init(timeIntervalSince1970:))
        @unknown default: return nil
        }
    }

    static func labels() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
    }

    static func setLabel(_ label: String, for id: UUID) {
        var all = labels()
        all[id.uuidString] = label
        UserDefaults.standard.set(all, forKey: labelsKey)
    }

    private static func timerEnds() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: timerEndsKey) as? [String: Double] ?? [:]
    }

    static func setTimerEnd(_ end: Date, for id: UUID) {
        var all = timerEnds()
        all[id.uuidString] = end.timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: timerEndsKey)
    }
}
#endif
