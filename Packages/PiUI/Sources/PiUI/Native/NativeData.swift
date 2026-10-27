import EventKit
import Foundation
#if os(iOS)
import HealthKit
import os
#endif

/// Reads the native sources a spec binds (`DataSources.sources`), in the widget on its timeline and in the app
/// for previews and cards. It never asks for permission: a source without it is simply missing, and the
/// spec shows a placeholder. `authorize` asks, and is for the app only (`bind_data`).
public final class NativeData: @unchecked Sendable {
    // Both stores are thread-safe for these reads; one instance keeps their caches.
    private let events = EKEventStore()
    #if os(iOS)
    private let health = HKHealthStore()
    private let healthRequest = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    #endif

    public init() {}

    /// Values for `sources` (names like `health.stepsToday`); `doc.*` and `time.*` are not native and are skipped.
    public func read(_ sources: Set<String>, now: Date = .now) async -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        let calendar = sources.filter { $0.hasPrefix("calendar.") }
        if !calendar.isEmpty, EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            values.merge(readCalendar(now: now)) { $1 }
        }
        let reminders = sources.filter { $0.hasPrefix("reminders.") }
        if !reminders.isEmpty, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            values.merge(await readReminders(now: now)) { $1 }
        }
        #if os(iOS)
        for source in sources where source.hasPrefix("health.") {
            if let value = await readHealth(source, now: now) { values[source] = value }
        }
        #endif
        return values.filter { sources.contains($0.key) }
    }

    public enum Authorization: String, Sendable {
        case granted, denied, notDetermined, unknown, notApplicable
    }

    /// Asks for the permission `source` needs if it was never asked (for Health, every Health source at once), then
    /// reports the state.
    public func authorize(_ source: DataSources.Source) async -> Authorization {
        switch source.permission {
        case .none:
            return .notApplicable
        case .calendar, .reminders:
            let type: EKEntityType = source.permission == .calendar ? .event : .reminder
            if EKEventStore.authorizationStatus(for: type) == .notDetermined {
                _ = try? await (type == .event ? events.requestFullAccessToEvents() : events.requestFullAccessToReminders())
            }
            return switch EKEventStore.authorizationStatus(for: type) {
            case .fullAccess: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .health:
            #if os(iOS)
            guard HKHealthStore.isHealthDataAvailable() else { return .denied }
            // HealthKit never says whether reading was allowed, only whether it already asked.
            guard Self.healthTypes[source.name] != nil else { return .unknown }
            await healthAuthorization().value
            return .unknown
            #else
            return .denied
            #endif
        }
    }

    // MARK: Calendar and reminders

    private func readCalendar(now: Date) -> [String: JSONValue] {
        let cal = Calendar.current
        let endOfDay = cal.startOfDay(for: now).addingTimeInterval(86_400)
        let week = events.predicateForEvents(withStart: cal.startOfDay(for: now), end: now.addingTimeInterval(7 * 86_400), calendars: nil)
        let upcoming = events.events(matching: week).filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
        let today = upcoming.filter { $0.startDate < endOfDay }
        let next = upcoming.first { !$0.isAllDay } ?? upcoming.first
        var values: [String: JSONValue] = [
            "calendar.today": .array(today.map { item($0).json }),
            "calendar.countToday": .number(Double(today.count)),
        ]
        values["calendar.next"] = next.map { item($0).json } ?? .null
        return values
    }

    private func item(_ event: EKEvent) -> SurfaceItem {
        SurfaceItem(title: event.title ?? "Event", subtitle: event.location, date: event.startDate, end: event.endDate)
    }

    private func readReminders(now: Date) async -> [String: JSONValue] {
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [(title: String, due: Date?, list: String?)] = await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { found in
                // EKReminder is not Sendable; copy out the fields inside the callback.
                continuation.resume(returning: (found ?? []).map { ($0.title ?? "Reminder", $0.dueDateComponents?.date, $0.calendar?.title) })
            }
        }
        let sorted = reminders.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        let items = sorted.prefix(20).map { SurfaceItem(title: $0.title, subtitle: $0.list, date: $0.due).json }
        let dueToday = sorted.filter { ($0.due ?? .distantFuture) < endOfDay }.prefix(20).map { SurfaceItem(title: $0.title, subtitle: $0.list, date: $0.due).json }
        return [
            "reminders.open": .array(Array(items)),
            "reminders.dueToday": .array(Array(dueToday)),
            "reminders.countOpen": .number(Double(reminders.count)),
        ]
    }

    // MARK: Health

    #if os(iOS)
    /// The HealthKit type behind each health source, so binding one asks for that type only.
    /// One request for every Health source, shared by parallel `bind_data` calls: HealthKit cannot present a
    /// request's sheet while another one's is presenting, and never calls that request back.
    private func healthAuthorization() -> Task<Void, Never> {
        healthRequest.withLock { request in
            if let request { return request }
            let task = Task { [health] in _ = try? await health.requestAuthorization(toShare: [], read: Set(Self.healthTypes.values)) }
            request = task
            return task
        }
    }

    static let healthTypes: [String: HKObjectType] = [
        "health.stepsToday": HKQuantityType(.stepCount), "health.stepsWeek": HKQuantityType(.stepCount),
        "health.activeEnergyToday": HKQuantityType(.activeEnergyBurned), "health.activeEnergyWeek": HKQuantityType(.activeEnergyBurned),
        "health.distanceToday": HKQuantityType(.distanceWalkingRunning), "health.flightsToday": HKQuantityType(.flightsClimbed),
        "health.restingHeartRate": HKQuantityType(.restingHeartRate),
        "health.sleepLastNight": HKCategoryType(.sleepAnalysis), "health.sleepWeek": HKCategoryType(.sleepAnalysis),
    ]

    private func readHealth(_ source: String, now: Date) async -> JSONValue? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let midnight = Calendar.current.startOfDay(for: now)
        do {
            switch source {
            // A day's total with no samples is 0: HealthKit cannot tell "not allowed" from "nothing recorded" anyway.
            case "health.stepsToday": return .number((try await sum(.stepCount, .count(), from: midnight, to: now) ?? 0).rounded())
            case "health.activeEnergyToday": return .number((try await sum(.activeEnergyBurned, .kilocalorie(), from: midnight, to: now) ?? 0).rounded())
            case "health.distanceToday": return .number(((try await sum(.distanceWalkingRunning, .meter(), from: midnight, to: now) ?? 0) / 100).rounded() / 10)
            case "health.flightsToday": return .number((try await sum(.flightsClimbed, .count(), from: midnight, to: now) ?? 0).rounded())
            case "health.restingHeartRate": return try await latest(.restingHeartRate, .count().unitDivided(by: .minute()), since: now.addingTimeInterval(-7 * 86_400)).map { .number($0.rounded()) }
            case "health.sleepLastNight": return .number(((try await asleepHours(from: midnight.addingTimeInterval(-6 * 3600), to: now)) * 10).rounded() / 10)
            case "health.stepsWeek": return try await week(.stepCount, .count(), now: now)
            case "health.activeEnergyWeek": return try await week(.activeEnergyBurned, .kilocalorie(), now: now)
            case "health.sleepWeek": return try await sleepWeek(now: now)
            default: return nil
            }
        } catch {
            return nil
        }
    }

    private func sum(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, from: Date, to: Date) async throws -> Double? {
        let type = HKQuantityType(identifier)
        let predicate = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: to))
        let statistics = try await HKStatisticsQueryDescriptor(predicate: predicate, options: .cumulativeSum).result(for: health)
        return statistics?.sumQuantity()?.doubleValue(for: unit)
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, since: Date) async throws -> Double? {
        let type = HKQuantityType(identifier)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try await descriptor.result(for: health).first?.quantity.doubleValue(for: unit)
    }

    private func week(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, now: Date) async throws -> JSONValue {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        var values: [JSONValue] = []
        var labels: [JSONValue] = []
        for offset in 0 ..< 7 {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let end = min(calendar.date(byAdding: .day, value: 1, to: day)!, now)
            values.append(.number((try await sum(identifier, unit, from: day, to: end) ?? 0).rounded()))
            labels.append(.string(day.formatted(.dateTime.weekday(.narrow))))
        }
        return .object(["values": .array(values), "labels": .array(labels)])
    }

    private func asleepHours(from: Date, to: Date) async throws -> Double {
        let type = HKCategoryType(.sleepAnalysis)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: to))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let seconds = try await descriptor.result(for: health).filter { asleep.contains($0.value) }.reduce(0.0) { total, sample in
            total + max(0, min(sample.endDate, to).timeIntervalSince(max(sample.startDate, from)))
        }
        return seconds / 3600
    }

    private func sleepWeek(now: Date) async throws -> JSONValue {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var values: [JSONValue] = []
        var labels: [JSONValue] = []
        for offset in (0 ..< 7).reversed() {
            let morning = calendar.date(byAdding: .day, value: -offset, to: today)!
            let hours = try await asleepHours(from: morning.addingTimeInterval(-6 * 3600), to: min(morning.addingTimeInterval(12 * 3600), now))
            values.append(.number((hours * 10).rounded() / 10))
            labels.append(.string(morning.formatted(.dateTime.weekday(.narrow))))
        }
        return .object(["values": .array(values), "labels": .array(labels)])
    }
    #endif
}
