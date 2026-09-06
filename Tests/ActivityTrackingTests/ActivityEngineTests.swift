import CoreLocation
import CoreMotion
import Foundation
import Testing
@testable import ActivityTracking

// Unit tests for the Activity Engine FSM. The engine talks to the world only
// through LocationControlling + ActivityBackend, so these run with fakes and
// an injected clock — no device, no CoreLocation/CoreMotion managers.
//
// Events are delivered through the engine's serial intake (`handle` = post +
// wait-for-idle), so each `await` returns only once the event (and anything it
// queued behind it) has been fully processed — the same ordering guarantee the
// coordinator relies on in production.

// ─── Fakes ───────────────────────────────────────────────────────────
@MainActor
final class FakeControl: LocationControlling {
    enum Call: Equatable {
        case setContinuous
        case stop
        case arm(String)
        case remove(String)
    }
    var calls: [Call] = []
    var continuousOn = false
    var armed: Set<String> = []
    var requestedStateFor: [String] = []

    func setContinuous(_ decision: SamplingDecision) {
        calls.append(.setContinuous); continuousOn = true
    }
    func stopContinuous() { calls.append(.stop); continuousOn = false }
    func armGeofence(id: String, center: CLLocationCoordinate2D, radius: CLLocationDistance) {
        calls.append(.arm(id)); armed.insert(id)
    }
    func removeGeofence(id: String) { calls.append(.remove(id)); armed.remove(id) }
    func requestState(id: String) { requestedStateFor.append(id) }
}

@MainActor
final class FakeBackend: TrackingOutput {
    var samples: [LocationSample] = []
    var homes: [LocationCoordinator.HomeLocation] = []
    var flushes = 0
    func recordSample(_ sample: LocationSample) { samples.append(sample) }
    func recordHome(_ home: LocationCoordinator.HomeLocation) { homes.append(home) }
    func flush() async { flushes += 1 }
    struct Outing { let clientId: String; var mode: String; var endedAt: Date? }
    struct Segment { let clientId: String; let type: String; var endedAt: Date?; var distance: Double?; var maxSpeed: Double? }
    var outings: [Outing] = []
    var segments: [String: Segment] = [:]   // keyed by clientSegmentId
    var segmentOrder: [String] = []
    var places: [(lat: Double, lng: Double)] = []
    var farRecords: [String] = []
    var farthest: Double = 0
    var sessions: [String] = []
    var outingAnchors: [(lat: Double?, lng: Double?)] = []
    var outingSources: [String] = []
    func startSession(clientOutingId: String, at: Date) async -> String? {
        sessions.append(clientOutingId)
        outings.append(Outing(clientId: clientOutingId, mode: "session", endedAt: nil))
        return clientOutingId
    }
    private var seq = 0
    private func nextId(_ p: String) -> String { seq += 1; return "\(p)\(seq)" }

    func startOuting(clientOutingId: String, mode: String, source: String, at: Date, homeLat: Double?, homeLng: Double?) async -> String? {
        outingAnchors.append((homeLat, homeLng))
        outingSources.append(source)
        // Idempotent on clientOutingId (mirrors the real upsert).
        if !outings.contains(where: { $0.clientId == clientOutingId }) {
            outings.append(Outing(clientId: clientOutingId, mode: mode, endedAt: nil))
        }
        return nextId("o")
    }
    func endOuting(clientOutingId: String, at: Date) async {
        if let i = outings.firstIndex(where: { $0.clientId == clientOutingId }) { outings[i].endedAt = at }
    }
    func setOutingMode(clientOutingId: String, mode: String) async {
        if let i = outings.firstIndex(where: { $0.clientId == clientOutingId }) { outings[i].mode = mode }
    }
    func markFarRecord(clientOutingId: String) async { farRecords.append(clientOutingId) }
    func bumpMaxDistance(clientOutingId: String, meters: Double) async {}
    func startSegment(clientSegmentId: String, clientOutingId: String, type: String, at: Date, placeId: String?) async {
        if segments[clientSegmentId] == nil {     // idempotent on clientSegmentId
            segments[clientSegmentId] = Segment(clientId: clientSegmentId, type: type, endedAt: nil, distance: nil, maxSpeed: nil)
            segmentOrder.append(clientSegmentId)
        }
    }
    func endSegment(clientSegmentId: String, at: Date, distanceMeters: Double, maxSpeed: Double, placeId: String?) async {
        segments[clientSegmentId]?.endedAt = at
        segments[clientSegmentId]?.distance = distanceMeters
        segments[clientSegmentId]?.maxSpeed = maxSpeed
    }
    // One-shot hook fired *inside* upsertPlace, to simulate a delegate signal
    // arriving while beginDwell is awaiting (the dangling-dup race). With the
    // serial queue this should post a fresh event, not re-enter directly.
    var onUpsertPlace: (() -> Void)?
    func upsertPlace(lat: Double, lng: Double, at: Date, clientSegmentId: String) async -> String? {
        places.append((lat, lng))
        if let h = onUpsertPlace { onUpsertPlace = nil; h() }
        return nextId("p")
    }
    func setFarthest(meters: Double) async { farthest = meters }

    var segmentTypesInOrder: [String] { segmentOrder.compactMap { segments[$0]?.type } }
}

// ─── Harness ─────────────────────────────────────────────────────────
// A mutable injected clock.
@MainActor
final class Clock {
    var t: Date
    init(_ d: Date = Date(timeIntervalSince1970: 1_780_000_000)) { self.t = d }
    func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
    var date: Date { t }
}

@MainActor
private func engineWithClock(seedPR: Double = 0) -> (ActivityEngine, FakeControl, FakeBackend, Clock) {
    let control = FakeControl()
    let backend = FakeBackend()
    let clock = Clock()
    var st = EngineState()
    st.lastPersonalRecord = seedPR
    let engine = ActivityEngine(
        control: control, backend: backend,
        home: { (lat: 40.0, lng: -86.0, radius: 75) },
        now: { clock.t }, state: st, persist: { _ in }
    )
    return (engine, control, backend, clock)
}

// A point ~`m` meters east of home (≈ at this latitude) for distance tests.
private func east(of lng: Double, meters: Double) -> Double {
    lng + meters / 85_000.0
}

// ─── Tests ───────────────────────────────────────────────────────────

@Suite @MainActor
struct ActivityEngineTests {

    @Test("Drive → in-vehicle stop → dwell → drive home yields [transit, dwell, transit]")
    func driveDwellDrive() async {
        let (engine, control, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)

        await engine.handle(.homeExit(at: clock.date))
        #expect(control.continuousOn)               // GPS armed for the drive
        #expect(engine.state.phase == .transit)

        // Drive out 1 km.
        clock.advance(30)
        await engine.handle(.sample(lat: 40.0, lng: east(of: -86.0, meters: 1000), speed: 20, at: clock.date))

        // Park and sit (speed→0) for > T at the same spot.
        clock.advance(5)
        await engine.handle(.sample(lat: 40.0, lng: east(of: -86.0, meters: 1000), speed: 0, at: clock.date))
        clock.advance(ActivityEngine.dwellConfirmSeconds + 1)
        await engine.handle(.sample(lat: 40.0, lng: east(of: -86.0, meters: 1000), speed: 0, at: clock.date))

        #expect(engine.state.phase == .onSite)
        #expect(!control.continuousOn)              // GPS cut at the dwell
        #expect(control.armed.contains(ActivityEngine.dwellGeofenceId))
        #expect(backend.places.count == 1)

        // Get back in the car → drive home.
        clock.advance(120)
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.dwellExit(lat: 40.0, lng: east(of: -86.0, meters: 1000), at: clock.date))
        #expect(engine.state.phase == .transit)
        #expect(control.continuousOn)

        clock.advance(60)
        await engine.handle(.homeEnter(at: clock.date))
        #expect(engine.state.phase == .atHome)
        #expect(!control.continuousOn)

        #expect(backend.segmentTypesInOrder == ["transit", "dwell", "transit"])
        #expect(backend.outings.first?.endedAt != nil)
    }

    @Test("A stoplight (brief stop under T) does not create a dwell")
    func stoplightNoDwell() async {
        let (engine, control, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))

        let lng = east(of: -86.0, meters: 800)
        await engine.handle(.sample(lat: 40.0, lng: lng, speed: 0, at: clock.date))  // stop
        clock.advance(45)                                                            // < T
        await engine.handle(.sample(lat: 40.0, lng: lng, speed: 12, at: clock.date)) // moving again

        #expect(engine.state.phase == .transit)
        #expect(control.continuousOn)
        #expect(backend.places.isEmpty)
        #expect(backend.segmentTypesInOrder == ["transit"])
    }

    @Test("Walking out the front door starts a no-GPS walk outing")
    func walkFromHome() async {
        let (engine, control, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.walking, .high)

        await engine.handle(.homeExit(at: clock.date))
        #expect(engine.state.phase == .onSite)
        #expect(engine.state.outingMode == "walk")
        #expect(!control.continuousOn)               // GPS never armed for a walk
        #expect(backend.segmentTypesInOrder == ["onfoot"])

        clock.advance(600)
        await engine.handle(.homeEnter(at: clock.date))
        #expect(engine.state.phase == .atHome)
        #expect(backend.outings.first?.mode == "walk")
    }

    @Test("Roaming on foot out of the dwell fence re-anchors instead of departing")
    func bigParkRoam() async {
        let (engine, control, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))
        let lng = east(of: -86.0, meters: 1500)
        await engine.handle(.sample(lat: 40.0, lng: lng, speed: 0, at: clock.date))
        clock.advance(ActivityEngine.dwellConfirmSeconds + 1)
        await engine.handle(.sample(lat: 40.0, lng: lng, speed: 0, at: clock.date))
        #expect(engine.state.phase == .onSite)

        // Walk out of the fence (motion=walking, not a vehicle): stay OnSite.
        clock.advance(120)
        engine._setRegimeForTest(.walking, .high)
        let newLng = east(of: -86.0, meters: 1700)
        await engine.handle(.dwellExit(lat: 40.0, lng: newLng, at: clock.date))
        #expect(engine.state.phase == .onSite)       // did NOT promote to transit
        #expect(!control.continuousOn)               // GPS stayed off
        #expect(backend.outings.first?.endedAt == nil)
    }

    @Test("A second home-exit (jitter / cold-wake) does not start a duplicate outing")
    func noDuplicateOuting() async {
        let (engine, _, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))
        clock.advance(16)
        await engine.handle(.homeExit(at: clock.date))   // the bug repro
        #expect(backend.outings.count == 1)
    }

    @Test("Overlapping posts are serialized: a burst of duplicate exits + a sample yields one outing")
    func serializedIntakeNoInterleave() async {
        let (engine, control, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        // Fire several events WITHOUT awaiting between them — the production
        // shape where each CoreLocation callback used to spawn its own Task and
        // interleave at an await. The serial queue must process them in order.
        engine.post(.homeExit(at: clock.date))
        engine.post(.homeExit(at: clock.date))   // jitter / double-fire
        engine.post(.sample(lat: 40.0, lng: east(of: -86.0, meters: 500), speed: 18, at: clock.date))
        engine.post(.homeExit(at: clock.date))   // a third spurious exit
        await engine.waitForIdle()

        #expect(backend.outings.count == 1)       // exactly one, regardless of ordering
        #expect(engine.state.phase == .transit)
        #expect(control.continuousOn)
        #expect(backend.segmentTypesInOrder == ["transit"])
    }

    @Test("Crossing the prior Far PR flags the outing as a record")
    func farRecord() async {
        let (engine, _, backend, clock) = engineWithClock(seedPR: 1000)
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))

        await engine.handle(.sample(lat: 40.0, lng: east(of: -86.0, meters: 900), speed: 20, at: clock.date))
        #expect(backend.farRecords.isEmpty)           // under PR
        clock.advance(15)
        await engine.handle(.sample(lat: 40.0, lng: east(of: -86.0, meters: 1200), speed: 20, at: clock.date))
        #expect(backend.farRecords.count == 1)        // crossed PR + margin
    }

    @Test("A trigger that interleaves mid-beginDwell does not open a second dwell")
    func noDoubleDwellUnderReentrancy() async {
        let (engine, _, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))
        let lng = east(of: -86.0, meters: 1500)
        await engine.handle(.sample(lat: 40.0, lng: lng, speed: 0, at: clock.date))  // park, arm timer
        clock.advance(ActivityEngine.dwellConfirmSeconds + 1)
        // While beginDwell is awaiting upsertPlace, a second stopped sample
        // arrives. It must be queued (not re-entered) and processed only after
        // beginDwell completes — by which time phase is already .onSite.
        backend.onUpsertPlace = {
            engine.post(.sample(lat: 40.0, lng: lng, speed: 0, at: clock.date))
        }
        await engine.handle(.sample(lat: 40.0, lng: lng, speed: 0, at: clock.date))  // triggers beginDwell

        let dwells = backend.segmentTypesInOrder.filter { $0 == "dwell" }
        #expect(dwells.count == 1)
        #expect(engine.state.phase == .onSite)
    }

    @Test("A walk outing that later drives is relabeled mixed")
    func driveAfterWalkMarksMixed() async {
        let (engine, _, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.walking, .high)
        await engine.handle(.homeExit(at: clock.date))   // walk outing (GPS off)
        #expect(engine.state.phase == .onSite)
        #expect(backend.outings.first?.mode == "walk")

        // Get in a car and drive off (motion classifies automotive).
        clock.advance(300)
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.motion(.automotive, .high))
        #expect(engine.state.phase == .transit)
        #expect(backend.outings.first?.mode == "mixed")  // walked then drove
    }

    @Test("Bootstrap in OnSite re-arms the dwell fence AND requests its state (cold-wake exit catch)")
    func bootstrapOnSiteRequestsDwellState() {
        let control = FakeControl()
        var st = EngineState()
        st.phase = .onSite
        st.dwellAnchorLat = 40.0
        st.dwellAnchorLng = -86.0
        let engine = ActivityEngine(
            control: control, backend: FakeBackend(),
            home: { (lat: 40.0, lng: -86.0, radius: 75) },
            now: { Date(timeIntervalSince1970: 1_780_000_000) },
            state: st, persist: { _ in }
        )
        engine.bootstrap()
        #expect(control.armed.contains(ActivityEngine.dwellGeofenceId))
        #expect(control.requestedStateFor.contains(ActivityEngine.dwellGeofenceId))
    }

    @Test("Outing start time is persisted so elapsed survives a reload")
    func outingStartedAtPersisted() async {
        let (engine, _, _, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))
        #expect(engine.state.outingStartedAt == clock.date)
        clock.advance(120)
        await engine.handle(.homeEnter(at: clock.date))
        #expect(engine.state.outingStartedAt == nil)   // cleared on end
    }

    @Test("Outing client ID is durable across an EngineState reload")
    func clientIdStableAcrossReload() async {
        var saved = EngineState()
        let engine = ActivityEngine(
            control: FakeControl(), backend: FakeBackend(),
            home: { (lat: 40.0, lng: -86.0, radius: 75) },
            now: { Date(timeIntervalSince1970: 1_780_000_000) },
            state: EngineState(), persist: { saved = $0 }
        )
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: Date(timeIntervalSince1970: 1_780_000_000)))
        let cid = engine.state.clientOutingId
        #expect(cid != nil)

        // A fresh engine rehydrated from the persisted state keeps the same id.
        let engine2 = ActivityEngine(
            control: FakeControl(), backend: FakeBackend(),
            home: { (lat: 40.0, lng: -86.0, radius: 75) },
            now: { Date(timeIntervalSince1970: 1_780_000_000) },
            state: saved, persist: { _ in }
        )
        #expect(engine2.state.clientOutingId == cid)
    }

    @Test("Boot reconcile: away while state says home starts exactly one outing")
    func reconcileMissedDeparture() async {
        let (engine, control, backend, _) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.reconcile(homeInside: false))   // we left while the app was off
        #expect(engine.state.phase == .transit)
        #expect(engine.state.clientOutingId != nil)
        #expect(control.continuousOn)
        #expect(backend.outings.count == 1)
        // A repeated requestState callback must not double-start.
        await engine.handle(.reconcile(homeInside: false))
        #expect(backend.outings.count == 1)
    }

    @Test("Boot reconcile: home while state says away ends the stale outing")
    func reconcileCameHomeWhileOff() async {
        let (engine, _, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))   // open outing, phase transit
        #expect(backend.outings.first?.endedAt == nil)
        await engine.handle(.reconcile(homeInside: true)) // we got home while the app was off
        #expect(engine.state.phase == .atHome)
        #expect(engine.state.clientOutingId == nil)
        #expect(backend.outings.first?.endedAt != nil)
        // Idempotent.
        await engine.handle(.reconcile(homeInside: true))
        #expect(engine.state.phase == .atHome)
    }

    @Test("Boot reconcile: away while already on an outing is a no-op (resume)")
    func reconcileResumeNoOp() async {
        let (engine, _, backend, clock) = engineWithClock()
        engine._setRegimeForTest(.automotive, .high)
        await engine.handle(.homeExit(at: clock.date))
        let cid = engine.state.clientOutingId
        await engine.handle(.reconcile(homeInside: false))  // already away — resume, don't restart
        #expect(engine.state.clientOutingId == cid)
        #expect(backend.outings.count == 1)
    }
}
