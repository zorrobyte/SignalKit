import Foundation
import HealthKit

public enum HealthReadError: Error {
    case invalidValue, incompatibleUnit, unsupportedStatistic, perObjectAuthorizationRequired
}

/// Full-fidelity HealthKit access. Native sample objects retain their specialized
/// fields. Use `store` for Apple's series, document and characteristic APIs.
@MainActor
public final class HealthDataReader: HealthReading {
    public typealias ChangePage = HealthChangePage
    public let store: HKHealthStore
    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }
    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests exactly the app's selection, including non-sample types.
    /// A successful request does not reveal which read permissions were granted.
    public func requestAuthorization(read types: Set<HKObjectType>) async throws {
        guard isAvailable else { return }
        guard !types.contains(where: { $0.requiresPerObjectAuthorization() }) else {
            throw HealthReadError.perObjectAuthorizationRequired
        }
        try await store.requestAuthorization(toShare: [], read: types)
    }

    public func samples(type: HKSampleType, interval: DateInterval,
                        strictStart: Bool = false, limit: Int = 10_000) async throws -> [HKSample] {
        precondition(limit >= 0, "Use HKObjectQueryNoLimit or a positive limit")
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                options: strictStart ? .strictStartDate : [])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }

    public func quantity(type: HKQuantityType, unit: HKUnit, statistic: HealthMetric.Statistic,
                         interval: DateInterval) async throws -> Double? {
        guard type.is(compatibleWith: unit) else { throw HealthReadError.incompatibleUnit }
        let resolved = statistic == .automatic ? (type.aggregationStyle == .cumulative ? .sum : .average) : statistic
        guard (type.aggregationStyle == .cumulative) == (resolved == .sum) else { throw HealthReadError.unsupportedStatistic }
        let options: HKStatisticsOptions
        switch resolved {
        case .sum: options = .cumulativeSum
        case .minimum: options = .discreteMin
        case .maximum: options = .discreteMax
        default: options = .discreteAverage
        }
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
            store.execute(HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                let quantity: HKQuantity?
                switch resolved {
                case .sum: quantity = stats?.sumQuantity()
                case .minimum: quantity = stats?.minimumQuantity()
                case .maximum: quantity = stats?.maximumQuantity()
                default: quantity = stats?.averageQuantity()
                }
                continuation.resume(returning: quantity?.doubleValue(for: unit))
            })
        }
    }

    /// Native, bounded change pages for any anchored-query-compatible sample
    /// type. The host must durably enqueue transformed samples/deletions BEFORE
    /// saving the returned anchor. Keep the same interval for a given anchor.
    public func changes(type: HKSampleType, interval: DateInterval,
                        anchor: HKQueryAnchor? = nil, limit: Int = 500) async throws -> ChangePage {
        try await changes(type: type, start: interval.start, end: interval.end, anchor: anchor, limit: limit)
    }

    public func changes(type: HKSampleType, start: Date, end: Date?,
                        anchor: HKQueryAnchor?, limit: Int) async throws -> HealthChangePage {
        precondition(limit > 0 && limit <= 10_000)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: limit) {
                _, samples, deleted, next, error in
                if let error { continuation.resume(throwing: error); return }
                guard let next else { continuation.resume(throwing: CocoaError(.coderReadCorrupt)); return }
                continuation.resume(returning: ChangePage(samples: samples ?? [], deletedIDs: (deleted ?? []).map(\.uuid),
                    anchor: next, hasMore: (samples?.count ?? 0) + (deleted?.count ?? 0) >= limit))
            }
            store.execute(query)
        }
    }
}
