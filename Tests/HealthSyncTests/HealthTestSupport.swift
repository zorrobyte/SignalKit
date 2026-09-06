import Foundation
import HealthKit
@testable import HealthSync

@MainActor final class HealthFixture {
    let url: URL
    let suite = "SignalKitTests." + UUID().uuidString
    let defaults: UserDefaults
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor final class FakeHealthReader: HealthReading {
    let store = HKHealthStore()
    var isAvailable = true
    var authorized: Set<HKObjectType> = []
    var authorizationError: Error?
    var quantityValue: Double? = 12
    var quantityError: Error?
    var sampleValues: [HKSample] = []
    var sampleError: Error?
    var changeError: Error?
    var pages: [HealthChangePage] = []
    var quantityCalls: [(HKQuantityType, HKUnit, HealthMetric.Statistic, DateInterval)] = []
    var sampleCalls: [(HKSampleType, DateInterval, Bool, Int)] = []
    var changeCalls: [(String, Date, Date?, HKQueryAnchor?, Int)] = []
    var onQuantity: (() async -> Void)?
    func requestAuthorization(read types: Set<HKObjectType>) async throws {
        if let authorizationError { throw authorizationError }; authorized = types
    }
    func quantity(type: HKQuantityType, unit: HKUnit, statistic: HealthMetric.Statistic, interval: DateInterval) async throws -> Double? {
        quantityCalls.append((type, unit, statistic, interval))
        await onQuantity?()
        if let quantityError { throw quantityError }; return quantityValue
    }
    func samples(type: HKSampleType, interval: DateInterval, strictStart: Bool, limit: Int) async throws -> [HKSample] {
        sampleCalls.append((type, interval, strictStart, limit))
        if let sampleError { throw sampleError }; return sampleValues
    }
    func changes(type: HKSampleType, start: Date, end: Date?, anchor: HKQueryAnchor?, limit: Int) async throws -> HealthChangePage {
        changeCalls.append((type.identifier, start, end, anchor, limit))
        if let changeError { throw changeError }
        if !pages.isEmpty { return pages.removeFirst() }
        return HealthChangePage(samples: [], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 1), hasMore: false)
    }
}

@MainActor final class FakeHealthObservation: HealthObserving {
    var handlers: [String: @MainActor (Error?, @escaping () -> Void) -> Void] = [:]
    var starts = 0
    var stops = 0
    var enabledTypes: [String] = []
    var enabled = true
    var error: Error?
    func observe(_ type: HKSampleType,
        onChange: @escaping @MainActor (Error?, @escaping () -> Void) -> Void) -> () -> Void {
        starts += 1; handlers[type.identifier] = onChange
        return { [weak self] in self?.stops += 1; self?.handlers[type.identifier] = nil }
    }
    func enableBackgroundDelivery(_ type: HKSampleType) async throws -> Bool {
        enabledTypes.append(type.identifier)
        if let error { throw error }; return enabled
    }
}

actor HealthUploads {
    private(set) var batches: [[HealthAggregate]] = []
    var failure: Error?
    func setFailure(_ error: Error?) { failure = error }
    func send(_ totals: [HealthAggregate]) throws {
        if let failure { throw failure }; batches.append(totals)
    }
    func all() -> [HealthAggregate] { batches.flatMap { $0 } }
}
