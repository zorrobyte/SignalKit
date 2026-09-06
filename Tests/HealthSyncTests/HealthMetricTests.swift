import Foundation
import HealthKit
import Testing
@testable import HealthSync

@MainActor struct HealthMetricTests {
    @Test func quantityForwardsUnitStatisticAndIdentifier() async throws {
        let reader = FakeHealthReader()
        let type = HKQuantityType(.heartRate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let metric = HealthMetric.quantity(type, unit: unit, statistic: .maximum)
        let day = DateInterval(start: Date().addingTimeInterval(-100), duration: 100)
        #expect(try await metric.read(reader, day) == 12)
        #expect(metric.id == type.identifier && metric.unit == unit.unitString)
        #expect(metric.readTypes == [type])
        #expect(reader.quantityCalls.first?.2 == .maximum)
        #expect(reader.quantityCalls.first?.3 == day)
    }
    @Test func sleepFiltersClipsAndMergesOverlappingSources() async throws {
        let r = FakeHealthReader(), type = HKCategoryType(.sleepAnalysis)
        let day = DateInterval(start: Date(timeIntervalSince1970: 10_000), duration: 600)
        func sample(_ start: Double, _ end: Double, _ value: Int) -> HKCategorySample {
            HKCategorySample(type: type, value: value, start: day.start.addingTimeInterval(start), end: day.start.addingTimeInterval(end))
        }
        let asleep = HKCategoryValueSleepAnalysis.asleepCore.rawValue
        r.sampleValues = [sample(-100, 300, asleep), sample(200, 800, asleep),
                          sample(0, 600, HKCategoryValueSleepAnalysis.awake.rawValue)]
        let metric = HealthMetric.categoryDuration(type, values: [asleep])
        #expect(try await metric.read(r, day) == 10)
        #expect(r.sampleCalls.first?.2 == false && r.sampleCalls.first?.3 == HKObjectQueryNoLimit)
        r.sampleValues = []
        #expect(try await metric.read(r, day) == nil)
    }
    @Test func invalidUnitsAndStatisticsFailBeforeNativeQueries() async throws {
        let reader = HealthDataReader()
        let day = DateInterval(start: Date(), duration: 60)
        await #expect(throws: HealthReadError.self) {
            try await reader.quantity(type: HKQuantityType(.stepCount), unit: .meter(), statistic: .sum, interval: day)
        }
        await #expect(throws: HealthReadError.self) {
            try await reader.quantity(type: HKQuantityType(.heartRate), unit: .count().unitDivided(by: .minute()), statistic: .sum, interval: day)
        }
        await #expect(throws: HealthReadError.self) {
            try await reader.quantity(type: HKQuantityType(.stepCount), unit: .count(), statistic: .average, interval: day)
        }
    }
    @Test func intervalEdgeCases() {
        let day = DateInterval(start: Date(timeIntervalSince1970: 100), duration: 120)
        #expect(HealthIntervals.minutes([], within: day) == 0)
        #expect(HealthIntervals.minutes([DateInterval(start: day.end, duration: 60)], within: day) == 0)
        #expect(HealthIntervals.minutes([DateInterval(start: day.start, duration: 0)], within: day) == 0)
        #expect(HealthIntervals.minutes([day, day], within: day) == 2)
    }
}
