#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity for a conversation's run (spec "ActivityKit"): status, the running tool, elapsed time, and Approve /
/// Stop buttons. PiApp starts it when the user sends from the app and updates it from the conversation's frames; the
/// widget extension draws it. Its buttons are App Intents that run in the app's process.
public struct PiRunAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public struct Approval: Codable, Hashable, Sendable {
            /// The tool task's ID (`ApprovalRequest.id`).
            public var id: Int
            public var tool: String

            public init(id: Int, tool: String) {
                self.id = id
                self.tool = tool
            }
        }

        public var status: String
        /// SF Symbol for the status.
        public var symbol: String
        /// The newest text of the answer, or the final answer once finished.
        public var detail: String?
        public var approval: Approval?
        public var finished: Bool
        public var startedAt: Date

        public init(status: String, symbol: String = "sparkle", detail: String? = nil, approval: Approval? = nil, finished: Bool = false, startedAt: Date = .now) {
            self.status = status
            self.symbol = symbol
            self.detail = detail
            self.approval = approval
            self.finished = finished
            self.startedAt = startedAt
        }
    }

    public var title: String
    public var conversationId: Int

    public init(title: String, conversationId: Int = 0) {
        self.title = title
        self.conversationId = conversationId
    }
}
#endif
