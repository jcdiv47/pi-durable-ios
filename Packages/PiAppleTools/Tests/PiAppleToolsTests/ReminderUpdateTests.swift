import EventKit
import Foundation
import Testing
@testable import PiAppleTools

struct ReminderUpdateTests {
    private func arguments(_ json: String) throws -> CalendarTools.UpdateReminderArguments {
        try JSONDecoder().decode(CalendarTools.UpdateReminderArguments.self, from: Data(json.utf8))
    }

    @Test func editsAndMovesPreserveUnspecifiedFields() throws {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = "Original"
        reminder.notes = "Keep full notes"
        reminder.url = URL(string: "pidurable://reminder/task-42")
        reminder.priority = 1
        let alarm = EKAlarm(absoluteDate: Date(timeIntervalSince1970: 2_000_000_000))
        reminder.addAlarm(alarm)
        reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        let destination = EKCalendar(for: .reminder, eventStore: store)
        destination.title = "Work"
        try CalendarTools.applyUpdate(arguments(#"{"id":"r","title":"Edited"}"#), to: reminder, destination: destination)
        #expect(reminder.title == "Edited")
        #expect(reminder.calendar === destination)
        #expect(reminder.notes == "Keep full notes")
        #expect(reminder.priority == 1)
        #expect(reminder.url?.absoluteString == "pidurable://reminder/task-42")
        #expect(reminder.alarms?.count == 1)
        #expect(reminder.recurrenceRules?.count == 1)
    }

    @Test func dueEditsReplaceTimeAlarmsAndCanClear() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Office")
        location.proximity = .enter
        reminder.addAlarm(location)
        let timed = try arguments(#"{"id":"r","due":"2030-01-02T12:00:00Z"}"#)
        try CalendarTools.applyUpdate(timed, to: reminder, destination: nil)
        try CalendarTools.applyUpdate(timed, to: reminder, destination: nil)
        #expect(reminder.alarms?.count == 2)
        #expect(reminder.dueDateComponents != nil)
        try CalendarTools.applyUpdate(arguments(#"{"id":"r","due":"2030-01-03"}"#), to: reminder, destination: nil)
        #expect(reminder.alarms?.count == 1)
        #expect(reminder.alarms?.first?.structuredLocation?.title == "Office")
        #expect(reminder.dueDateComponents?.hour == nil)
        try CalendarTools.applyUpdate(arguments(#"{"id":"r","clearDue":true,"notes":""}"#), to: reminder, destination: nil)
        #expect(reminder.dueDateComponents == nil)
        #expect(reminder.notes?.isEmpty != false)
    }

    @Test func invalidUpdatesDoNotPartiallyMutate() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "Original"
        for json in [
            #"{"id":"r","title":"Edited","priority":"invalid"}"#,
            #"{"id":"r","title":"Edited","due":"invalid"}"#,
            #"{"id":"r","title":"Edited","due":"2030-01-01","clearDue":true}"#,
            #"{"id":"r","title":"  "}"#,
            #"{"id":"r"}"#,
        ] {
            let args = try arguments(json)
            #expect(throws: AppleToolError.self) { try CalendarTools.applyUpdate(args, to: reminder, destination: nil) }
            #expect(reminder.title == "Original")
        }
    }

    @Test func duplicateListNamesRequireIDs() throws {
        let store = EKEventStore()
        let first = EKCalendar(for: .reminder, eventStore: store)
        let second = EKCalendar(for: .reminder, eventStore: store)
        first.title = "Work"
        second.title = "Work"
        #expect(throws: AppleToolError.self) { try CalendarTools.resolveList(name: "work", id: nil, in: [first, second]) }
        #expect(throws: AppleToolError.self) { try CalendarTools.resolveList(name: "Missing", id: nil, in: [first]) }
        #expect(throws: AppleToolError.self) { try CalendarTools.resolveList(name: "Work", id: "id", in: [first]) }
        #expect(try CalendarTools.resolveList(name: "work", id: nil, in: [first]) === first)
        #expect(try CalendarTools.resolveList(name: nil, id: first.calendarIdentifier, in: [first, second]) === first)
        #expect(try CalendarTools.resolveList(name: nil, id: nil, in: [first]) == nil)
    }
}
