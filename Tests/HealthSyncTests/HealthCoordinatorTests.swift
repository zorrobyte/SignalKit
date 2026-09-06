import Foundation
import HealthKit
import Testing
@testable import HealthSync

@MainActor struct HealthCoordinatorTests {
    let steps = HKQuantityType(.stepCount)
    func make(_ f: HealthFixture, _ reader: FakeHealthReader, _ observer: FakeHealthObservation,
              _ uploads: HealthUploads, days: Int = 7, metrics: [HealthMetric]? = nil) -> HealthSyncCoordinator {
        HealthSyncCoordinator(storageDirectory: f.url, defaults: f.defaults,
            metrics: metrics ?? [.quantity(steps, unit: .count(), id: "steps")], window: HealthWindow(days: days),
            reader: reader, observation: observer, uploadBatch: { try await uploads.send($0) })
    }

    @Test func sevenDayReadUploadsOnceAndSurvivesRelaunch() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let reader = FakeHealthReader(), observation = FakeHealthObservation(), uploads = HealthUploads()
        let sync = make(f, reader, observation, uploads); defer { sync.stop() }
        await sync.syncRecent(); await sync.drainUploads()
        #expect(reader.quantityCalls.count == 7)
        #expect(reader.changeCalls.allSatisfy { $0.2 == nil && $0.4 == 500 })
        #expect(await uploads.all().count == 7)
        #expect(await uploads.all().allSatisfy { HealthWindow().contains($0.date) })
        #expect(sync.todayAggregates.first?.value == 12)
        #expect(sync.lastSyncAt != nil && sync.lastUploadedAt != nil)
        #expect(sync.pendingWrites == 0 && sync.status.pendingHealthDays == 0)
        await sync.syncRecent(); await sync.drainUploads()
        #expect(await uploads.all().count == 7)
        sync.stop()
        let reopened = make(f, reader, observation, uploads); defer { reopened.stop() }
        await reopened.syncRecent(); await reopened.drainUploads()
        #expect(await uploads.all().count == 7)
        reader.quantityValue = 14
        await reopened.syncToday(); await reopened.drainUploads()
        #expect(await uploads.all().last?.value == 14)
        #expect(await uploads.all().count == 8)
    }

    @Test func configurableWindowAndUnavailableStore() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let r = FakeHealthReader(), o = FakeHealthObservation(), u = HealthUploads()
        let sync = make(f, r, o, u, days: 3); defer { sync.stop() }
        r.isAvailable = false
        sync.bootstrap(); await sync.requestAuthorization(); await sync.syncRecent()
        #expect(o.starts == 0 && r.authorized.isEmpty && r.quantityCalls.isEmpty)
        r.isAvailable = true
        await sync.syncRecent(days: 30); await sync.drainUploads()
        #expect(r.quantityCalls.count == 3)
        #expect(await u.all().count == 3)
    }

    @Test func authorizationSelectionAndObserverLifecycle() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let r = FakeHealthReader(), o = FakeHealthObservation(), u = HealthUploads()
        let birth = HKCharacteristicType(.dateOfBirth)
        let metric = HealthMetric(id: "custom", label: "Custom", unit: "count", sampleTypes: [steps],
            additionalReadTypes: [birth]) { _, _ in nil }
        let sync = make(f, r, o, u, days: 1, metrics: [metric]); defer { sync.stop() }
        sync.bootstrap(); sync.bootstrap()
        #expect(o.starts == 1)
        await sync.requestAuthorization()
        #expect(r.authorized == Set([steps as HKObjectType, birth]))
        #expect(o.stops == 1 && o.starts == 2)
        #expect(f.defaults.bool(forKey: "health.authorizationRequested"))
        // The completion runs on the main actor, so this local mutation is safe.
        nonisolated(unsafe) var completed = false
        o.handlers[steps.identifier]?(nil, { completed = true })
        for _ in 0..<100 where !completed { await Task.yield() }
        #expect(completed)
        sync.stop()
        #expect(o.stops == 2 && o.handlers.isEmpty)
    }

    @Test func lockedStoreStopsQueriesAndRecovers() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let r = FakeHealthReader(), o = FakeHealthObservation(), u = HealthUploads()
        let sync = make(f, r, o, u); defer { sync.stop() }
        r.changeError = NSError(domain: HKErrorDomain, code: HKError.errorDatabaseInaccessible.rawValue)
        await sync.syncRecent()
        #expect(r.quantityCalls.isEmpty)
        #expect(sync.lastError?.contains("locked") == true)
        #expect(sync.lastSyncAt == nil)
        r.changeError = nil
        await sync.syncRecent(); await sync.drainUploads()
        #expect(sync.lastError == nil && sync.status.lastError == nil)
        #expect(await u.all().count == 7)
    }

    @Test(arguments: [false, true]) func emptyVisibilityDoesNotOverwriteButKnownDeletionDoes(throwsNoData: Bool) async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let r = FakeHealthReader(), o = FakeHealthObservation(), u = HealthUploads()
        let sync = make(f, r, o, u, days: 1); defer { sync.stop() }
        let now = Date()
        let sample = HKQuantitySample(type: steps, quantity: HKQuantity(unit: .count(), doubleValue: 12), start: now, end: now)
        r.pages = [.init(samples: [sample], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 1), hasMore: false)]
        await sync.syncToday(); await sync.drainUploads()
        r.quantityValue = nil
        if throwsNoData {
            r.quantityError = NSError(domain: HKErrorDomain, code: HKError.errorNoData.rawValue)
        }
        await sync.syncToday(); await sync.drainUploads()
        #expect(await u.all().count == 1)
        r.pages = [.init(samples: [], deletedIDs: [sample.uuid], anchor: HKQueryAnchor(fromValue: 2), hasMore: false)]
        await sync.syncToday(); await sync.drainUploads()
        #expect(await u.all().map(\.value) == [12, 0])
    }

    @Test func finiteValidationAndReadErrorsDoNotUploadInvalidValues() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let r = FakeHealthReader(), o = FakeHealthObservation(), u = HealthUploads()
        let sync = make(f, r, o, u, days: 1); defer { sync.stop() }
        r.quantityValue = .nan
        await sync.syncToday(); await sync.drainUploads()
        #expect(sync.lastError != nil && sync.lastSyncAt == nil)
        #expect(await u.all().isEmpty)
        r.quantityError = URLError(.cannotLoadFromNetwork)
        await sync.syncToday(); await sync.drainUploads()
        #expect(await u.all().isEmpty)
        r.quantityError = nil; r.quantityValue = 8
        await sync.syncToday(); await sync.drainUploads()
        #expect(sync.lastError == nil)
        #expect(await u.all().map(\.value) == [8])
    }

    @Test func fullChangePageContinuesAndUsesItsAnchor() async throws {
        let f = try HealthFixture(); defer { f.clean() }
        let r = FakeHealthReader(), o = FakeHealthObservation(), u = HealthUploads()
        let sync = make(f, r, o, u, days: 1); defer { sync.stop() }
        r.pages = [.init(samples: [], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 500), hasMore: true),
                   .init(samples: [], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 501), hasMore: false)]
        await sync.syncToday(); await sync.drainUploads()
        #expect(r.changeCalls.count == 2)
        #expect(r.changeCalls[0].3 == nil && r.changeCalls[1].3 != nil)
        #expect(!sync.status.healthHistoryCatchingUp)
    }
}
