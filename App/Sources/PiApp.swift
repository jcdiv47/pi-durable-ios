import SwiftUI

@main
struct PiApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: PiAppDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before launch finishes: background launch handlers, and the notification delegate that receives actions
        // which launched the app.
        BackgroundWork.register()
        if LaunchMode.current == .chat { ChatStore.shared.notifications.configure() }
    }

    var body: some Scene {
        WindowGroup {
            if LaunchMode.current == .chat {
                ChatRootView(store: ChatStore.shared)
                    .task { await ChatStore.shared.ensureStarted() }
            } else {
                ContentView(model: model)
                    .task { await model.start() }
            }
        }
        .onChange(of: scenePhase) { old, new in
            if LaunchMode.current == .chat { ChatStore.shared.scenePhaseChanged(from: old, to: new) }
        }
    }
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

/// Portrait only. Info.plist lists every orientation (iOS warns otherwise); this is what the app allows.
final class PiAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }
}
