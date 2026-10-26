#if os(iOS)
import ActivityKit

/// Live Activity for a running agent turn. M0 only proves the capability; M3 fills it in.
public struct PiRunAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: String
        public init(status: String) { self.status = status }
    }

    public var title: String
    public init(title: String) { self.title = title }
}
#endif
