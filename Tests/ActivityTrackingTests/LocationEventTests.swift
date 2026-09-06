import CoreLocation
import Foundation
import Testing
@testable import ActivityTracking

private final class SyntheticVisit: CLVisit, @unchecked Sendable {
    let point: CLLocationCoordinate2D, arrival: Date, departure: Date
    init(arrival: Date, departure: Date) {
        self.point = .init(latitude: 40.02, longitude: -86)
        self.arrival = arrival; self.departure = departure; super.init()
    }
    required init?(coder: NSCoder) { return nil }
    override var coordinate: CLLocationCoordinate2D { point }
    override var arrivalDate: Date { arrival }
    override var departureDate: Date { departure }
    override var horizontalAccuracy: CLLocationAccuracy { 500 }
}

@MainActor struct LocationEventTests {
    func home(_ f: TrackingFixture) -> CLCircularRegion {
        f.coordinator.home = .init(lat: 40, lng: -86, accuracy: 5, radius: 75, setAt: Date())
        return CLCircularRegion(center: .init(latitude: 40, longitude: -86), radius: 75, identifier: "home")
    }
    @Test func exitEnterAndDuplicateEventsRespectOutingBoundaries() async {
        let f = TrackingFixture(); defer { f.clean() }
        let region = home(f); var completed: [String] = []; var ended = 0
        f.coordinator.onOutingCompleted = { completed.append($0); _ = $1 }
        f.coordinator.onOutingEnded = { ended += 1 }
        f.coordinator.bootstrap(); await f.settle { f.output.flushes == 1 }
        f.coordinator.locationManager(f.nativeCallbackSender, didExitRegion: region)
        await f.settle { f.output.flushes == 2 }
        #expect(f.output.outings.count == 1 && f.coordinator.currentOutingStartedAt != nil)
        f.coordinator.locationManager(f.nativeCallbackSender, didExitRegion: region)
        await f.settle { f.output.flushes == 3 }
        #expect(f.output.outings.count == 1)
        f.coordinator.locationManager(f.nativeCallbackSender, didEnterRegion: region)
        await f.settle { f.output.flushes == 4 }
        #expect(f.output.outings[0].endedAt != nil && completed.count == 1 && ended == 1)
        #expect(f.coordinator.currentOutingStartedAt == nil && f.coordinator.enginePhase == .atHome)
    }
    @Test func coldStateReconciliationAndUnknownRegion() async {
        let f = TrackingFixture(); defer { f.clean() }
        let region = home(f)
        f.coordinator.bootstrap(); await f.settle { f.output.flushes == 1 }
        f.coordinator.locationManager(f.nativeCallbackSender, didDetermineState: .outside, for: region)
        await f.settle { f.output.flushes == 2 }
        #expect(f.output.outings.count == 1)
        f.coordinator.locationManager(f.nativeCallbackSender, didDetermineState: .inside, for: region)
        await f.settle { f.output.flushes == 3 }
        #expect(f.coordinator.enginePhase == .atHome)
        f.coordinator.locationManager(f.nativeCallbackSender, didDetermineState: .unknown, for: region)
        let unrelated = CLCircularRegion(center: region.center, radius: 50, identifier: "unrelated")
        f.coordinator.locationManager(f.nativeCallbackSender, didExitRegion: unrelated)
        await f.settle { f.output.flushes == 4 }
        #expect(f.output.outings.count == 1)
    }
    @Test func visitEventsKeepHistoricalObservationsButDoNotDriveEngine() async {
        let f = TrackingFixture(); defer { f.clean() }
        _ = home(f)
        var context = 0; f.coordinator.onContextChanged = { context += 1 }
        let arrival = Date().addingTimeInterval(-3_600)
        f.coordinator.locationManager(f.nativeCallbackSender,
            didVisit: SyntheticVisit(arrival: arrival, departure: .distantFuture))
        await f.settle { context == 1 }
        #expect(f.coordinator.isDwelling && f.coordinator.dwellingSince == arrival)
        #expect(f.output.samples.first?.source == "visit-arrival")
        #expect(f.output.samples.first?.accuracy == 500 && f.output.samples.first?.clientOutingId == nil)
        #expect(f.output.outings.isEmpty && f.output.places.isEmpty)
        f.coordinator.locationManager(f.nativeCallbackSender,
            didVisit: SyntheticVisit(arrival: arrival, departure: Date().addingTimeInterval(-300)))
        await f.settle { context == 2 }
        #expect(!f.coordinator.isDwelling && f.coordinator.dwellingCoord == nil)
        #expect(f.output.samples.last?.source == "visit-departure")
    }
    @Test func manualLifecycleUsesSameDurableEngineAndCallbacks() async {
        let f = TrackingFixture(); defer { f.clean() }
        _ = home(f)
        f.coordinator.bootstrap(); await f.settle { f.output.flushes == 1 }
        await f.coordinator.startManualSession()
        #expect(f.output.sessions.count == 1 && f.coordinator.currentOutingIsSession)
        await f.send([f.fix()])
        #expect(f.output.samples.last?.clientOutingId == nil)
        await f.coordinator.endCurrentOutingManually()
        #expect(f.output.outings[0].endedAt != nil && f.coordinator.enginePhase == .atHome)
    }
    @Test func authorizationDelegateUsesInjectedDriverAndLoadsSavedHome() async throws {
        let f = TrackingFixture(authorized: .notDetermined); defer { f.clean() }
        f.radio.authorizationStatus = .authorizedWhenInUse
        f.coordinator.locationManagerDidChangeAuthorization(f.nativeCallbackSender)
        await f.settle { f.coordinator.authStatus == .authorizedWhenInUse }
        #expect(f.radio.calls.contains("always") && f.radio.calls.contains("slc.start") && f.radio.calls.contains("fix"))
        f.coordinator.lastSample = f.fix()
        await f.coordinator.setHomeToCurrentLocation()
        let reload = LocationCoordinator(output: f.output, defaults: f.defaults, stateDefaults: f.stateDefaults,
            motion: MotionCoordinator(driver: FakeMotionDriver()), driver: FakeLocationDriver())
        #expect(reload.home?.lat == f.coordinator.home?.lat)
        #expect(reload.home?.lng == f.coordinator.home?.lng)
        #expect(reload.home?.accuracy == f.coordinator.home?.accuracy)
        #expect(reload.home?.radius == f.coordinator.home?.radius)
        let reloadedAt = try #require(reload.home?.setAt)
        let originalAt = try #require(f.coordinator.home?.setAt)
        // Persisting Unix seconds can round the native Date reference interval.
        #expect(abs(reloadedAt.timeIntervalSince(originalAt)) < 0.000001)
        f.radio.authorizationStatus = .authorizedAlways
        f.coordinator.locationManagerDidChangeAuthorization(f.nativeCallbackSender)
        await f.settle { f.coordinator.authStatus == .authorizedAlways }
        #expect(f.radio.calls.contains("state:home"))
    }
}
