import PiUI
import SwiftUI

/// What a tool does, in the words a person uses: the approval sheet, the approval rows in the conversation list and the
/// inline approval card lead with it, and keep the tool's own name as a detail. Tools without an entry (MCP servers'
/// tools, new ones) show their name.
enum ToolTitles {
    struct Title {
        /// "Add an event to Calendar".
        let action: String
        let symbol: String
        let tint: Color
    }

    static func title(for tool: String) -> Title {
        switch tool {
        case "calendar_create_event": Title(action: "Add an event to Calendar", symbol: "calendar.badge.plus", tint: .red)
        case "reminders_create": Title(action: "Add a reminder", symbol: "checklist", tint: .orange)
        case "reminders_update": Title(action: "Change a reminder", symbol: "checklist", tint: .orange)
        case "alarms_set": Title(action: "Set an alarm", symbol: "alarm.fill", tint: .orange)
        case "publish_surface": Title(action: "Put a widget on your Home Screen", symbol: "square.grid.2x2.fill", tint: .cyan)
        case "schedule_task": Title(action: "Schedule a task", symbol: "clock.arrow.circlepath", tint: .pink)
        case "web_fetch": Title(action: "Read a web page", symbol: "globe", tint: .blue)
        case "ssh_exec": Title(action: "Run a command on your machine", symbol: "terminal.fill", tint: .mint)
        case "http_get": Title(action: "Read from your API", symbol: "network", tint: .indigo)
        case "http_send": Title(action: "Send a request to your API", symbol: "paperplane.fill", tint: .indigo)
        case "codemode": Title(action: "Run a script that uses Pi's tools", symbol: "curlybraces", tint: .indigo)
        default: Title(action: "Run \(tool)", symbol: "wrench.and.screwdriver.fill", tint: .gray)
        }
    }

    static func action(for tool: String) -> String { title(for: tool).action }
}

/// A tool call's arguments as the approval sheet lists them: what the call is about first (title, label, URL), then when,
/// then the rest; keys as words ("allDay" → "All day"), and ISO 8601 dates as the user's own date and time.
enum ApprovalDetails {
    private static let order = ["title", "label", "name", "url", "host", "command", "endpoint", "method", "path", "query", "start", "end", "at", "due", "time", "afterSeconds", "every", "weekdays", "allDay", "location", "list", "notes", "prompt"]

    static func rows(_ arguments: JSONValue) -> [(key: String, label: String, value: String)] {
        let fields = arguments.fields
        let ranked = fields.sorted { a, b in
            let ia = order.firstIndex(of: a.0) ?? order.count
            let ib = order.firstIndex(of: b.0) ?? order.count
            return ia != ib ? ia < ib : a.0 < b.0
        }
        return ranked.map { key, value in (key, label(key), display(key: key, value: value)) }
    }

    static func label(_ key: String) -> String {
        switch key {
        case "url": return "Link"
        case "at": return "When"
        case "due": return "Due"
        case "start": return "Starts"
        case "end": return "Ends"
        case "afterSeconds": return "Timer"
        case "every": return "Repeats every"
        case "listId": return "List ID"
        case "id": return "ID"
        default: break
        }
        // camelCase and snake_case to words, first letter capitalized.
        var words = ""
        for character in key.replacingOccurrences(of: "_", with: " ") {
            if character.isUppercase, !words.isEmpty, words.last != " " { words.append(" ") }
            words.append(words.isEmpty ? Character(character.uppercased()) : Character(character.lowercased()))
        }
        return words
    }

    private static func display(key: String, value: String) -> String {
        if key == "afterSeconds", let seconds = Double(value) {
            return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        }
        if value == "true" { return "Yes" }
        if value == "false" { return "No" }
        if let date = date(value) {
            // A date-only value (a reminder due on a day) has no time to show.
            return value.count == 10
                ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                : Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
                    ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
        }
        return value
    }

    private static func date(_ text: String) -> Date? {
        guard text.count >= 10, text.first?.isNumber == true, text.dropFirst(4).first == "-" else { return nil }
        if text.count == 10 {
            var calendar = Calendar.current
            calendar.timeZone = .current
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
