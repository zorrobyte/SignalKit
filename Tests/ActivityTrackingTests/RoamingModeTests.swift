import CoreLocation
import CoreMotion
import Foundation
import Testing
@testable import ActivityTracking

// Roaming mode: no fixed home. Outings begin on departure signals and end once
// a stop has lasted the rest threshold; that stop becomes the next base.

@MainActor
private func roamingEngine(restThreshold: TimeInterval = 3600, state: EngineState = EngineState())
    -> (ActivityEngine, FakeControl, FakeBackend, Clock) {
    let control = FakeControl(), backend = FakeBackend(), clock = Clock()
    let engine = ActivityEngine(control: control, backend: backend, home: { nil },
        now: { clock.t }, state: state, persist: { _ in }, mode: .roaming(restThreshold: restThreshold))
    return (engine, control, backend, clock)
}

private func east(of lng: Double, meters: Double) -> Double { lng + meters / 85_000.0 }

@Suite @MainActor
struct RoamingEngineTests {

    @Test("Vehicle motion from rest starts a drive outing with no anchor; a long stop ends it and becomes the base")
    func departRestDepartAgain() async {
        let (engine, control, backend, clock) = roamingEngine()
        #expect(engine.anchor == nil)

        await engine.handle(.motion(.automotive, .high))
        #expect(engine.state.phase == .transit && control.continuousOn)
        #expect(backend.outings.count == 1 && backend.outingSources == ["roaming"])
        #expect(backend.outingAnchors.first?.lat == nil)

        // Drive 5 km, then park for longer than the rest threshold.
        clock.advance(300)
        await engine.handle(.sample(lat: 40, lng: east(of: -86, meters: 5000), speed: 20, at: clock.date))
        clock.advance(5)
        await engine.handle(.sample(lat: 40, lng: east(of: -86, meters: 5000), speed: 0, at: clock.date))
        clock.advance(ActivityEngine.dwellConfirmSeconds + 1)
        await engine.handle(.sample(lat: 40, lng: east(of: -86, meters: 5000), speed: 0, at: clock.date))
        #expect(engine.state.phase == .onSite && !control.continuousOn)
        #expect(backend.outings[0].endedAt == nil)          // a short stop is a dwell inside the outing

        clock.advance(3600)
        await engine.handle(.tick(at: clock.date))
        #expect(engine.state.phase == .atHome)
        #expect(backend.outings[0].endedAt == clock.date)
        #expect(backend.segmentTypesInOrder == ["transit", "dwell"])
        #expect(engine.anchor?.lat == 40 && engine.state.baseLng == east(of: -86, meters: 5000))
        #expect(control.armed.contains(ActivityEngine.dwellGeofenceId))   // base fence stays armed

        // Leaving the base fence starts the next outing, anchored at the rest stop.
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.dwellExit(lat: 40, lng: east(of: -86, meters: 5200), at: clock.date))
        #expect(engine.state.phase == .transit && backend.outings.count == 2)
        #expect(backend.outingAnchors[1].lng == east(of: -86, meters: 5000))
        #expect(!control.armed.contains(ActivityEngine.dwellGeofenceId))
    }

    @Test("A slow first fix adopts the starting location as the base; a fast fix departs")
    func firstFixAndSpeedDeparture() async {
        let (engine, control, backend, clock) = roamingEngine()
        await engine.handle(.sample(lat: 40, lng: -86, speed: 0, at: clock.date))
        #expect(engine.anchor?.lat == 40 && engine.state.phase == .atHome)
        #expect(control.armed.contains(ActivityEngine.dwellGeofenceId) && backend.outings.isEmpty)

        clock.advance(60)
        await engine.handle(.sample(lat: 40, lng: east(of: -86, meters: 300), speed: 1, at: clock.date))
        #expect(backend.outings.isEmpty)                    // slow fixes near base do not depart

        clock.advance(60)
        await engine.handle(.sample(lat: 40, lng: east(of: -86, meters: 900), speed: 15, at: clock.date))
        #expect(engine.state.phase == .transit && backend.outings.count == 1)
        #expect(backend.outingAnchors[0].lat == 40)
        #expect(engine.state.lastSampleLat == 40)           // the departing fix is the first point
    }

    @Test("Walking or low-confidence motion at rest does not start an outing; home events are ignored")
    func restIgnoresWeakSignals() async {
        let (engine, _, backend, clock) = roamingEngine()
        await engine.handle(.motion(.walking, .high))
        await engine.handle(.motion(.automotive, .low))
        await engine.handle(.homeExit(at: clock.date))
        await engine.handle(.reconcile(homeInside: false))
        #expect(engine.state.phase == .atHome && backend.outings.isEmpty)
    }

    @Test("Bootstrap while resting re-arms the base fence and requests its state")
    func bootstrapAtBase() {
        var st = EngineState(); st.baseLat = 40; st.baseLng = -86
        let (engine, control, _, _) = roamingEngine(state: st)
        engine.bootstrap()
        #expect(control.armed.contains(ActivityEngine.dwellGeofenceId))
        #expect(control.requestedStateFor == [ActivityEngine.dwellGeofenceId])
    }

    @Test("Manual end while driving makes the last fix the base")
    func manualEndSetsBase() async {
        let (engine, control, backend, clock) = roamingEngine()
        await engine.handle(.motion(.automotive, .high))
        await engine.handle(.sample(lat: 41, lng: -87, speed: 20, at: clock.date))
        await engine.handle(.manualEnd(at: clock.date))
        #expect(engine.state.phase == .atHome && backend.outings[0].endedAt != nil)
        #expect(engine.anchor?.lat == 41 && control.armed.contains(ActivityEngine.dwellGeofenceId))
    }

    @Test("Switching modes ends the open outing, drops the base, and honors the new rules")
    func switchModes() async {
        let (engine, control, backend, clock) = roamingEngine()
        await engine.handle(.motion(.automotive, .high))
        await engine.handle(.setMode(.homeAnchored))
        #expect(engine.mode == .homeAnchored && engine.state.phase == .atHome)
        #expect(backend.outings[0].endedAt != nil && engine.state.baseLat == nil)
        #expect(!control.armed.contains(ActivityEngine.dwellGeofenceId))

        // Home-anchored with no home: vehicle motion no longer starts anything.
        await engine.handle(.motion(.automotive, .high))
        await engine.handle(.tick(at: clock.date))
        #expect(backend.outings.count == 1)

        await engine.handle(.setMode(.roaming()))
        await engine.handle(.setMode(.roaming()))           // same mode is a no-op
        #expect(engine.mode == .roaming() && TrackingMode.roaming().restThreshold == 4 * 3600)
        await engine.handle(.motion(.automotive, .high))
        #expect(backend.outings.count == 2)
    }
}

@Suite @MainActor
struct RoamingCoordinatorTests {

    @Test("Roaming bootstrap ignores a saved home, asks for a fix, and adopts it as the base")
    func roamingBootstrap() async {
        let f = TrackingFixture(mode: .roaming(restThreshold: 60)); defer { f.clean() }
        f.coordinator.home = .init(lat: 40, lng: -86, accuracy: 5, radius: 75, setAt: Date())
        f.coordinator.bootstrap()
        #expect(f.coordinator.trackingMode.isRoaming)
        #expect(!f.radio.calls.contains("arm:home") && f.radio.calls.contains("fix"))

        await f.send([f.fix(lat: 45, lng: -90)])
        await f.settle { f.radio.calls.contains("arm:dwell") }
        #expect(f.coordinator.anchorCoordinate?.latitude == 45)
        #expect(f.defaults.dictionary(forKey: "location.home.v1") == nil)   // no default home saved
        #expect(f.output.homes.isEmpty)
    }

    @Test("Toggling modes at runtime swaps the fences and flushes")
    func toggleModes() async {
        let f = TrackingFixture(); defer { f.clean() }
        f.coordinator.home = .init(lat: 40, lng: -86, accuracy: 5, radius: 75, setAt: Date())
        f.coordinator.bootstrap()
        #expect(f.radio.calls.contains("arm:home"))
        await f.send([f.fix(lat: 40, lng: -86)])

        await f.settle { f.output.samples.count == 1 }
        await f.coordinator.setTrackingMode(.roaming(restThreshold: 60))
        #expect(f.radio.calls.contains("remove:home") && f.radio.calls.contains("arm:dwell"))
        #expect(f.coordinator.anchorCoordinate?.latitude == 40)

        await f.coordinator.setTrackingMode(.homeAnchored)
        #expect(f.radio.calls.filter { $0 == "arm:home" }.count == 2)
        #expect(f.coordinator.anchorCoordinate?.longitude == -86)
    }
}

@Suite @MainActor
struct RoamingCoordinatorDelegateTests {

    @Test("Native motion, a rest timer, and refresh drive a roaming outing end to end")
    func nativeSignalsAndRestTimer() async {
        let f = TrackingFixture(mode: .roaming(restThreshold: 0.05), motionAvailable: true); defer { f.clean() }
        f.coordinator.bootstrap()
        await f.send([f.fix(lat: 45, lng: -90)])
        await f.settle { f.radio.calls.contains("arm:dwell") }

        // Getting into a vehicle (through the native motion driver) departs.
        f.motionDriver.handler?(MotionObservation(automotive: true, confidence: .high, startDate: Date()))
        await f.settle { f.radio.calls.contains("gps.start") }
        #expect(f.coordinator.enginePhase == .transit && f.coordinator.currentOutingStartedAt != nil)

        // Arrive: a fix, then walking with confidence → dwell. The tiny rest
        // threshold lets the coordinator's timer end the outing.
        await f.send([f.fix(lat: 45.1, lng: -90, speed: 20)])
        await f.settle { f.output.samples.count == 2 }
        f.motionDriver.handler?(MotionObservation(walking: true, confidence: .high, startDate: Date()))
        await f.settle { f.output.places.count == 1 }
        for _ in 0..<300 where f.output.outings[0].endedAt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(f.coordinator.enginePhase == .atHome)
        #expect(f.output.outings.count == 1 && f.output.outings[0].endedAt != nil)
        #expect(f.coordinator.anchorCoordinate?.latitude == 45.1)

        // Refresh is harmless at rest, and an authorization change with no base
        // yet asks for a fix.
        await f.coordinator.refreshTrackingState()
        #expect(f.coordinator.enginePhase == .atHome)
    }

    @Test("Base fence exit and cold-boot outside state start the next outing")
    func baseFenceDelegate() async {
        let f = TrackingFixture(mode: .roaming(restThreshold: 60), motionAvailable: true); defer { f.clean() }
        f.coordinator.bootstrap()
        await f.send([f.fix(lat: 45, lng: -90)])
        await f.settle { f.radio.calls.contains("arm:dwell") }
        let fence = CLCircularRegion(center: .init(latitude: 45, longitude: -90), radius: 120, identifier: "dwell")

        f.motionDriver.handler?(MotionObservation(automotive: true, confidence: .medium, startDate: Date()))
        // Motion alone already departs; end manually to get back to rest, then
        // use the fence exit path.
        await f.settle { f.output.outings.count == 1 && f.radio.calls.contains("gps.start") }
        await f.coordinator.endCurrentOutingManually()
        #expect(f.coordinator.enginePhase == .atHome && f.output.outings.count == 1)

        f.coordinator.locationManager(f.nativeCallbackSender, didExitRegion: fence)
        await f.settle { f.output.outings.count == 2 }
        #expect(f.coordinator.enginePhase == .transit)
        await f.coordinator.endCurrentOutingManually()

        f.coordinator.locationManager(f.nativeCallbackSender, didDetermineState: .outside, for: fence)
        await f.settle { f.output.outings.count == 3 }
        #expect(f.coordinator.enginePhase == .transit)
    }

    @Test("Authorization arriving before any base asks for a fix and installs no home fence")
    func authorizationWithoutBase() async {
        let f = TrackingFixture(authorized: .notDetermined, mode: .roaming()); defer { f.clean() }
        f.coordinator.home = .init(lat: 40, lng: -86, accuracy: 5, radius: 75, setAt: Date())
        f.coordinator.bootstrap()
        f.radio.authorizationStatus = .authorizedAlways
        f.coordinator.locationManagerDidChangeAuthorization(f.nativeCallbackSender)
        await f.settle { f.radio.calls.contains("fix") }
        #expect(!f.radio.calls.contains("arm:home"))
    }
}
