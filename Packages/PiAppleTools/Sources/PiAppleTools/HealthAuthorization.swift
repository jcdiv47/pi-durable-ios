#if os(iOS)
import Foundation
import HealthKit
import os

/// Asks for every Health type the tools read in one sheet, once, however many queries run at once.
/// HealthKit presents a sheet per request: a second request made while the first sheet is presenting fails to
/// present ("Attempt to present … whose view is not in the window hierarchy") and never calls back, so
/// parallel `health_query` calls that each asked for their own type hung forever.
actor HealthAuthorization {
    /// How long a request may take before the query fails instead of waiting. Generous, since the sheet stays
    /// up while the user reads it; only a request whose sheet never appeared should get here.
    static let timeout: TimeInterval = 120

    private let store: HKHealthStore
    private let types: Set<HKObjectType>
    private var request: Task<Void, Error>?

    init(store: HKHealthStore, types: Set<HKObjectType>) {
        self.store = store
        self.types = types
    }

    /// Returns once HealthKit has an answer for every type (asking the user if it never has). A failed or timed-out
    /// request is forgotten, so the next query asks again.
    func ensure() async throws {
        let task = request ?? Task { [store, types] in try await Self.requestAuthorization(store, types) }
        request = task
        do {
            try await task.value
        } catch {
            if request == task { request = nil }
            throw error
        }
    }

    /// `requestAuthorization` with a deadline. The async variant cannot be abandoned: it ignores cancellation, so a
    /// lost callback would still hang the caller.
    private static func requestAuthorization(_ store: HKHealthStore, _ types: Set<HKObjectType>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: continuation)
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                pending.withLock { pending in
                    defer { pending = nil }
                    return pending
                }?.resume(with: result)
            }
            store.requestAuthorization(toShare: [], read: types) { _, error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(AppleToolError(
                    "The Health permission request did not finish. Ask the user to try again, or to allow Pi in Settings › Health › Data Access & Devices."
                )))
            }
        }
    }
}
#endif
