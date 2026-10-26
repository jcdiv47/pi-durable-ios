#if os(iOS)
import HealthKit

/// HealthKit handlers land here in M1. For M0 this only checks that the signed app may use HealthKit.
public enum HealthAccess {
    /// Asks HealthKit whether it would show a permission sheet for step count, without showing one.
    /// Fails when the HealthKit entitlement is missing.
    public static func probe() async -> (available: Bool, requestStatus: String) {
        guard HKHealthStore.isHealthDataAvailable() else { return (false, "health data unavailable") }
        let steps = HKQuantityType(.stepCount)
        do {
            let status = try await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: [steps])
            let name = switch status {
            case .shouldRequest: "shouldRequest"
            case .unnecessary: "unnecessary"
            default: "unknown"
            }
            return (true, name)
        } catch {
            return (true, "error: \(error.localizedDescription)")
        }
    }
}
#endif
