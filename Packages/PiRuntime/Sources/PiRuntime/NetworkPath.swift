import Foundation
import Network
import os

/// Whether the device has a network path. JS reads it (`__native.networkOnline()`) to tell a model request that failed
/// because the phone is offline, which waits for the network, from one that failed for another reason
/// (`js/src/app/network.ts`).
public protocol NetworkStatus: Sendable {
    var online: Bool { get }
}

/// `NWPathMonitor`'s view: online while the current path is satisfied, and until the first update says otherwise.
public final class NetworkPath: NetworkStatus, @unchecked Sendable {
    public static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    private let state = OSAllocatedUnfairLock(initialState: true)

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            state.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "pi.network-path", qos: .utility))
    }

    public var online: Bool { state.withLock { $0 } }
}
