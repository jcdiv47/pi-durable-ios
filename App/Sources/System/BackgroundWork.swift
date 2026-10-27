import BackgroundTasks
import Foundation

/// iOS's side of Pi's wake-ups (spec "Durability on iOS"). Pi reports `onWake` (`active` while work can run, `at` for
/// the earliest sleep); with `onWake` set it arms no timers of its own, so:
/// - `at` arms a `BGAppRefreshTask` for when iOS has suspended or evicted the app (JS resumes due sleeps while the
///   process lives);
/// - active work when the app leaves the foreground asks for a `BGContinuedProcessingTask` (the system shows its
///   progress) and arms a `BGProcessingTask` to finish later if iOS suspends the app anyway;
/// - every background launch opens Pi, calls `resume()`, and waits until nothing is active.
/// Timing is best effort: iOS runs these at or after the time asked for, if at all. Pi never relies on them; every
/// launch resumes whatever is due.
@MainActor
final class BackgroundWork {
    nonisolated static let refresh = "dev.jcdiv47.pidurable.refresh"
    nonisolated static let processing = "dev.jcdiv47.pidurable.processing"
    /// Continued processing tasks use a fresh identifier under this wildcard each time.
    nonisolated static let runPrefix = "dev.jcdiv47.pidurable.run."

    struct Wake: Decodable, Equatable {
        let active: Bool
        let at: Double?

        var date: Date? { at.map { Date(timeIntervalSince1970: $0 / 1000) } }
    }

    private unowned let store: ChatStore
    private(set) var wake = Wake(active: false, at: nil)
    private var armedRefresh: Date?
    private var idle: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var continued: BGContinuedProcessingTask?
    private var continuedRequested = false

    init(store: ChatStore) {
        self.store = store
    }

    /// Launch handlers must be registered before the app finishes launching.
    nonisolated static func register() {
        for identifier in [refresh, processing] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                // Delivered on the main queue (`using: .main`), so the task never leaves it.
                nonisolated(unsafe) let task = task
                MainActor.assumeIsolated { ChatStore.shared.background.run(task) }
            }
        }
    }

    // MARK: Wake events

    func update(_ wake: Wake) {
        self.wake = wake
        if !wake.active {
            for id in Array(idle.keys) { stopWaiting(id) }
        }
        armRefresh(at: wake.date)
    }

    /// A refresh for the earliest sleep. Resubmitting replaces the pending request.
    private func armRefresh(at date: Date?) {
        guard date != armedRefresh else { return }
        armedRefresh = date
        guard let date else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refresh)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refresh)
        request.earliestBeginDate = max(date, .now.addingTimeInterval(60))
        submit(request, "refresh at \(date.formatted(date: .omitted, time: .shortened))")
    }

    private func submit(_ request: BGTaskRequest, _ what: String) {
        do {
            try BGTaskScheduler.shared.submit(request)
            store.diagnostics.record("info", "background", "Armed \(what)")
        } catch {
            // The simulator has no BGTaskScheduler (code 1); a device with Background App Refresh off says the same.
            store.diagnostics.record("warn", "background", "Could not arm \(what): \(error.localizedDescription)")
        }
    }

    // MARK: Background launches

    /// A refresh or processing launch: open Pi, resume, and finish once nothing is active (or iOS wants the time back).
    func run(_ task: BGTask) {
        // The M0 modes open Pi themselves; they only check that these launches are accepted.
        guard LaunchMode.current == .chat else { return task.setTaskCompleted(success: true) }
        store.diagnostics.record("info", "background", "Woke for \(task.identifier)")
        let work = Task {
            await store.ensureStarted()
            await store.resumeWork()
            await waitForIdle(timeout: .seconds(25))
        }
        task.expirationHandler = {
            work.cancel()
        }
        Task {
            await work.value
            let success = !work.isCancelled
            store.diagnostics.record(success ? "info" : "warn", "background", "\(task.identifier) \(success ? "finished" : "expired") with work \(wake.active ? "left" : "done")")
            armedRefresh = nil
            armRefresh(at: wake.date)
            task.setTaskCompleted(success: success)
        }
    }

    /// Until no work is active, or `timeout`. Entry points that run while the app is away (notification actions, widget
    /// buttons) wait here, so iOS does not suspend the app mid-run as soon as they return.
    func waitForIdle(timeout: Duration) async {
        guard wake.active else { return }
        let id = UUID()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            stopWaiting(id)
        }
        await withCheckedContinuation { idle[id] = $0 }
        timer.cancel()
    }

    private func stopWaiting(_ id: UUID) {
        idle.removeValue(forKey: id)?.resume()
    }

    // MARK: Leaving the foreground with work running

    /// The app is about to leave the foreground (scene `inactive`) with runs going: ask iOS to keep it running, with
    /// the system's progress UI. Continued processing may only be requested while the app is in the foreground.
    func continueRuns(titles: [String]) {
        guard !titles.isEmpty, continued == nil, !continuedRequested else { return }
        continuedRequested = true
        let identifier = Self.runPrefix + String(UUID().uuidString.prefix(8))
        // Continued processing handlers may be registered after launch, once per identifier.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated { ChatStore.shared.background.began(task) }
        }
        let subtitle = titles.count == 1 ? titles[0] : "\(titles.count) conversations"
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Pi is working", subtitle: subtitle)
        request.strategy = .fail
        submit(request, "continued processing for \(subtitle)")
    }

    /// The app went to the background: if work is still active, a processing task finishes it later should iOS
    /// suspend the app first.
    func enteredBackground() {
        guard wake.active || !store.busyConversations.isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processing)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = .now.addingTimeInterval(60)
        submit(request, "processing to finish runs")
    }

    func enteredForeground() {
        continuedRequested = continued != nil
    }

    private func began(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
        continued = task
        task.progress.totalUnitCount = 100
        task.expirationHandler = {
            MainActor.assumeIsolated { ChatStore.shared.background.continuedEnded(success: false) }
        }
        store.diagnostics.record("info", "background", "Continued processing started")
        progress(busy: store.busyConversations.count, status: nil)
    }

    /// Called as runs move. A run has no known length, so progress creeps toward 95% with each step and completes
    /// when no conversation is busy.
    func progress(busy: Int, status: String?) {
        guard let continued else { return }
        if busy == 0 { return continuedEnded(success: true) }
        let progress = continued.progress
        progress.completedUnitCount = min(95, progress.completedUnitCount + 2)
        if let status { continued.updateTitle("Pi is working", subtitle: status) }
    }

    private func continuedEnded(success: Bool) {
        guard let task = continued else { return }
        continued = nil
        continuedRequested = false
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: success)
        store.diagnostics.record(success ? "info" : "warn", "background", success ? "Continued processing finished" : "Continued processing expired; Pi resumes at the next launch")
    }
}
