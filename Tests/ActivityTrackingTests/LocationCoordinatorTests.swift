import CoreLocation
import Foundation
import Testing
@testable import ActivityTracking

@MainActor struct LocationCoordinatorTests {
    @Test func bootstrapIsIdempotentAndRequestsFreshHomeFix() async {
        let f = TrackingFixture(); defer { f.clean() }
        var wakes = 0; f.coordinator.onWake = { wakes += 1 }
        f.coordinator.bootstrap(); f.coordinator.bootstrap()
        await f.settle { f.output.flushes == 1 }
        #expect(f.radio.calls.filter { $0 == "slc.start" }.count == 1)
        #expect(f.radio.calls.contains("visits.start") && f.radio.calls.contains("fix"))
        #expect(wakes == 1 && f.coordinator.canGetFix)
        #expect(f.radio.allowsBackgroundLocationUpdates && f.radio.showsBackgroundLocationIndicator)
    }
    @Test func permissionsUseCorrectStagesAndPrecisePurposeKey() {
        let f = TrackingFixture(authorized: .notDetermined, precise: .reducedAccuracy); defer { f.clean() }
        f.coordinator.requestAuthorization(); f.coordinator.requestPreciseAccuracy()
        #expect(f.radio.calls == ["whenInUse", "precise:preciseForOuting"])
        f.coordinator.authStatus = .authorizedWhenInUse
        f.coordinator.requestAuthorization()
        #expect(f.radio.calls.last == "always")
        f.coordinator.authStatus = .denied
        f.coordinator.requestAuthorization()
        #expect(f.radio.calls.count == 3 && !f.coordinator.canGetFix)
    }
    @Test func liveSampleGatesAndDefaultHomePreserveValidSIData() async throws {
        let f = TrackingFixture(); defer { f.clean() }
        await f.send([f.fix(age: 100), f.fix(accuracy: -1), f.fix(accuracy: 101), f.fix(age: -10)])
        #expect(f.output.samples.isEmpty && f.coordinator.home == nil)
        await f.send([f.fix(speed: 2, verticalAccuracy: 5)])
        #expect(f.output.samples.count == 1 && f.output.homes.count == 1)
        let saved = try #require(f.coordinator.home)
        #expect(saved.lat == 40 && saved.radius == 75)
        #expect(f.output.samples[0].altitude == 100 && f.output.samples[0].speed == 2)
        #expect(f.defaults.dictionary(forKey: "location.home.v1") != nil)
        #expect(f.stateDefaults.dictionary(forKey: "location.home.v1") != nil)
        await f.send([f.fix(lat: 40.01)])
        #expect(f.coordinator.home == saved && f.output.homes.count == 1)
        #expect(f.output.samples.last?.speed == nil && f.output.samples.last?.altitude == nil)
        let encoded = try JSONEncoder().encode(f.output.samples[0])
        #expect(try JSONDecoder().decode(LocationSample.self, from: encoded) == f.output.samples[0])
    }
    @Test func reducedAccuracyDoesNotChooseHome() async {
        let f = TrackingFixture(precise: .reducedAccuracy); defer { f.clean() }
        await f.send([f.fix()])
        #expect(f.coordinator.home == nil && f.output.homes.isEmpty)
    }
    @Test func gpsConfigurationThinningAndBackgroundLease() async {
        let f = TrackingFixture(); defer { f.clean() }
        // Avoid a new home changing engine state while testing stream thinning.
        f.coordinator.home = .init(lat: 40, lng: -86, accuracy: 5, radius: 75, setAt: Date())
        let decision = SamplingDecision(accuracy: 10, distanceFilter: 60, activityType: .fitness)
        f.coordinator.setContinuous(decision); f.coordinator.setContinuous(decision)
        #expect(f.radio.calls.filter { $0 == "gps.start" }.count == 1)
        #expect(f.radio.calls.filter { $0 == "background.start" }.count == 1)
        #expect(f.radio.distanceFilter == kCLDistanceFilterNone && !f.radio.pausesLocationUpdatesAutomatically)
        await f.send([f.fix()]); await f.send([f.fix()])
        #expect(f.output.samples.count == 1)
        f.coordinator.highAccuracyGPS = true
        await f.send([f.fix()])
        #expect(f.output.samples.count == 2)
        #expect(f.defaults.bool(forKey: "location.highAccuracyGPS.v1"))
        f.coordinator.stopContinuous(); f.coordinator.stopContinuous()
        #expect(f.radio.calls.filter { $0 == "gps.stop" }.count == 1)
        #expect(f.radio.calls.filter { $0 == "background.end" }.count == 1)
        #expect(!f.coordinator.continuousActive && f.radio.pausesLocationUpdatesAutomatically)
    }
    @Test func geofenceReplacementKeepsUnrelatedRegions() {
        let f = TrackingFixture(); defer { f.clean() }
        let center = CLLocationCoordinate2D(latitude: 40, longitude: -86)
        f.coordinator.armGeofence(id: "home", center: center, radius: 75)
        f.coordinator.armGeofence(id: "dwell", center: center, radius: 100)
        f.coordinator.armGeofence(id: "home", center: center, radius: 80)
        #expect(f.radio.monitoredRegions.count == 2)
        f.coordinator.requestState(id: "home")
        #expect(f.radio.calls.last == "state:home")
        f.coordinator.removeGeofence(id: "home")
        #expect(f.radio.monitoredRegions.map(\.identifier) == ["dwell"])
    }
    @Test func freshFixReturnsCachedValueAndDeniedFailsWithoutRadioWork() async {
        let f = TrackingFixture(); defer { f.clean() }
        let fresh = f.fix(); f.coordinator.lastSample = fresh
        #expect(await f.coordinator.requestFreshFix() === fresh)
        #expect(!f.radio.calls.contains("fix"))
        f.coordinator.authStatus = .denied
        #expect(await f.coordinator.requestFreshFix() == nil)
        await f.coordinator.setHomeToCurrentLocation()
        #expect(f.coordinator.lastError != nil)
    }
    @Test func freshFixCompletesFromDelegateAndFailure() async {
        let f = TrackingFixture(); defer { f.clean() }
        let request = Task { await f.coordinator.requestFreshFix(timeout: 2) }
        await f.settle { f.radio.calls.contains("fix") }
        #expect(await f.coordinator.requestFreshFix() == nil)
        await f.send([f.fix()])
        #expect(await request.value != nil)
        f.coordinator.lastSample = nil
        let count = f.radio.calls.count
        let failed = Task { await f.coordinator.requestFreshFix(timeout: 2) }
        await f.settle { f.radio.calls.count > count }
        f.coordinator.locationManager(f.nativeCallbackSender, didFailWithError: CLError(.locationUnknown))
        #expect(await failed.value == nil)
    }
    @Test func freshFixTimeoutAndExplicitHomeReplacement() async {
        let f = TrackingFixture(); defer { f.clean() }
        #expect(await f.coordinator.requestFreshFix(timeout: 0) == nil)
        f.coordinator.lastSample = f.fix()
        await f.coordinator.setHomeToCurrentLocation()
        #expect(f.output.homes.count == 1 && f.coordinator.lastError == nil)
        #expect(f.coordinator.distance(40, -86, 40, -86) == 0)
        #expect(f.coordinator.distance(40, -86, 40.01, -86) > 1_000)
    }
}
