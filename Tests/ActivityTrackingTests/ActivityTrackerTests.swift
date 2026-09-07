import CoreLocation
import Foundation
import Testing
@testable import ActivityTracking

@MainActor private final class Uploads {
    var events: [TrackingEvent] = []
    var failures = 0
    var kinds: [TrackingEvent.Kind] { events.map(\.kind) }
}

/// Builds the tracker exactly as a host would, but over fake radios, so the test
/// exercises the real coordinator, engine, and outbox with no sensors.
@MainActor private final class TrackerFixture {
    let suite = "SignalKitTrackerTests." + UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let radio = FakeLocationDriver(), motionDriver = FakeMotionDriver()
    let uploads = Uploads()
    let tracker: ActivityTracker
    let sender = CLLocationManager()

    init() {
        defaults = UserDefaults(suiteName: suite)!
        radio.authorizationStatus = .authorizedAlways
        radio.accuracyAuthorization = .fullAccuracy
        // MotionCoordinator reads availability once, in its initializer, and
        // start() is a no-op when classification is unavailable.
        motionDriver.available = true
        let uploads = self.uploads
        var configuration = DurableTrackingOutput.Configuration()
        configuration.retryBackoff = []
        configuration.retryDelay = 0
        configuration.minimumFlushInterval = 0
        tracker = ActivityTracker(storageDirectory: directory, defaults: defaults,
                                  configuration: configuration,
                                  locationDriver: radio, motionDriver: motionDriver) { batch in
            try await MainActor.run {
                if uploads.failures > 0 {
                    uploads.failures -= 1
                    throw URLError(.notConnectedToInternet)
                }
                uploads.events.append(contentsOf: batch)
            }
        }
    }

    func clean() {
        tracker.stop()
        tracker.location.stopContinuous()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func fix(lat: Double = 40, lng: Double = -86) -> CLLocation {
        CLLocation(coordinate: .init(latitude: lat, longitude: lng), altitude: 100,
                   horizontalAccuracy: 5, verticalAccuracy: 5, course: -1, speed: 2,
                   timestamp: Date())
    }

    func send(_ locations: [CLLocation]) async {
        tracker.location.locationManager(sender, didUpdateLocations: locations)
        await settle { self.tracker.pendingUploads == 0 && !self.uploads.events.isEmpty }
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "Tracker work should complete without a sensor or network wait")
    }
}

@MainActor struct ActivityTrackerTests {
    /// The point of the facade: a host that supplies only storage and an
    /// uploader gets collected data delivered, with no callback wiring at all.
    @Test func deliversEngineOutputToTheUploaderWithNoHostWiring() async {
        let f = TrackerFixture(); defer { f.clean() }
        f.tracker.bootstrap()
        await f.send([f.fix()])
        #expect(f.uploads.kinds.contains(.home))
        #expect(f.uploads.kinds.contains(.sample))
        #expect(f.tracker.pendingUploads == 0)
        #expect(f.tracker.lastUploadedAt != nil)
        #expect(f.tracker.lastUploadError == nil)
        #expect(f.tracker.storageError == nil)
        #expect(f.motionDriver.starts == 1)
    }

    /// Host callbacks are forwarded, and installing them does not displace the
    /// upload wiring the way assigning them on `location` directly would.
    @Test func forwardsHostCallbacksWhileStillDrivingUploads() async {
        let f = TrackerFixture(); defer { f.clean() }
        var snapshots = 0, wakes = 0, distances: [Double] = [], completed: [String] = []
        f.tracker.onSnapshot = { snapshots += 1 }
        f.tracker.onWake = { wakes += 1 }
        f.tracker.onDistanceChanged = { distances.append($0) }
        f.tracker.onOutingCompleted = { id, _ in completed.append(id) }
        f.tracker.bootstrap()
        await f.send([f.fix()])
        #expect(wakes >= 1)
        #expect(snapshots > 0)
        #expect(!f.uploads.events.isEmpty)

        f.tracker.location.onOutingCompleted?("outing-1", Date())
        await f.settle { completed == ["outing-1"] }
        #expect(completed == ["outing-1"])
        #expect(distances.allSatisfy { $0 >= 0 })
    }

    @Test func retainsEventsAcrossAFailedUploadAndDrainsOnRecovery() async {
        let f = TrackerFixture(); defer { f.clean() }
        f.uploads.failures = 1
        f.tracker.bootstrap()
        f.tracker.location.locationManager(f.sender, didUpdateLocations: [f.fix()])
        await f.settle { f.tracker.pendingUploads > 0 && f.tracker.lastUploadError != nil }
        #expect(f.uploads.events.isEmpty)
        #expect(f.tracker.lastUploadError != nil)

        await f.tracker.drainUploads()
        #expect(f.tracker.pendingUploads == 0)
        #expect(f.uploads.kinds.contains(.sample))
        #expect(f.tracker.lastUploadError == nil)
    }

    /// Unguarded, this terminates the process: CoreLocation raises an
    /// Objective-C exception when background updates are enabled without the
    /// host background mode, which no Swift `catch` can intercept. The xctest
    /// host has no such mode, so reaching the end of this test is the assertion.
    /// The forwarded commands must actually reach the coordinator; a facade
    /// that quietly stopped forwarding would look fine at the call site.
    @Test func forwardedCommandsReachTheCoordinator() async {
        let f = TrackerFixture(); defer { f.clean() }
        f.tracker.bootstrap()
        // Already-Always needs no prompt; escalation is what must forward.
        f.tracker.location.authStatus = .authorizedWhenInUse
        f.tracker.requestAuthorization()
        #expect(f.radio.calls.contains("always"))

        f.tracker.setHome(.init(lat: 10, lng: 20, accuracy: 5, radius: 75, setAt: Date()))
        #expect(f.tracker.location.home?.lat == 10)
        await f.settle { !self.homeEvents(f).isEmpty }
        #expect(!homeEvents(f).isEmpty)

        await f.tracker.startManualSession()
        #expect(f.tracker.location.enginePhase == .session)
        await f.tracker.endCurrentOutingManually()
        #expect(f.tracker.location.enginePhase != .session)

        #expect(f.tracker.trackingMode == .homeAnchored)
        await f.tracker.setTrackingMode(.roaming(restThreshold: 60))
        #expect(f.tracker.trackingMode == .roaming(restThreshold: 60))

        f.tracker.onForeground()
        await f.settle { f.tracker.pendingUploads == 0 }
        #expect(f.tracker.pendingUploads == 0)
        #expect(f.uploads.kinds.contains(.sessionStart))
    }

    private func homeEvents(_ f: TrackerFixture) -> [TrackingEvent] {
        f.uploads.events.filter { $0.kind == .home }
    }

    @Test func realDriverRefusesBackgroundUpdatesWithoutTheHostBackgroundMode() {
        #expect(!CoreLocationDriver.hostDeclaresLocationBackgroundMode)
        let driver = CoreLocationDriver()
        driver.allowsBackgroundLocationUpdates = true
        #expect(!driver.allowsBackgroundLocationUpdates)
    }

    @Test func stopHaltsWorkButPreservesDurableEvents() async {
        let f = TrackerFixture(); defer { f.clean() }
        f.uploads.failures = 99
        f.tracker.bootstrap()
        f.tracker.location.locationManager(f.sender, didUpdateLocations: [f.fix()])
        // A first fix records home and a sample; wait for both so the count is
        // stable before stop(), rather than racing the second write.
        await f.settle { f.tracker.pendingUploads >= 2 }
        let pending = f.tracker.pendingUploads
        f.tracker.stop()
        #expect(f.motionDriver.stops == 1)
        #expect(f.tracker.pendingUploads == pending)   // stop is not a delete

        // A fresh tracker over the same directory replays what stop preserved.
        let recovered = Uploads()
        let reopened = ActivityTracker(storageDirectory: f.directory, defaults: f.defaults,
                                       locationDriver: FakeLocationDriver(),
                                       motionDriver: FakeMotionDriver()) { batch in
            await MainActor.run { recovered.events.append(contentsOf: batch) }
        }
        defer { reopened.stop() }
        await reopened.drainUploads()
        #expect(recovered.events.count == pending)
        #expect(reopened.pendingUploads == 0)
    }
}
