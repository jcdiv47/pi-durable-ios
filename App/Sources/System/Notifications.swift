import Foundation
import PiUI
import UserNotifications

/// Local notifications (spec "UserNotifications"): approvals the user can answer from the notification, finished runs
/// while the app is away, scheduled task results and reminders the agent sets. Permission is asked on first use, and
/// identifiers are idempotency keys, so a rerun after a crash replaces a notification rather than posting another.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let approvalCategory = "pi.approval"
    nonisolated static let messageCategory = "pi.message"
    nonisolated static let allowAction = "pi.allow"
    nonisolated static let denyAction = "pi.deny"
    nonisolated static let replyAction = "pi.reply"

    private unowned let store: ChatStore
    private let center = UNUserNotificationCenter.current()

    init(store: ChatStore) {
        self.store = store
        super.init()
    }

    /// Before launch finishes, so actions that launch the app are delivered.
    func configure() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.approvalCategory,
                actions: [
                    UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [.authenticationRequired]),
                    UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.messageCategory,
                actions: [UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message Pi")],
                intentIdentifiers: []
            ),
        ])
    }

    /// Asks for permission the first time Pi has something to show; true when allowed.
    @discardableResult
    func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            store.diagnostics.record("info", "notify", "Notification permission \(granted ? "granted" : "declined")")
            return granted
        default: return false
        }
    }

    // MARK: Posting

    func postApproval(_ request: ApprovalRequest, conversation: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Pi wants to run \(request.tool)"
        content.body = ([conversation] + request.arguments.fields.prefix(3).map { "\($0.0): \($0.1)" }).joined(separator: "\n")
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = ["conversationId": request.conversationId, "approvalId": request.id]
        await add(Self.approvalIdentifier(request.id), content, trigger: nil)
    }

    func removeApprovals(except pending: Set<Int>) async {
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let stale = delivered.filter { $0.hasPrefix("approval-") && !pending.contains(Int($0.dropFirst(9)) ?? -1) }
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }

    /// A run that ended while the app was away. One per answer entry.
    func postAnswer(conversationId: Int, entryId: Int, title: String, text: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(text.prefix(400))
        content.categoryIdentifier = Self.messageCategory
        content.threadIdentifier = "conversation-\(conversationId)"
        content.userInfo = ["conversationId": conversationId]
        await add("answer-\(conversationId)-\(entryId)", content, trigger: nil)
    }

    /// A deleted conversation's delivered and pending notifications: its answers, approvals and scheduled reminders.
    func removeConversation(_ id: Int) async {
        let center = UNUserNotificationCenter.current()
        let belongs = { (content: UNNotificationContent) in (content.userInfo["conversationId"] as? Int) == id || content.threadIdentifier == "conversation-\(id)" }
        let delivered = await center.deliveredNotifications().filter { belongs($0.request.content) }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        let pending = await center.pendingNotificationRequests().filter { belongs($0.content) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    /// A notice from the app itself, such as an MCP server that can't be reached. The identifier replaces an earlier one.
    func postNotice(identifier: String, title: String, body: String) async {
        guard await authorize() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        await add(identifier, content, trigger: nil)
    }

    /// `notify.post` (a scheduled task's answer) and `notify.schedule` (a reminder at a time), from JS. Returns JSON.
    func post(_ args: NotifyArguments) async throws -> String {
        guard await authorize() else { return #"{"scheduled":false,"reason":"The user has not allowed notifications for Pi"}"# }
        let content = UNMutableNotificationContent()
        content.title = args.title
        content.body = args.body
        content.sound = .default
        content.categoryIdentifier = Self.messageCategory
        if let conversationId = args.conversationId {
            content.userInfo = ["conversationId": conversationId]
            content.threadIdentifier = "conversation-\(conversationId)"
        }
        var trigger: UNNotificationTrigger?
        if let at = args.at {
            let date = Date(timeIntervalSince1970: at / 1000)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            if date > .now { trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false) }
        }
        let identifier = args.identifier ?? args.id ?? UUID().uuidString
        await add(identifier, content, trigger: trigger)
        var result: [String: JSONValue] = ["scheduled": true, "id": .string(identifier)]
        if let at = args.at { result["at"] = .string(Date(timeIntervalSince1970: at / 1000).ISO8601Format()) }
        return JSONValue.object(result).jsonText
    }

    struct NotifyArguments: Decodable {
        let identifier: String?
        let id: String?
        let title: String
        let body: String
        /// Milliseconds since 1970; absent posts now.
        let at: Double?
        let conversationId: Int?
    }

    private func add(_ identifier: String, _ content: UNNotificationContent, trigger: UNNotificationTrigger?) async {
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        } catch {
            store.diagnostics.record("warn", "notify", "Could not post \(identifier): \(error.localizedDescription)")
        }
    }

    static func approvalIdentifier(_ id: Int) -> String { "approval-\(id)" }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // In the app, approvals show as the sheet; everything else shows as a banner.
        notification.request.content.categoryIdentifier == Self.approvalCategory ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let conversationId = userInfo["conversationId"] as? Int
        let approvalId = userInfo["approvalId"] as? Int
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        await store.notificationResponse(
            identifier: identifier, action: action, conversationId: conversationId, approvalId: approvalId, reply: reply
        )
    }
}
