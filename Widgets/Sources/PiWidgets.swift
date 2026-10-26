import ActivityKit
import PiUI
import SwiftUI
import WidgetKit

@main
struct PiWidgets: WidgetBundle {
    var body: some Widget {
        PiWidget()
        PiRunLiveActivity()
    }
}

/// M0 placeholder: shows the snapshot PiApp's capability check wrote to the App Group container,
/// proving the extension can read it. M2 replaces this with the configurable Pi Widget.
struct PiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PiWidget", provider: SnapshotProvider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Label("Pi", systemImage: "sparkle")
                    .font(.headline)
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pi")
        .description("M0 placeholder")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let message: String
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, message: "…") }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) { completion(entry()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> SnapshotEntry {
        guard let container = SharedContainer.url else { return SnapshotEntry(date: .now, message: "No App Group") }
        let url = container.appendingPathComponent("snapshots/m0.json")
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return SnapshotEntry(date: .now, message: "App Group ok, no snapshot yet") }
        return SnapshotEntry(date: .now, message: "Snapshot \(snapshot["writtenAt"] ?? "?")")
    }
}

struct PiRunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiRunAttributes.self) { context in
            VStack(alignment: .leading) {
                Text(context.attributes.title).font(.headline)
                Text(context.state.status).font(.caption)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text(context.state.status) }
            } compactLeading: {
                Image(systemName: "sparkle")
            } compactTrailing: {
                Text(context.state.status).lineLimit(1)
            } minimal: {
                Image(systemName: "sparkle")
            }
        }
    }
}
