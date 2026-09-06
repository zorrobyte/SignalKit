import Foundation
import HealthKit

/// Injectable HealthKit query boundary, also useful for recorded-data replay.
@MainActor public protocol HealthReading: AnyObject {
    var store: HKHealthStore { get }
    var isAvailable: Bool { get }
    func requestAuthorization(read: Set<HKObjectType>) async throws
    func samples(type: HKSampleType, interval: DateInterval, strictStart: Bool, limit: Int) async throws -> [HKSample]
    func quantity(type: HKQuantityType, unit: HKUnit, statistic: HealthMetric.Statistic, interval: DateInterval) async throws -> Double?
    func changes(type: HKSampleType, start: Date, end: Date?, anchor: HKQueryAnchor?, limit: Int) async throws -> HealthChangePage
}

public struct HealthChangePage {
    public let samples: [HKSample]
    public let deletedIDs: [UUID]
    public let anchor: HKQueryAnchor
    public let hasMore: Bool
    public init(samples: [HKSample], deletedIDs: [UUID], anchor: HKQueryAnchor, hasMore: Bool) {
        self.samples = samples; self.deletedIDs = deletedIDs; self.anchor = anchor; self.hasMore = hasMore
    }
}

@MainActor public protocol HealthObserving: AnyObject {
    /// Returns a cancellation closure. Complete every update after durable work,
    /// including error paths, without waiting for a network upload.
    func observe(_ type: HKSampleType,
        onChange: @escaping @Sendable @MainActor (Error?, @escaping @Sendable () -> Void) -> Void) -> () -> Void
    func enableBackgroundDelivery(_ type: HKSampleType) async throws -> Bool
}

@MainActor public final class HealthKitObservation: HealthObserving {
    private let store: HKHealthStore
    public init(store: HKHealthStore) { self.store = store }
    public func observe(_ type: HKSampleType,
        onChange: @escaping @Sendable @MainActor (Error?, @escaping @Sendable () -> Void) -> Void) -> () -> Void {
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            // HealthKit's completion handler is not declared Sendable; it is safe to
            // call from any thread, so hand it to the main actor explicitly.
            nonisolated(unsafe) let completion = completion
            Task { @MainActor in onChange(error) { completion() } }
        }
        store.execute(query)
        return { [store] in store.stop(query) }
    }
    public func enableBackgroundDelivery(_ type: HKSampleType) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { enabled, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: enabled) }
            }
        }
    }
}
