import EventKit
import Foundation

/// EventKit handlers: calendar and reminder reads, and event and reminder writes that a rerun cannot duplicate.
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
        let listId: String?
        let limit: Int?
    }

    struct CreateReminderArguments: Decodable {
        let title: String
        /// A date-time (due then, with an alert) or a bare date (due that day, no alert).
        let due: String?
        let list: String?
        let listId: String?
        let notes: String?
        let priority: String?
        /// From the tool task's ID, as for events.
        let idempotencyKey: String
    }

    struct UpdateReminderArguments: Decodable {
        let id: String
        let title: String?
        let notes: String?
        let priority: String?
        let due: String?
        let clearDue: Bool?
        let list: String?
        let listId: String?
    }

    /// Resolve exactly one list. Never silently pick an account when titles collide.
    static func resolveList(name: String?, id: String?, in lists: [EKCalendar]) throws -> EKCalendar? {
        guard name == nil || id == nil else { throw AppleToolError("Use either list or listId, not both") }
        guard name != nil || id != nil else { return nil }
        let matches = lists.filter { calendar in
            if let id { return calendar.calendarIdentifier == id }
            return calendar.title.caseInsensitiveCompare(name!) == .orderedSame
        }
        guard matches.count == 1 else {
            throw AppleToolError(matches.isEmpty ? "Reminder list not found. Call reminders_lists for current IDs." : "Multiple lists have that name. Call reminders_lists and use listId.")
        }
        return matches[0]
    }

    func reminderLists() async throws -> [String: Any] {
        try await requireAccess(.reminder)
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let lists = store.calendars(for: .reminder).map { calendar -> [String: Any] in
            ["id": calendar.calendarIdentifier, "title": calendar.title,
             "account": calendar.source?.title ?? "", "writable": calendar.allowsContentModifications,
             "isDefault": calendar.calendarIdentifier == defaultID]
        }
        return ["lists": lists]
    }

    func updateReminder(_ args: UpdateReminderArguments) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        guard let reminder = store.calendarItem(withIdentifier: args.id) as? EKReminder else {
            throw AppleToolError("Reminder not found. Call reminders_query for current IDs.")
        }
        guard reminder.calendar.allowsContentModifications else { throw AppleToolError("The source list is read-only") }
        let destination = try Self.resolveList(name: args.list, id: args.listId, in: store.calendars(for: .reminder))
        if let destination, !destination.allowsContentModifications { throw AppleToolError("The destination list is read-only") }
        // Roll back cached edits if validation or EventKit saving fails.
        do {
            try Self.applyUpdate(args, to: reminder, destination: destination)
            try store.save(reminder, commit: true)
        } catch {
            store.reset()
            throw error
        }
        return ["updated": true, "reminder": describe(reminder)]
    }

    static func applyUpdate(_ args: UpdateReminderArguments, to reminder: EKReminder, destination: EKCalendar?) throws {
        guard args.title != nil || args.notes != nil || args.priority != nil || args.due != nil || args.clearDue == true || destination != nil else {
            throw AppleToolError("Supply at least one field to update")
        }
        guard args.due == nil || args.clearDue != true else { throw AppleToolError("Use due or clearDue, not both") }
        if let title = args.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppleToolError("title must not be empty")
        }
        let priorities = ["none": 0, "high": 1, "medium": 5, "low": 9]
        if let priority = args.priority, priorities[priority] == nil { throw AppleToolError("Invalid priority") }
        let dueDate = try args.due.map { try ISODate.parse($0, field: "due") }
        // Validate everything before changing the cached EventKit object. Preserve URL (creation deduplication),
        // recurrence and any other fields the caller did not supply.
        if let title = args.title { reminder.title = title }
        if let notes = args.notes { reminder.notes = notes }
        if let priority = args.priority { reminder.priority = priorities[priority]! }
        if let destination { reminder.calendar = destination }
        if args.clearDue == true || dueDate != nil {
            reminder.alarms = reminder.alarms?.filter { $0.structuredLocation != nil }
            reminder.dueDateComponents = nil
            if let dueDate {
                let dateOnly = args.due!.count == 10
                let components: Set<Calendar.Component> = dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .timeZone]
                reminder.dueDateComponents = Calendar.current.dateComponents(components, from: dueDate)
                if !dateOnly { reminder.addAlarm(EKAlarm(absoluteDate: dueDate)) }
            }
        }
    }

    struct CompleteReminderArguments: Decodable {
        let id: String
        let completed: Bool?
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

    func createReminder(_ args: CreateReminderArguments) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        let tag = URL(string: "pidurable://reminder/\(args.idempotencyKey)")!
        // Completed ones too: the reminder may have been ticked off before the call ran again.
        let all = try await fetch(store.predicateForReminders(in: nil))
        if let existing = all.first(where: { $0.url == tag }) {
            return ["created": false, "alreadyExisted": true, "reminder": describe(existing)]
        }
        let calendar: EKCalendar
        if let selected = try Self.resolveList(name: args.list, id: args.listId, in: store.calendars(for: .reminder)) {
            calendar = selected
        } else {
            guard let fallback = store.defaultCalendarForNewReminders() else { throw AppleToolError("There is no default list for new reminders") }
            calendar = fallback
        }
        guard calendar.allowsContentModifications else { throw AppleToolError("The list is read-only") }
        let priorities = ["none": 0, "high": 1, "medium": 5, "low": 9]
        guard let priority = priorities[args.priority ?? "none"] else { throw AppleToolError("priority must be none, low, medium or high") }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = args.title
        reminder.notes = args.notes
        reminder.priority = priority
        reminder.url = tag
        if let due = args.due {
            let date = try ISODate.parse(due, field: "due")
            let dateOnly = due.count == 10
            let components: Set<Calendar.Component> = dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .timeZone]
            reminder.dueDateComponents = Calendar.current.dateComponents(components, from: date)
            if !dateOnly { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        try store.save(reminder, commit: true)
        return ["created": true, "reminder": describe(reminder)]
    }

    /// Marks a reminder done (or not done). Setting the state it already has changes nothing, so a rerun is harmless.
    func completeReminder(_ args: CompleteReminderArguments) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        guard let reminder = store.calendarItem(withIdentifier: args.id) as? EKReminder else {
            throw AppleToolError("No reminder with id \(args.id). Call reminders_query for current IDs.")
        }
        let completed = args.completed ?? true
        let changed = reminder.isCompleted != completed
        if changed {
            reminder.isCompleted = completed
            try store.save(reminder, commit: true)
        }
        return ["changed": changed, "reminder": describe(reminder)]
    }

    func reminders(_ args: ReminderArguments) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        var calendars = store.calendars(for: .reminder)
        if let selected = try Self.resolveList(name: args.list, id: args.listId, in: calendars) {
            calendars = [selected]
        }
        let dueBefore = try args.dueBefore.map { try ISODate.parse($0, field: "dueBefore") }
        let predicate = args.includeCompleted == true
            ? store.predicateForReminders(in: calendars)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: calendars)
        let limit = max(1, args.limit ?? 50)
        var items = try await fetch(predicate).map(describe)
        if let dueBefore {
            items = items.filter { ($0["due"] as? String).flatMap { try? ISODate.parse($0, field: "due") }.map { $0 < dueBefore } ?? false }
        }
        items.sort { ($0["due"] as? String ?? "~") < ($1["due"] as? String ?? "~") }
        return ["count": items.count, "truncated": items.count > limit, "reminders": Array(items.prefix(limit))]
    }

    /// EKReminder is not Sendable; the callback hands them over once, and nothing else touches them.
    private func fetch(_ predicate: NSPredicate) async throws -> [EKReminder] {
        nonisolated(unsafe) var result: [EKReminder] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                result = reminders ?? []
                continuation.resume()
            }
        }
        return result
    }

    private func describe(_ reminder: EKReminder) -> [String: Any] {
        var item: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "completed": reminder.isCompleted,
            "list": reminder.calendar?.title ?? "",
            "listId": reminder.calendar?.calendarIdentifier ?? "",
            "priority": reminder.priority,
        ]
        if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) { item["due"] = ISODate.format(date) }
        if let notes = reminder.notes, !notes.isEmpty { item["notes"] = String(notes.prefix(300)) }
        return item
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

    /// Each reminder list's or calendar's color by title. Empty without access: it never asks.
    func colors(_ type: EKEntityType) -> [String: CGColor] {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return [:] }
        return Dictionary(store.calendars(for: type).compactMap { calendar in calendar.cgColor.map { (calendar.title, $0) } }) { first, _ in first }
    }

    /// Whether each reminder is done now, by ID; reminders that are gone are left out. Empty without access.
    func completion(_ ids: [String]) -> [String: Bool] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [:] }
        var states: [String: Bool] = [:]
        for id in ids {
            if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder { states[id] = reminder.isCompleted }
        }
        return states
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
