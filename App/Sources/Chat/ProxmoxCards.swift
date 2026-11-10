import SwiftUI

// The Proxmox VE cards: the node, its guests and its backups. The chat draws them under
// pve_overview, pve_guests and pve_backups (their `details.card`, see display.ts); the Proxmox page draws all three from
// `PiRuntime.proxmoxDashboard`. Times are UNIX seconds, sizes bytes.

// MARK: Data

struct PveNode: Decodable, Hashable {
    let name: String
    let status: String
    var uptime: Double?
    var cpu: Double?
    var maxcpu: Int?
    var mem: Double?
    var maxmem: Double?
    var disk: Double?
    var maxdisk: Double?
    var load: [String]?
    var version: String?
}

struct PveGuest: Decodable, Hashable, Identifiable {
    let vmid: Int
    var name: String?
    let type: String
    let node: String
    let status: String
    var template: Bool?
    var cpu: Double?
    var maxcpu: Int?
    var mem: Double?
    var maxmem: Double?
    var disk: Double?
    var maxdisk: Double?
    var uptime: Double?
    var tags: [String]
    var lock: String?
    var hastate: String?

    var id: Int { vmid }
    var running: Bool { status == "running" }
    var title: String { name ?? "Guest \(vmid)" }
}

struct PveTask: Decodable, Hashable {
    let upid: String
    let node: String
    let type: String
    var id: String?
    let user: String
    let status: String
    let start: Double
    var end: Double?
}

struct PveStorage: Decodable, Hashable {
    let name: String
    var node: String?
    var type: String?
    let shared: Bool
    let status: String
    var used: Double?
    var total: Double?
    let content: [String]
}

struct PveCount: Decodable, Hashable {
    let running: Int
    let total: Int
}

struct PveOverview: Decodable, Hashable {
    let at: Double
    let nodes: [PveNode]
    let containers: PveCount
    let vms: PveCount
    let down: [PveGuest]
    let storages: [PveStorage]
    let failed: [PveTask]
}

struct PveGuestList: Decodable, Hashable {
    let at: Double
    var node: String?
    var filters: String?
    let guests: [PveGuest]
}

struct PveBackups: Decodable, Hashable {
    struct Job: Decodable, Hashable {
        let id: String
        let label: String
        var schedule: String?
        var storage: String?
        let guests: String
        var mode: String?
        let enabled: Bool
        var next: Double?
    }

    struct Last: Decodable, Hashable, Identifiable {
        let vmid: Int
        var name: String?
        var type: String?
        /// ok, failed, running or none.
        let state: String
        let result: String
        var at: Double?
        var storage: String?
        var id: Int { vmid }
    }

    struct Uncovered: Decodable, Hashable {
        let vmid: Int
        var name: String?
    }

    let at: Double
    var only: Int?
    let jobs: [Job]
    var uncovered: [Uncovered]?
    let last: [Last]
    let scanned: Int
    var since: Double?
    let failed: [PveTask]

    var failedGuests: [Last] { last.filter { $0.state == "failed" || $0.state == "none" } }
}

struct PveDashboard: Decodable {
    let overview: PveOverview
    let guests: PveGuestList
    let backups: PveBackups
}

// MARK: Formatting

enum Pve {
    /// Proxmox's orange.
    static let tint = Color(red: 0.90, green: 0.44, blue: 0.0)

    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "?" }
        return Int64(value).formatted(.byteCount(style: .memory))
    }

    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "?" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "?" }
        return fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
    }

    static func fraction(_ part: Double?, _ whole: Double?) -> Double? {
        guard let part, let whole, whole > 0 else { return nil }
        return min(max(part / whole, 0), 1)
    }

    /// Green, then orange from 75%, red from 90%.
    static func level(_ fraction: Double?) -> Color {
        guard let fraction else { return .gray }
        return fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .green
    }

    static func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    static func relative(_ seconds: Double) -> String {
        date(seconds).formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func kind(_ type: String?) -> String { type == "lxc" ? "CT" : "VM" }

    static func guestColor(_ guest: PveGuest) -> Color {
        if guest.template == true { return .gray }
        if guest.lock != nil { return .orange }
        switch guest.status {
        case "running": return .green
        case "paused": return .yellow
        default: return .secondary
        }
    }

    /// Opens a new conversation asking about a guest.
    @MainActor static func ask(about guest: PveGuest) {
        Task { await ChatStore.shared.compose("How is \(guest.title) (\(kind(guest.type)) \(guest.vmid)) on my Proxmox node doing?") }
    }
}

// MARK: Pieces

/// A usage figure as a ring, colored by how full it is.
private struct PveRing: View {
    let label: String
    let fraction: Double?
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: fraction ?? 0) {
                Text(label)
            } currentValueLabel: {
                Text(Pve.percent(fraction)).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Pve.level(fraction))
            VStack(spacing: 1) {
                Text(label).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Pve.percent(fraction)), \(detail)")
    }
}

/// A labeled bar: a storage, or a guest's memory.
struct PveUsageBar: View {
    let label: String
    var caption: String?
    let detail: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: fraction ?? 0).tint(Pve.level(fraction))
        }
        .accessibilityElement(children: .combine)
    }
}

struct PveGuestRow: View {
    let guest: PveGuest

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Pve.guestColor(guest)).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(guest.title).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if guest.running {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("CPU \(Pve.percent(guest.cpu))")
                    Text("\(Pve.bytes(guest.mem)) of \(Pve.bytes(guest.maxmem))")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                Text(guest.template == true ? "Template" : guest.status.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Pve.guestColor(guest))
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Ask Pi About \(guest.title)", systemImage: "bubble.left.and.text.bubble.right") { Pve.ask(about: guest) }
        }
    }

    private var subtitle: String {
        var parts = ["\(Pve.kind(guest.type)) \(guest.vmid)"]
        if guest.running { parts.append("up \(Pve.uptime(guest.uptime))") }
        if let lock = guest.lock { parts.append("locked: \(lock)") }
        if !guest.tags.isEmpty { parts.append(guest.tags.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

private struct PveTaskRow: View {
    let task: PveTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text([task.type, task.id].compactMap(\.self).joined(separator: " ")).font(.subheadline.weight(.medium))
                Text(task.status).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(Pve.relative(task.start)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PveSectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct MoreLine: View {
    let hidden: Int
    let noun: String
    var body: some View {
        if hidden > 0 {
            Text("\(hidden) more \(noun)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Node

struct PveOverviewCard: View {
    let value: PveOverview
    /// The Proxmox page: everything, no Expand.
    var full = false

    var body: some View {
        ResultCardShell(
            source: "Proxmox",
            symbol: "server.rack",
            tint: Pve.tint,
            title: title,
            subtitle: subtitle,
            share: share,
            expandable: !full && (value.down.count > 3 || value.storages.count > 3 || value.failed.count > 2)
        ) { expanded in
            let all = full || expanded
            VStack(alignment: .leading, spacing: 12) {
                ForEach(value.nodes, id: \.name) { node in
                    if value.nodes.count > 1 { Text(node.name).font(.headline) }
                    if node.status == "online" {
                        HStack(alignment: .top, spacing: 8) {
                            PveRing(label: "CPU", fraction: node.cpu, detail: "\(node.maxcpu ?? 0) cores")
                            PveRing(label: "Memory", fraction: Pve.fraction(node.mem, node.maxmem), detail: "\(Pve.bytes(node.mem)) of \(Pve.bytes(node.maxmem))")
                            PveRing(label: "Root Disk", fraction: Pve.fraction(node.disk, node.maxdisk), detail: "\(Pve.bytes(node.disk)) of \(Pve.bytes(node.maxdisk))")
                        }
                    } else {
                        Label("\(node.name) is \(node.status)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                guestsLine
                if !value.down.isEmpty {
                    let shown = all ? value.down : Array(value.down.prefix(3))
                    PveSectionTitle(text: "Not Running")
                    ForEach(shown) { PveGuestRow(guest: $0) }
                    MoreLine(hidden: value.down.count - shown.count, noun: "not running")
                }
                if !value.storages.isEmpty {
                    let shown = all ? value.storages : Array(value.storages.prefix(3))
                    PveSectionTitle(text: "Storage")
                    ForEach(shown, id: \.self) { storage in
                        if storage.status == "available" {
                            PveUsageBar(
                                label: storage.name,
                                caption: storage.type,
                                detail: "\(Pve.bytes(storage.used)) of \(Pve.bytes(storage.total))",
                                fraction: Pve.fraction(storage.used, storage.total)
                            )
                        } else {
                            Label("\(storage.name): \(storage.status)", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                        }
                    }
                    MoreLine(hidden: value.storages.count - shown.count, noun: "storages")
                }
                if value.failed.isEmpty {
                    Label("No task failed in the last 24 hours", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    let shown = all ? value.failed : Array(value.failed.prefix(2))
                    PveSectionTitle(text: "Failed in the Last 24 Hours")
                    ForEach(shown, id: \.upid) { PveTaskRow(task: $0) }
                    MoreLine(hidden: value.failed.count - shown.count, noun: "failed tasks")
                }
            }
        }
    }

    private var guestsLine: some View {
        let running = value.containers.running + value.vms.running
        let total = value.containers.total + value.vms.total
        return HStack(spacing: 6) {
            Image(systemName: running == total ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(running == total ? .green : .orange)
            Text("\(running) of \(total) guests running")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            Text("\(value.containers.running)/\(value.containers.total) CT · \(value.vms.running)/\(value.vms.total) VM")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        value.nodes.count == 1 ? value.nodes[0].name : "\(value.nodes.count) nodes"
    }

    private var subtitle: String? {
        guard value.nodes.count == 1, let node = value.nodes.first else { return nil }
        guard node.status == "online" else { return node.status.capitalized }
        return ["Online", "up \(Pve.uptime(node.uptime))", node.version].compactMap(\.self).joined(separator: " · ")
    }

    private var share: String {
        var lines = value.nodes.map { node in
            "\(node.name): \(node.status), CPU \(Pve.percent(node.cpu)), memory \(Pve.bytes(node.mem)) of \(Pve.bytes(node.maxmem))"
        }
        lines.append("\(value.containers.running + value.vms.running) of \(value.containers.total + value.vms.total) guests running")
        lines += value.storages.map { "\($0.name): \(Pve.bytes($0.used)) of \(Pve.bytes($0.total))" }
        if !value.failed.isEmpty { lines.append("\(value.failed.count) failed tasks in the last 24 hours") }
        return lines.joined(separator: "\n")
    }
}

// MARK: Guests

struct PveGuestsCard: View {
    let value: PveGuestList
    var full = false

    private static let shown = 6

    var body: some View {
        let running = value.guests.filter(\.running).count
        ResultCardShell(
            source: "Proxmox",
            symbol: "shippingbox",
            tint: Pve.tint,
            title: "\(value.guests.count) \(value.guests.count == 1 ? "Guest" : "Guests")",
            subtitle: [value.filters?.capitalized, "\(running) running", value.node.map { "on \($0)" }].compactMap(\.self).joined(separator: " · "),
            share: value.guests.map { "\($0.vmid) \($0.title) (\(Pve.kind($0.type))): \($0.status)" }.joined(separator: "\n"),
            expandable: !full && value.guests.count > Self.shown
        ) { expanded in
            let rows = full || expanded ? value.guests : Array(value.guests.prefix(Self.shown))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { guest in
                    PveGuestRow(guest: guest)
                    if guest.id != rows.last?.id { Divider() }
                }
                MoreLine(hidden: value.guests.count - rows.count, noun: "guests")
            }
        }
    }
}

// MARK: Backups

struct PveBackupsCard: View {
    let value: PveBackups
    var full = false

    var body: some View {
        let problems = value.failedGuests.count + (value.only == nil ? (value.uncovered?.count ?? 0) : 0)
        ResultCardShell(
            source: "Proxmox Backups",
            symbol: "externaldrive.badge.timemachine",
            tint: Pve.tint,
            title: value.only.map { "Backups of \($0)" }
                ?? (problems > 0 ? "\(problems) Need\(problems == 1 ? "s" : "") Attention" : confirmed ? "All Backed Up" : "Backups"),
            subtitle: subtitle,
            share: share,
            expandable: !full && (value.last.count > 5 || !value.jobs.isEmpty || !value.failed.isEmpty)
        ) { expanded in
            let all = full || expanded
            VStack(alignment: .leading, spacing: 10) {
                if let uncovered = value.uncovered, value.only == nil, !uncovered.isEmpty {
                    Label {
                        Text("Not in any job: \(Text(uncovered.map { "\($0.vmid) \($0.name ?? "")" }.joined(separator: ", ")).fontWeight(.semibold))")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                }
                // Problems first.
                let ordered = value.failedGuests + value.last.filter { $0.state == "ok" || $0.state == "running" }
                let rows = all ? ordered : Array(ordered.prefix(5))
                ForEach(rows) { row in
                    backupRow(row)
                }
                MoreLine(hidden: ordered.count - rows.count, noun: "guests")
                if all && !value.jobs.isEmpty {
                    PveSectionTitle(text: "Jobs")
                    ForEach(value.jobs, id: \.id) { job in
                        jobRow(job)
                    }
                }
                if all && !value.failed.isEmpty {
                    PveSectionTitle(text: "Failed in the Last 7 Days")
                    ForEach(value.failed, id: \.upid) { PveTaskRow(task: $0) }
                }
            }
        }
    }

    /// Every guest is in a job and each one's last backup worked: not while one runs, or without the coverage list.
    private var confirmed: Bool {
        value.uncovered != nil && !value.last.isEmpty && value.last.allSatisfy { $0.state == "ok" }
    }

    private var subtitle: String {
        let ok = value.last.filter { $0.state == "ok" }.count
        var parts = ["\(ok) of \(value.last.count) OK"]
        if !value.jobs.isEmpty { parts.append("\(value.jobs.count) \(value.jobs.count == 1 ? "job" : "jobs")") }
        if let next = value.jobs.compactMap(\.next).min() { parts.append("next \(Pve.relative(next))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func backupRow(_ row: PveBackups.Last) -> some View {
        let (symbol, color): (String, Color) = switch row.state {
        case "ok": ("checkmark.circle.fill", .green)
        case "running": ("arrow.triangle.2.circlepath.circle.fill", .blue)
        case "failed": ("xmark.circle.fill", .red)
        default: ("questionmark.circle.fill", .orange)
        }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(row.name ?? "Guest \(row.vmid)")").font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail(row)).font(.caption).foregroundStyle(row.state == "ok" ? AnyShapeStyle(.secondary) : AnyShapeStyle(color)).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let at = row.at {
                Text(Pve.relative(at)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ row: PveBackups.Last) -> String {
        let kind = "\(Pve.kind(row.type)) \(row.vmid)"
        switch row.state {
        case "ok": return [kind, row.storage.map { "→ \($0)" }].compactMap(\.self).joined(separator: " · ")
        case "running": return "\(kind) · running now"
        default: return "\(kind) · \(row.result.replacingOccurrences(of: "failed: ", with: ""))"
        }
    }

    private func jobRow(_ job: PveBackups.Job) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(job.label).font(.subheadline.weight(.medium))
                Spacer()
                Text(job.enabled ? (job.next.map { "next \(Pve.relative($0))" } ?? "") : "Disabled")
                    .font(.caption)
                    .foregroundStyle(job.enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Text([job.schedule, job.storage.map { "→ \($0)" }, job.guests, job.mode].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var share: String {
        value.last.map { "\($0.vmid) \($0.name ?? ""): \($0.result)\($0.at.map { " (\(Pve.date($0).formatted()))" } ?? "")" }
            .joined(separator: "\n")
    }
}
