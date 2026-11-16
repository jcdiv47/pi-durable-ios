#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity for a spoken conversation with Pi (`RealtimeVoice` in the app): listening, working, speaking, the last
/// thing said, Allow / Deny when Pi waits for approval, and End. A voice session started from the Action button or
/// Control Center records in the background, which iOS allows only while this activity shows. The widget extension
/// draws it; its buttons are App Intents that run in the app's process.
public struct PiVoiceAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public struct Approval: Codable, Hashable, Sendable {
            /// The tool task's ID (`ApprovalRequest.id`).
            public var id: Int
            /// What the tool does, in words ("Run a command on your machine").
            public var action: String

            public init(id: Int, action: String) {
                self.id = id
                self.action = action
            }
        }

        public var status: String
        /// SF Symbol for the status.
        public var symbol: String
        /// The last thing the user or Pi said, or why the session ended.
        public var line: String?
        public var approval: Approval?
        public var ended: Bool
        /// The Pi conversation the requests went to, which a tap opens once the session has ended.
        public var conversationId: Int?

        public init(status: String, symbol: String = "waveform", line: String? = nil, approval: Approval? = nil, ended: Bool = false, conversationId: Int? = nil) {
            self.status = status
            self.symbol = symbol
            self.line = line
            self.approval = approval
            self.ended = ended
            self.conversationId = conversationId
        }
    }

    public var startedAt: Date

    public init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }
}
#endif
