import Foundation

/// Answers the JS Apple tools (`js/src/app/apple.ts`): one handler per `hostCall` name, JSON in and
/// out. Permission is requested the first time a tool needs it, not at launch.
public final class AppleToolHost: Sendable {
    let calendar = CalendarTools()
    #if os(iOS)
    let health = HealthTools()
    #endif

    public init() {}

    /// Names this host answers; anything else is the caller's.
    public static let handlers: Set<String> = [
        "calendar.query", "calendar.createEvent", "reminders.query", "reminders.create", "reminders.complete", "health.query",
    ]

    public func handle(_ name: String, _ json: String) async throws -> String {
        let data = Data(json.utf8)
        let result: Any
        switch name {
        case "calendar.query": result = try await calendar.query(decode(data))
        case "calendar.createEvent": result = try await calendar.createEvent(decode(data))
        case "reminders.query": result = try await calendar.reminders(decode(data))
        case "reminders.create": result = try await calendar.createReminder(decode(data))
        case "reminders.complete": result = try await calendar.completeReminder(decode(data))
        #if os(iOS)
        case "health.query": result = try await health.query(decode(data))
        #endif
        default: throw AppleToolError("No Apple tool handler named \(name)")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AppleToolError("Invalid arguments: \(error)")
        }
    }
}

public struct AppleToolError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// ISO 8601 in and out. Accepts a UTC offset or `Z`, with or without fractional seconds, or a bare date
/// (local midnight). Writes local time with its offset, which models read more reliably than UTC.
enum ISODate {
    static func parse(_ text: String, field: String) throws -> Date {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = text.count == 16 ? "yyyy-MM-dd'T'HH:mm" : text.count == 19 ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd"
        if let date = day.date(from: text) { return date }
        throw AppleToolError("\(field) is not an ISO 8601 date: \(text)")
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
