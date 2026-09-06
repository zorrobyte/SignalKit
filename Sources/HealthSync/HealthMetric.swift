import Foundation
import HealthKit

/// A configurable numeric summary. Non-numeric data stays in native HealthKit
/// objects through HealthDataReader; it is never silently coerced into a total.
@MainActor
public struct HealthMetric {
    public enum Statistic: Sendable { case automatic, sum, average, minimum, maximum }
    public let id: String
    public let label: String
    public let unit: String
    public let sampleTypes: Set<HKSampleType>
    public let readTypes: Set<HKObjectType>
    public let deletionTypeIdentifier: String?
    let read: @MainActor (any HealthReading, DateInterval) async throws -> Double?

    /// Custom queries can use any sample types and any native HealthKit query.
    /// Only set deletionType when absence means a confirmed zero for this metric.
    public init(id: String, label: String, unit: String, sampleTypes: Set<HKSampleType>,
                deletionType: HKSampleType? = nil, additionalReadTypes: Set<HKObjectType> = [],
                read: @escaping @MainActor (any HealthReading, DateInterval) async throws -> Double?) {
        self.id = id; self.label = label; self.unit = unit
        self.sampleTypes = sampleTypes; self.deletionTypeIdentifier = deletionType?.identifier
        self.readTypes = Set(sampleTypes.map { $0 as HKObjectType }).union(additionalReadTypes)
        self.read = read
    }

    public static func quantity(_ type: HKQuantityType, unit: HKUnit, id: String? = nil,
                                label: String? = nil, unitLabel: String? = nil,
                                statistic: Statistic = .automatic) -> HealthMetric {
        HealthMetric(id: id ?? type.identifier, label: label ?? type.identifier,
            unit: unitLabel ?? unit.unitString, sampleTypes: [type], deletionType: type) { reader, interval in
            try await reader.quantity(type: type, unit: unit, statistic: statistic, interval: interval)
        }
    }

    public static func categoryDuration(_ type: HKCategoryType, values: Set<Int>? = nil,
                                        id: String? = nil, label: String? = nil) -> HealthMetric {
        HealthMetric(id: id ?? type.identifier, label: label ?? type.identifier,
            unit: "min", sampleTypes: [type], deletionType: type) { reader, interval in
            let samples = try await reader.samples(type: type, interval: interval, strictStart: false, limit: HKObjectQueryNoLimit)
                .compactMap { $0 as? HKCategorySample }.filter { values?.contains($0.value) ?? true }
            let minutes = HealthIntervals.minutes(samples.map { DateInterval(start: $0.startDate, end: $0.endDate) }, within: interval)
            return minutes > 0 ? minutes : nil
        }
    }
}
