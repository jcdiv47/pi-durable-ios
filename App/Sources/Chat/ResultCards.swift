import Charts
import MapKit
import PiUI
import SwiftUI

// Native cards for Apple tool and web search results, drawn under a run's "Worked" row. They read the result's parsed output
// (`cardTools` in js/src/app/display.ts); a result without one, or one that does not decode, shows no card.

/// What a tool result shows as a card.
enum ResultCardContent {
    case reminders(title: String, [ReminderRow], truncated: Bool)
    case events(title: String, [EventRow], days: Bool)
    case location(LocationResult)
    case health(HealthResult)
    case web(WebSearchResult)
    case photos(PhotosResult)

    init?(call: ToolCallItem, result: DisplayItem) {
        guard result.isError != true, let data = result.data else { return nil }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch result.toolName {
        case "reminders_query":
            guard let value = data.decoded(RemindersResult.self) else { return nil }
            self = .reminders(title: Self.remindersTitle(args), value.reminders, truncated: value.truncated ?? false)
        case "reminders_create":
            guard let reminder = data.decoded(OneReminder.self)?.reminder else { return nil }
            self = .reminders(title: "Added to \(reminder.list?.isEmpty == false ? reminder.list! : "Reminders")", [reminder], truncated: false)
        case "reminders_update":
            guard let reminder = data.decoded(OneReminder.self)?.reminder else { return nil }
            self = .reminders(title: "Updated in \(reminder.list ?? "Reminders")", [reminder], truncated: false)
        case "reminders_complete":
            guard let reminder = data.decoded(OneReminder.self)?.reminder else { return nil }
            self = .reminders(title: reminder.completed == true ? "Completed" : "Not done", [reminder], truncated: false)
        case "calendar_query":
            guard let value = data.decoded(EventsResult.self) else { return nil }
            let start = (args["start"] as? String).flatMap(ISODate.date)
            let end = (args["end"] as? String).flatMap(ISODate.date)
            self = .events(title: Self.rangeTitle(start, end), value.events, days: Self.spansDays(start, end))
        case "calendar_create_event":
            guard let event = data.decoded(OneEvent.self)?.event else { return nil }
            self = .events(title: "Added to \(event.calendar?.isEmpty == false ? event.calendar! : "Calendar")", [event], days: false)
        case "location_current":
            guard let value = data.decoded(LocationResult.self) else { return nil }
            self = .location(value)
        case "health_query":
            guard let value = data.decoded(HealthResult.self), !value.buckets.isEmpty else { return nil }
            self = .health(value)
        case "web_search":
            guard let value = data.decoded(WebSearchResult.self), !value.results.isEmpty else { return nil }
            self = .web(value)
        case "photos_search":
            guard let value = data.decoded(PhotosResult.self) else { return nil }
            self = .photos(value)
        default:
            return nil
        }
    }

    private static func remindersTitle(_ args: [String: Any]) -> String {
        if let list = args["list"] as? String, !list.isEmpty { return list }
        if let due = (args["dueBefore"] as? String).flatMap(ISODate.date) {
            let calendar = Calendar.current
            // "Before tomorrow" is today, which is what a model asks for "due today".
            if due <= calendar.startOfDay(for: .now).addingTimeInterval(86_400 + 60) { return "Today" }
            if due <= calendar.startOfDay(for: .now).addingTimeInterval(2 * 86_400 + 60) { return "Through tomorrow" }
            return "Due by \(due.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return args["includeCompleted"] as? Bool == true ? "All reminders" : "Open reminders"
    }

    private static func rangeTitle(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return "Events" }
        let calendar = Calendar.current
        let lastDay = end.map { $0.addingTimeInterval(-1) } ?? start
        if calendar.isDate(start, inSameDayAs: lastDay) {
            if calendar.isDateInToday(start) { return "Today" }
            if calendar.isDateInTomorrow(start) { return "Tomorrow" }
            if calendar.isDateInYesterday(start) { return "Yesterday" }
            return start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(lastDay.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private static func spansDays(_ start: Date?, _ end: Date?) -> Bool {
        guard let start, let end else { return true }
        return !Calendar.current.isDate(start, inSameDayAs: end.addingTimeInterval(-1))
    }
}

struct ResultCard: View {
    let content: ResultCardContent
    let store: ChatStore

    var body: some View {
        switch content {
        case let .reminders(title, rows, truncated):
            RemindersCard(title: title, rows: rows, truncated: truncated, store: store)
        case let .events(title, rows, days):
            EventsCard(title: title, rows: rows, days: days, store: store)
        case let .location(value):
            LocationCard(value: value)
        case let .health(value):
            HealthCard(value: value)
        case let .web(value):
            WebSearchCard(value: value)
        case let .photos(value):
            PhotosCard(value: value)
        }
    }
}

// MARK: Shell

/// The frame every card shares: where it came from, a title, Share, and Expand when the content is cut short in the
/// chat. `content(true)` is the expanded sheet's.
struct ResultCardShell<Content: View>: View {
    let source: String
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    let share: String
    var expandable = false
    @ViewBuilder let content: (_ expanded: Bool) -> Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content(false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
        .sheet(isPresented: $expanded) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        content(true)
                    }
                    .padding()
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label(source.uppercased(), systemImage: symbol)
                    .font(.caption.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(tint)
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !expanded {
                ShareLink(item: share) {
                    Image(systemName: "square.and.arrow.up").frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Share")
                if expandable {
                    Button {
                        expanded = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Expand")
                }
            }
        }
        .controlSize(.small)
    }
}

// MARK: Reminders

struct ReminderRow: Decodable, Hashable {
    /// Missing in results from before M4; such a row cannot be ticked off.
    let id: String?
    let title: String
    let completed: Bool?
    let list: String?
    let due: String?
    /// EventKit's: 0 none, 1–4 high, 5 medium, 6–9 low.
    let priority: Int?
}

private struct RemindersResult: Decodable {
    let reminders: [ReminderRow]
    let truncated: Bool?
}

private struct OneReminder: Decodable { let reminder: ReminderRow }

struct RemindersCard: View {
    let title: String
    let rows: [ReminderRow]
    let truncated: Bool
    let store: ChatStore
    private let shown = 6

    var body: some View {
        ResultCardShell(
            source: "Reminders",
            symbol: "checklist",
            tint: .orange,
            title: title,
            subtitle: rows.count < 2 ? nil : "\(rows.count)\(truncated ? "+" : "") reminders",
            share: rows.map { "• \($0.title)\(due($0).map { " (\($0))" } ?? "")" }.joined(separator: "\n"),
            expandable: rows.count > shown
        ) { expanded in
            let visible = expanded ? rows : Array(rows.prefix(shown))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups(visible), id: \.list) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if showsLists {
                            Text(group.list.uppercased())
                                .font(.caption.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(color(group.list))
                        }
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            reminder(row)
                        }
                    }
                }
                if rows.isEmpty {
                    Text("No reminders.").foregroundStyle(.secondary)
                } else if !expanded, rows.count > shown {
                    Text("\(rows.count - shown) more").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            store.loadListColors()
            store.loadReminderStates(rows.compactMap(\.id))
        }
    }

    /// List names head their rows unless there is one list and the title names it.
    private var showsLists: Bool { Set(rows.map { $0.list ?? "" }).count > 1 || !title.contains(rows.first?.list ?? "") }

    private func groups(_ rows: [ReminderRow]) -> [(list: String, rows: [ReminderRow])] {
        var order: [String] = []
        var byList: [String: [ReminderRow]] = [:]
        for row in rows {
            let list = row.list ?? ""
            if byList[list] == nil { order.append(list) }
            byList[list, default: []].append(row)
        }
        return order.map { ($0, byList[$0]!) }
    }

    private func color(_ list: String) -> Color { store.listColors?.reminders[list] ?? .orange }

    private func done(_ row: ReminderRow) -> Bool { row.id.flatMap { store.reminderDone[$0] } ?? row.completed ?? false }

    private func toggle(_ row: ReminderRow, done: Bool) {
        guard let id = row.id else { return }
        Task { await store.setReminder(id, done: !done) }
    }

    @ViewBuilder private func reminder(_ row: ReminderRow) -> some View {
        let done = done(row)
        let overdue = !done && (row.due.flatMap(ISODate.date).map { $0 < .now } ?? false)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                toggle(row, done: done)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? color(row.list ?? "") : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(row.id == nil)
            .accessibilityLabel(done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(priorityMarks(row.priority))\(row.title)")
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                if let due = due(row) {
                    Text(due).font(.subheadline).foregroundStyle(overdue ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .contextMenu {
            if row.id != nil {
                Button(done ? "Mark not done" : "Mark done", systemImage: done ? "circle" : "checkmark.circle") { toggle(row, done: done) }
            }
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.title }
        }
        .animation(.snappy, value: done)
    }

    private func priorityMarks(_ priority: Int?) -> Text {
        guard let priority, priority > 0 else { return Text("") }
        let marks = priority < 5 ? "!!! " : priority == 5 ? "!! " : "! "
        return Text(marks).foregroundStyle(.orange).bold()
    }

    private func due(_ row: ReminderRow) -> String? { row.due.flatMap(ISODate.date).map { ISODate.relative($0) } }
}

// MARK: Calendar

struct EventRow: Decodable, Hashable {
    let title: String
    let start: String
    let end: String
    let allDay: Bool?
    let calendar: String?
    let location: String?
}

private struct EventsResult: Decodable {
    let events: [EventRow]
    let truncated: Bool?
}

private struct OneEvent: Decodable { let event: EventRow }

struct EventsCard: View {
    let title: String
    let rows: [EventRow]
    /// The range spans days: rows are grouped under each day.
    let days: Bool
    let store: ChatStore
    private let shown = 6

    var body: some View {
        ResultCardShell(
            source: "Calendar",
            symbol: "calendar",
            tint: .red,
            title: title,
            subtitle: rows.count < 2 ? nil : "\(rows.count) events",
            share: rows.map { "• \($0.title), \(time($0))" }.joined(separator: "\n"),
            expandable: rows.count > shown
        ) { expanded in
            let visible = expanded ? rows : Array(rows.prefix(shown))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, row in
                    if days, let day = day(row), index == 0 || self.day(visible[index - 1]) != day {
                        Text(day.uppercased()).font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary).padding(.top, index == 0 ? 0 : 4)
                    }
                    event(row)
                }
                if rows.isEmpty {
                    Text("No events.").foregroundStyle(.secondary)
                } else if !expanded, rows.count > shown {
                    Text("\(rows.count - shown) more").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { store.loadListColors() }
    }

    private func event(_ row: EventRow) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(store.listColors?.calendars[row.calendar ?? ""] ?? .red)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.body.weight(.medium))
                Text([time(row), row.location].compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func day(_ row: EventRow) -> String? {
        ISODate.date(row.start).map { Calendar.current.isDateInToday($0) ? "Today" : $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    }

    private func time(_ row: EventRow) -> String {
        if row.allDay == true { return "All day" }
        guard let start = ISODate.date(row.start) else { return row.start }
        let startText = days || title.contains("Added") ? ISODate.relative(start) : start.formatted(date: .omitted, time: .shortened)
        guard let end = ISODate.date(row.end), end > start else { return startText }
        return "\(startText) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: Location

struct LocationResult: Decodable {
    struct Place: Decodable {
        let name: String?
        let address: String?
        let city: String?
    }

    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
    let place: Place?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [.init(name: "ll", value: "\(latitude),\(longitude)"), .init(name: "q", value: place?.name ?? "Current location")]
        return components?.url
    }
}

struct LocationCard: View {
    let value: LocationResult
    @Environment(\.openURL) private var openURL

    var body: some View {
        ResultCardShell(
            source: "Location",
            symbol: "location.fill",
            tint: .blue,
            title: value.place?.name ?? value.place?.city ?? "Current location",
            subtitle: value.place?.name == nil ? nil : value.place?.city,
            share: [value.place?.address, value.mapsURL?.absoluteString].compactMap(\.self).joined(separator: "\n")
        ) { expanded in
            VStack(alignment: .leading, spacing: 10) {
                Map(
                    initialPosition: .region(.init(center: value.coordinate, latitudinalMeters: max((value.accuracyMeters ?? 100) * 6, 600), longitudinalMeters: max((value.accuracyMeters ?? 100) * 6, 600))),
                    interactionModes: expanded ? .all : []
                ) {
                    Marker(value.place?.name ?? "Here", coordinate: value.coordinate)
                }
                .frame(height: expanded ? 360 : 170)
                .clipShape(.rect(cornerRadius: 14))
                if let address = value.place?.address {
                    Label(address, systemImage: "mappin.and.ellipse").font(.subheadline)
                }
                if let url = value.mapsURL {
                    Button("Open in Maps", systemImage: "map") { openURL(url) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: Health

struct HealthResult: Decodable {
    struct Bucket: Decodable {
        let start: String
        let sum: Double?
        let average: Double?
        let min: Double?
        let max: Double?
        let hoursAsleep: Double?

        var value: Double? { sum ?? average ?? hoursAsleep }
        var date: Date? { ISODate.date(start) }
    }

    let metric: String
    let unit: String
    let interval: String
    let buckets: [Bucket]
    let note: String?

    var name: String {
        switch metric {
        case "steps": "Steps"
        case "activeEnergy": "Active energy"
        case "distanceWalkingRunning": "Walking + running"
        case "flightsClimbed": "Flights climbed"
        case "heartRate": "Heart rate"
        case "restingHeartRate": "Resting heart rate"
        case "bodyMass": "Weight"
        case "sleep": "Sleep"
        default: metric
        }
    }

    /// The whole range: summed for counts and sleep, averaged for rates and weight.
    var total: Double? {
        let values = buckets.compactMap(\.value)
        guard !values.isEmpty else { return nil }
        let summed = buckets.contains { $0.sum != nil || $0.hoursAsleep != nil }
        return summed ? values.reduce(0, +) : values.reduce(0, +) / Double(values.count)
    }

    func format(_ value: Double) -> String {
        if unit == "m", value >= 1000 { return "\((value / 1000).formatted(.number.precision(.fractionLength(1)))) km" }
        let number = value >= 100 ? value.formatted(.number.precision(.fractionLength(0))) : value.formatted(.number.precision(.fractionLength(0 ... 1)))
        return unit == "steps" ? number : "\(number) \(unit)"
    }
}

struct HealthCard: View {
    let value: HealthResult

    var body: some View {
        let total = value.total
        ResultCardShell(
            source: "Health",
            symbol: "heart.fill",
            tint: .pink,
            title: value.name,
            subtitle: subtitle,
            share: "\(value.name): \(total.map(value.format) ?? "no data")"
        ) { expanded in
            VStack(alignment: .leading, spacing: 10) {
                if let total, value.note == nil {
                    Text(value.format(total)).font(.system(size: 40, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                }
                if let note = value.note {
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                } else if value.buckets.count > 1 {
                    Chart(Array(value.buckets.enumerated()), id: \.offset) { _, bucket in
                        if let date = bucket.date, let y = bucket.value {
                            BarMark(x: .value("Time", date, unit: value.interval == "hour" ? .hour : .day), y: .value(value.name, y))
                                .foregroundStyle(.pink.gradient)
                                .cornerRadius(3)
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: expanded ? 260 : 130)
                }
            }
        }
    }

    private var subtitle: String? {
        let dates = value.buckets.compactMap(\.date)
        guard let first = dates.first else { return nil }
        let summed = value.buckets.contains { $0.sum != nil || $0.hoursAsleep != nil }
        let range = dates.count > 1 && value.interval == "day"
            ? "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(dates.last!.formatted(.dateTime.month(.abbreviated).day()))"
            : Calendar.current.isDateInToday(first) ? "Today" : first.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return summed ? range : "\(range) · average"
    }
}

// MARK: Web

struct WebSearchResult: Decodable {
    struct Row: Decodable, Hashable {
        let title: String
        let url: String
        let snippet: String?
        let date: String?
        let site: String?
    }

    let provider: String?
    let query: String
    let results: [Row]
}

struct WebSearchCard: View {
    let value: WebSearchResult
    @Environment(\.openURL) private var openURL
    private static let collapsed = 4

    var body: some View {
        ResultCardShell(
            source: "Web",
            symbol: "globe",
            tint: .teal,
            title: value.query,
            subtitle: [value.results.count == 1 ? "1 result" : "\(value.results.count) results", value.provider].compactMap(\.self).joined(separator: " · "),
            share: value.results.map { "\($0.title)\n\($0.url)" }.joined(separator: "\n\n"),
            expandable: value.results.count > Self.collapsed
        ) { expanded in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(expanded ? value.results : Array(value.results.prefix(Self.collapsed)), id: \.self) { row in
                    Button {
                        if let url = URL(string: row.url) { openURL(url) }
                    } label: {
                        result(row, expanded: expanded)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func result(_ row: WebSearchResult.Row, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(row.title.isEmpty ? row.url : row.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if expanded, let snippet = row.snippet, !snippet.isEmpty {
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// "Earendil · Jun 1, 2026": the site, or the link's host, and the date when it parses.
    private func source(_ row: WebSearchResult.Row) -> String {
        let site = row.site ?? URL(string: row.url)?.host()
        let date = row.date.flatMap(ISODate.date)?.formatted(.dateTime.month(.abbreviated).day().year())
        return [site, date].compactMap(\.self).joined(separator: " · ")
    }
}

// MARK: Dates

/// The Apple tools' dates: ISO 8601 with a UTC offset, written in local time.
enum ISODate {
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// "Today, 10:00 AM", "Tomorrow", "Mon, Oct 27, 9:30 AM". A time of midnight is a date-only due date.
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "Today"
            : calendar.isDateInTomorrow(date) ? "Tomorrow"
            : calendar.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if calendar.startOfDay(for: date) == date { return day }
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }
}

extension JSONValue {
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
