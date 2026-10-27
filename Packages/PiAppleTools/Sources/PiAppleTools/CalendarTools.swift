import EventKit
import Foundation

/// EventKit handlers: calendar and reminder reads, and event creation that a rerun cannot duplicate.
final class CalendarTools: @unchecked Sendable {
    // EKEventStore is thread-safe for these calls; one store keeps its cache across tool calls.
    private let store = EKEventStore()

    struct QueryArguments: Decodable {
        let start: String
        let end: String
        let search: String?
        let limit: Int?
    }

    struct CreateArguments: Decodable {
        let title: String
        let start: String
        let end: String
        let allDay: Bool?
        let location: String?
        let notes: String?
        /// From the tool task's ID: the same call after a crash finds its event instead of adding another.
        let idempotencyKey: String
    }

    struct ReminderArguments: Decodable {
        let includeCompleted: Bool?
        let dueBefore: String?
        let list: String?
        let limit: Int?
    }

    func query(_ args: QueryArguments) async throws -> [String: Any] {
        try await requireAccess(.event)
        let start = try ISODate.parse(args.start, field: "start")
        let end = try ISODate.parse(args.end, field: "end")
        guard end > start else { throw AppleToolError("end must be after start") }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let search = args.search?.lowercased(), !search.isEmpty {
            events = events.filter { event in
                [event.title, event.location, event.notes].compactMap(\.self).contains { $0.lowercased().contains(search) }
            }
        }
        let limit = max(1, args.limit ?? 50)
        return [
            "count": events.count,
            "truncated": events.count > limit,
            "events": events.prefix(limit).map(describe),
        ]
    }

    func createEvent(_ args: CreateArguments) async throws -> [String: Any] {
        try await requireAccess(.event)
        let start = try ISODate.parse(args.start, field: "start")
        let end = try ISODate.parse(args.end, field: "end")
        guard end >= start else { throw AppleToolError("end must not be before start") }
        let tag = URL(string: "pidurable://event/\(args.idempotencyKey)")!
        let window = store.predicateForEvents(withStart: start.addingTimeInterval(-86_400), end: end.addingTimeInterval(86_400), calendars: nil)
        if let existing = store.events(matching: window).first(where: { $0.url == tag }) {
            return ["created": false, "alreadyExisted": true, "event": describe(existing)]
        }
        guard let calendar = store.defaultCalendarForNewEvents else { throw AppleToolError("There is no default calendar for new events") }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = args.title
        event.startDate = start
        event.endDate = end
        event.isAllDay = args.allDay ?? false
        event.location = args.location
        event.notes = args.notes
        event.url = tag
        try store.save(event, span: .thisEvent, commit: true)
        return ["created": true, "event": describe(event)]
    }

    func reminders(_ args: ReminderArguments) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        var calendars = store.calendars(for: .reminder)
        if let list = args.list?.lowercased(), !list.isEmpty {
            calendars = calendars.filter { $0.title.lowercased() == list }
            guard !calendars.isEmpty else {
                let names = store.calendars(for: .reminder).map(\.title)
                throw AppleToolError("No reminder list named \(args.list!). Lists: \(names.joined(separator: ", "))")
            }
        }
        let dueBefore = try args.dueBefore.map { try ISODate.parse($0, field: "dueBefore") }
        let predicate = args.includeCompleted == true
            ? store.predicateForReminders(in: calendars)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: calendars)
        let limit = max(1, args.limit ?? 50)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                var items = (reminders ?? []).map { reminder -> [String: Any] in
                    var item: [String: Any] = [
                        "title": reminder.title ?? "",
                        "completed": reminder.isCompleted,
                        "list": reminder.calendar?.title ?? "",
                        "priority": reminder.priority,
                    ]
                    if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) { item["due"] = ISODate.format(date) }
                    if let notes = reminder.notes, !notes.isEmpty { item["notes"] = String(notes.prefix(300)) }
                    return item
                }
                if let dueBefore {
                    items = items.filter { ($0["due"] as? String).flatMap { try? ISODate.parse($0, field: "due") }.map { $0 < dueBefore } ?? false }
                }
                items.sort { ($0["due"] as? String ?? "~") < ($1["due"] as? String ?? "~") }
                continuation.resume(returning: ["count": items.count, "truncated": items.count > limit, "reminders": Array(items.prefix(limit))])
            }
        }
    }

    private func describe(_ event: EKEvent) -> [String: Any] {
        var item: [String: Any] = [
            "title": event.title ?? "",
            "start": ISODate.format(event.startDate),
            "end": ISODate.format(event.endDate),
            "allDay": event.isAllDay,
            "calendar": event.calendar?.title ?? "",
        ]
        if let location = event.location, !location.isEmpty { item["location"] = location }
        if let notes = event.notes, !notes.isEmpty { item["notes"] = String(notes.prefix(300)) }
        return item
    }

    private func requireAccess(_ type: EKEntityType) async throws {
        let name = type == .event ? "Calendar" : "Reminders"
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders()
            if granted { return }
        default:
            break
        }
        throw AppleToolError("\(name) access is not allowed. The user can turn it on in Settings › Privacy & Security › \(name).")
    }
}
