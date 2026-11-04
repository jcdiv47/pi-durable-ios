#if canImport(AlarmKit) && os(iOS)
import AlarmKit
import Foundation

/// What Pi's alarms carry (`AlarmTools` in PiAppleTools schedules them): the app and the widget extension, which draws
/// a timer's countdown on the Lock Screen and in the Dynamic Island, must agree on the type.
public struct PiAlarmMetadata: AlarmMetadata {
    public var label: String

    public init(label: String) {
        self.label = label
    }
}

public typealias PiAlarmAttributes = AlarmAttributes<PiAlarmMetadata>
#endif
