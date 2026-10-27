#if os(iOS)
import CoreLocation
import Foundation
import MapKit

/// The device's location, on request only: one fix per call, no tracking. The first call asks for When In Use
/// permission; iOS shows that prompt only while the app is in the foreground, so a call from the background before
/// the user ever answered fails after the timeout with a message saying so.
final class LocationTools: Sendable {
    /// Long enough for the permission prompt to be read and answered, and for a cold GPS fix.
    static let timeout: Duration = .seconds(30)

    struct Arguments: Decodable {
        /// Whether to look up the address (a network call to Apple). Default true.
        let placeName: Bool?
    }

    func current(_ args: Arguments) async throws -> [String: Any] {
        switch CLLocationManager().authorizationStatus {
        case .denied: throw AppleToolError("Location access is not allowed. The user can turn it on in Settings › Privacy & Security › Location Services › Pi.")
        case .restricted: throw AppleToolError("Location access is restricted on this device.")
        default: break
        }
        let location = try await fix()
        var result: [String: Any] = [
            "latitude": Self.round(location.coordinate.latitude, 4),
            "longitude": Self.round(location.coordinate.longitude, 4),
            "accuracyMeters": Int(location.horizontalAccuracy.rounded()),
            "at": ISODate.format(location.timestamp),
        ]
        if args.placeName ?? true, let place = await place(location) { result["place"] = place }
        return result
    }

    /// The first usable update. Holding a `CLServiceSession` asks for When In Use permission if it was never asked.
    private func fix() async throws -> CLLocation {
        try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask {
                let session = CLServiceSession(authorization: .whenInUse)
                defer { session.invalidate() }
                for try await update in CLLocationUpdate.liveUpdates() {
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        throw AppleToolError("Location access is not allowed. The user can turn it on in Settings › Privacy & Security › Location Services › Pi.")
                    }
                    if let location = update.location, location.horizontalAccuracy >= 0 { return location }
                }
                throw AppleToolError("Location updates ended without a fix.")
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                let asked = CLLocationManager().authorizationStatus != .notDetermined
                throw AppleToolError(asked
                    ? "No location fix within \(Self.timeout). The device may have no GPS or network signal."
                    : "Pi has not been allowed to use location yet, and iOS asks only while Pi is open. Ask the user to open Pi and try again.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func place(_ location: CLLocation) async -> [String: Any]? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first
        else { return nil }
        var place: [String: Any] = [:]
        if let name = item.name { place["name"] = name }
        if let address = item.address?.fullAddress { place["address"] = address }
        if let city = item.addressRepresentations?.cityWithContext { place["city"] = city }
        if let zone = item.timeZone?.identifier { place["timeZone"] = zone }
        return place.isEmpty ? nil : place
    }

    private static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
#endif
