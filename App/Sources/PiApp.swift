import BackgroundTasks
import SwiftUI

@main
struct PiApp: App {
    @State private var model = AppModel()
    @State private var store = ChatStore()

    init() {
        // Must be registered before launch finishes. M3 schedules real work; M0 only checks that
        // the background modes are accepted under this signing.
        for identifier in [BackgroundIdentifiers.refresh, BackgroundIdentifiers.processing] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                task.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if LaunchMode.current == .chat {
                ChatRootView(store: store)
                    .task { await store.start() }
            } else {
                ContentView(model: model)
                    .task { await model.start() }
            }
        }
    }
}

enum BackgroundIdentifiers {
    static let refresh = "dev.jcdiv47.pidurable.refresh"
    static let processing = "dev.jcdiv47.pidurable.processing"
}

/// What this launch does, from `-PiMode <mode>` (launch arguments land in `UserDefaults`).
enum LaunchMode: String {
    /// The app: conversations, settings, diagnostics (`ChatStore`).
    case chat
    /// M0's bare streaming view; `scripts/m0-check.sh stream` sends one prompt from `PI_PROMPT`.
    case stream
    case capabilities
    case conformance
    case killTestStart = "killtest-start"
    case killTestResume = "killtest-resume"
    case streamKillStart = "streamkill-start"
    case streamKillResume = "streamkill-resume"
    case measure

    static let current = UserDefaults.standard.string(forKey: "PiMode").flatMap(LaunchMode.init(rawValue:)) ?? .chat

    /// Reports this mode writes to `Documents/m0/`, cleared at launch so scripts never read a stale one.
    var reports: [String] {
        switch self {
        case .chat: []
        case .stream: ["stream.json"]
        case .capabilities: ["capabilities.json"]
        case .conformance: ["conformance.json"]
        case .killTestStart: ["killtest-start.jsonl", "killtest-result.json"]
        case .killTestResume: ["killtest-resume.jsonl", "killtest-result.json"]
        case .streamKillStart: ["streamkill-start.jsonl", "streamkill-result.json"]
        case .streamKillResume: ["streamkill-resume.jsonl", "streamkill-result.json"]
        case .measure: ["metrics.json"]
        }
    }
}
