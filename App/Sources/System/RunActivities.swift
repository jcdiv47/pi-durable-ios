import ActivityKit
import Foundation
import PiUI

/// A Live Activity per run the user starts from the app (spec "ActivityKit"): status, the running tool, elapsed time,
/// Allow / Deny when a tool waits for approval, and Stop. Started in the foreground (iOS allows nothing else without
/// push), updated from the conversation's frames only when what it shows changes (updates are budgeted), and ended
/// with the answer when the run ends.
@MainActor
final class RunActivities {
    private unowned let store: ChatStore
    private var activities: [Int: Activity<PiRunAttributes>] = [:]
    private var shown: [Int: PiRunAttributes.ContentState] = [:]
    /// Activities whose run has been seen busy. The frame right after a send can still show the conversation idle
    /// (the input is admitted before its run starts); only a run seen going can end.
    private var running: Set<Int> = []

    init(store: ChatStore) {
        self.store = store
    }

    func start(conversationId: Int, title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activities[conversationId] == nil else { return }
        let state = PiRunAttributes.ContentState(status: "Thinking…", symbol: "sparkle")
        do {
            activities[conversationId] = try Activity.request(
                attributes: PiRunAttributes(title: title, conversationId: conversationId),
                content: .init(state: state, staleDate: .now.addingTimeInterval(3600))
            )
            shown[conversationId] = state
        } catch {
            store.diagnostics.record("warn", "activity", "Could not start the Live Activity: \(error.localizedDescription)")
        }
    }

    /// Activities a previous process left: kept for runs that resume, ended for the rest.
    func adopt(busy: Set<Int>) {
        for activity in Activity<PiRunAttributes>.activities {
            let id = activity.attributes.conversationId
            if busy.contains(id), activities[id] == nil {
                activities[id] = activity
                shown[id] = activity.content.state
                running.insert(id)
            } else if activities[id] !== activity {
                Self.end(activity, nil, dismissalPolicy: .immediate)
            }
        }
    }

    func update(_ state: ConversationState, approval: ApprovalRequest?) {
        guard let activity = activities[state.id], let previous = shown[state.id] else { return }
        if state.live.busy {
            running.insert(state.id)
        } else {
            guard running.remove(state.id) != nil else { return }
            let answer = state.items.last { $0.kind == .assistant }
            let stopped = answer?.stopReason == "aborted"
            let final = PiRunAttributes.ContentState(
                status: stopped ? "Stopped" : answer?.stopReason == "error" ? "Failed" : "Answered",
                symbol: stopped ? "stop.circle" : "checkmark.circle.fill",
                detail: (answer?.text).map { String($0.prefix(240)) },
                finished: true,
                startedAt: previous.startedAt
            )
            activities[state.id] = nil
            shown[state.id] = nil
            Self.end(activity, .init(state: final, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
            return
        }
        var next = Self.status(state.live, approval: approval)
        next.startedAt = previous.startedAt
        guard next != previous else { return }
        shown[state.id] = next
        let content = ActivityContent(state: next, staleDate: .now.addingTimeInterval(3600))
        let box = ActivityBox(activity: activity)
        Task.detached { await box.activity.update(content) }
    }

    /// `Activity` is not `Sendable`; its async methods are called from outside the main actor, holding nothing else.
    private struct ActivityBox: @unchecked Sendable {
        let activity: Activity<PiRunAttributes>
    }

    private static func end(_ activity: Activity<PiRunAttributes>, _ content: ActivityContent<PiRunAttributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) {
        let box = ActivityBox(activity: activity)
        Task.detached { await box.activity.end(content, dismissalPolicy: dismissalPolicy) }
    }

    /// What the run is doing, in a few words; changes only at steps, not with every streamed token.
    static func status(_ live: DisplayLive, approval: ApprovalRequest?) -> PiRunAttributes.ContentState {
        if let approval {
            return .init(
                status: "Needs your approval",
                symbol: "hand.raised.fill",
                detail: ([approval.tool] + approval.arguments.fields.prefix(2).map { "\($0.0): \($0.1)" }).joined(separator: " · "),
                approval: .init(id: approval.id, tool: approval.tool)
            )
        }
        if let tool = live.tools.last(where: { $0.status == "running" }) ?? live.tools.last {
            return .init(status: "Running \(tool.name)", symbol: "wrench.and.screwdriver")
        }
        if let generation = live.generation {
            if generation.retry != nil { return .init(status: "Retrying…", symbol: "arrow.clockwise") }
            if !generation.toolCalls.isEmpty { return .init(status: "Calling \(generation.toolCalls.last!.name)", symbol: "wrench.and.screwdriver") }
            if !generation.text.isEmpty { return .init(status: "Writing…", symbol: "text.bubble") }
            if !generation.thinking.isEmpty { return .init(status: "Thinking…", symbol: "brain") }
        }
        if live.compacting { return .init(status: "Summarizing earlier messages", symbol: "archivebox") }
        return .init(status: "Thinking…", symbol: "sparkle")
    }

    /// A short status for the continued processing task's subtitle.
    func statusText(_ id: Int) -> String? { shown[id]?.status }
}
