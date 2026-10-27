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
