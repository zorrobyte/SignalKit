import Foundation
import Testing
import HealthKit
@testable import HealthSync

struct HealthSyncTests {
    @Test @MainActor func checkpointRequiresDurableEnqueue() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let total = HealthAggregate(date: HealthWindow().dateKey(Date()), type: "steps", value: 3,
            unit: "count", recordedAt: 1)
        #expect(throws: (any Error).self) {
            try HealthUploadCheckpoint(url: url).enqueueChanged([total]) { _ in false }
        }
        let checkpoint = HealthUploadCheckpoint(url: url)
        #expect(try checkpoint.enqueueChanged([total]) { _ in true } == 1)
        #expect(try HealthUploadCheckpoint(url: url).enqueueChanged([total]) { _ in
            Issue.record("Unchanged value should not enqueue"); return false
        } == 0)
    }
    @Test @MainActor func unknownDeletionAndEmptyReadCannotClearTotals() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = HealthChangeJournal(url: url)
        try journal.apply(type: "steps", anchor: Data([1]), added: [], deleted: ["unknown"], caughtUp: true)
        #expect(try !journal.canClearEmpty(type: "steps", date: "2026-09-06"))
        try journal.apply(type: "steps", anchor: Data([2]), added: [.init(id: "known", dates: ["2026-09-06"])], deleted: [], caughtUp: true)
        try journal.apply(type: "steps", anchor: Data([3]), added: [], deleted: ["known"], caughtUp: true)
        #expect(try journal.canClearEmpty(type: "steps", date: "2026-09-06"))
        try journal.acknowledge(date: "2026-09-06")
        #expect(try !HealthChangeJournal(url: url).canClearEmpty(type: "steps", date: "2026-09-06"))
    }
    @Test func catalogCoversNativeFamiliesWithoutDuplicateTypes() {
        let entries = HealthTypeCatalog.available()
        let ids = Set(entries.map(\.id))
        #expect(ids.count == entries.count)
        #expect(ids.contains(HKQuantityType(.heartRate).identifier))
        #expect(ids.contains(HKCategoryType(.sleepAnalysis).identifier))
        #expect(ids.contains(HKCharacteristicType(.dateOfBirth).identifier))
        #expect(ids.contains(HKCorrelationType(.bloodPressure).identifier))
        #expect(ids.contains(HKObjectType.electrocardiogramType().identifier))
        #expect(!entries.contains { $0.family == .clinical })
        #expect(HealthTypeCatalog.available(includeClinicalRecords: true).contains { $0.family == .clinical })
        if #available(iOS 26, *) {
            #expect(ids.contains(HKObjectType.medicationDoseEventType().identifier))
        }
    }
    @Test func sevenCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Indiana/Indianapolis"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let start = HealthWindow().start(now: now, calendar: calendar)
        #expect(calendar.component(.day, from: start) == 4)
        #expect(calendar.component(.hour, from: start) == 0)
    }
}
