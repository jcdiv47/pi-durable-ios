#if os(iOS)
import Foundation
import HealthKit

/// HealthKit read queries. HealthKit never says whether reading was denied: a denied type just has no
/// samples, so an empty result says so in `note`.
final class HealthTools: Sendable {
    private let store = HKHealthStore()

    struct QueryArguments: Decodable {
        let metric: String
        let start: String
        let end: String
        let interval: String?
    }

    private struct Quantity {
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let unitName: String
        let cumulative: Bool
    }

    private static let quantities: [String: Quantity] = [
        "steps": .init(identifier: .stepCount, unit: .count(), unitName: "steps", cumulative: true),
        "activeEnergy": .init(identifier: .activeEnergyBurned, unit: .kilocalorie(), unitName: "kcal", cumulative: true),
        "distanceWalkingRunning": .init(identifier: .distanceWalkingRunning, unit: .meter(), unitName: "m", cumulative: true),
        "flightsClimbed": .init(identifier: .flightsClimbed, unit: .count(), unitName: "flights", cumulative: true),
        "heartRate": .init(identifier: .heartRate, unit: .count().unitDivided(by: .minute()), unitName: "bpm", cumulative: false),
        "restingHeartRate": .init(identifier: .restingHeartRate, unit: .count().unitDivided(by: .minute()), unitName: "bpm", cumulative: false),
        "bodyMass": .init(identifier: .bodyMass, unit: .gramUnit(with: .kilo), unitName: "kg", cumulative: false),
    ]

    func query(_ args: QueryArguments) async throws -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppleToolError("Health data is not available on this device") }
        let start = try ISODate.parse(args.start, field: "start")
        let end = try ISODate.parse(args.end, field: "end")
        guard end > start else { throw AppleToolError("end must be after start") }
        let interval = args.interval ?? "total"
        guard ["total", "day", "hour"].contains(interval) else { throw AppleToolError("interval must be total, day or hour") }
        if args.metric == "sleep" { return try await sleep(start: start, end: end, interval: interval) }
        guard let quantity = Self.quantities[args.metric] else {
            throw AppleToolError("Unknown metric \(args.metric). Known: \((Self.quantities.keys.sorted() + ["sleep"]).joined(separator: ", "))")
        }
        let type = HKQuantityType(quantity.identifier)
        try await store.requestAuthorization(toShare: [], read: [type])

        let options: HKStatisticsOptions = quantity.cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
        var buckets: [[String: Any]] = []
        for (from, to) in Self.buckets(start: start, end: end, interval: interval) {
            let predicate = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: to))
            let statistics = try await HKStatisticsQueryDescriptor(predicate: predicate, options: options).result(for: store)
            var bucket: [String: Any] = ["start": ISODate.format(from), "end": ISODate.format(to)]
            if quantity.cumulative {
                bucket["sum"] = Self.round(statistics?.sumQuantity()?.doubleValue(for: quantity.unit) ?? 0)
            } else if let average = statistics?.averageQuantity() {
                bucket["average"] = Self.round(average.doubleValue(for: quantity.unit))
                bucket["min"] = statistics?.minimumQuantity().map { Self.round($0.doubleValue(for: quantity.unit)) }
                bucket["max"] = statistics?.maximumQuantity().map { Self.round($0.doubleValue(for: quantity.unit)) }
            }
            buckets.append(bucket)
        }
        var result: [String: Any] = ["metric": args.metric, "unit": quantity.unitName, "interval": interval, "buckets": buckets]
        let empty = buckets.allSatisfy { ($0["sum"] as? Double ?? 0) == 0 && $0["average"] == nil }
        if empty { result["note"] = "No samples. Either there is no data for this range, or the user has not allowed Pi to read it." }
        return result
    }

    private func sleep(start: Date, end: Date, interval: String) async throws -> [String: Any] {
        let type = HKCategoryType(.sleepAnalysis)
        try await store.requestAuthorization(toShare: [], read: [type])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let samples = try await descriptor.result(for: store).filter { asleep.contains($0.value) }
        let buckets = Self.buckets(start: start, end: end, interval: interval).map { from, to -> [String: Any] in
            let seconds = samples.reduce(0.0) { total, sample in
                total + max(0, min(sample.endDate, to).timeIntervalSince(max(sample.startDate, from)))
            }
            return ["start": ISODate.format(from), "end": ISODate.format(to), "hoursAsleep": Self.round(seconds / 3600)]
        }
        var result: [String: Any] = ["metric": "sleep", "unit": "hours", "interval": interval, "buckets": buckets]
        if samples.isEmpty { result["note"] = "No sleep samples. Either there is no data for this range, or the user has not allowed Pi to read it." }
        return result
    }

    /// Splits the range at local day or hour boundaries; at most 400 buckets.
    private static func buckets(start: Date, end: Date, interval: String) -> [(Date, Date)] {
        guard interval != "total" else { return [(start, end)] }
        let component: Calendar.Component = interval == "day" ? .day : .hour
        let calendar = Calendar.current
        var result: [(Date, Date)] = []
        var from = start
        while from < end, result.count < 400 {
            let boundary = calendar.dateInterval(of: component, for: from)?.end ?? end
            let to = min(boundary, end)
            result.append((from, to))
            from = to
        }
        return result
    }

    private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
#endif
