import CoreLocation
import CoreMotion
import Foundation

// The away-from-home activity state machine. Idle and cheap at home; precise
// GPS is a guest invited only for vehicle transit. CoreMotion gates the GPS;
// SLC + geofences are the low-power backbone. Durable across cold wakes.
//
// This type is deliberately free of CoreLocation/CoreMotion *managers* — it
// talks to the world only through LocationControlling + ActivityBackend +
// injected clock/home, so it unit-tests with fakes. See Documentation/ActivityTracking.md.
//
// Ordering is guaranteed STRUCTURALLY, not by convention: callers `post(_:)`
// events into a serial queue that a single pump drains one at a time, so two
// signals can never interleave at an `await` (the bug that produced duplicate
// outings/segments when each delegate callback ran its own Task). The
// synchronous-phase-flip in each transition is kept as defense-in-depth.
@MainActor
public final class ActivityEngine {
    // ─── Event intake (serial) ───────────────────────────────────────
    // A signal from the outside world. Posted, queued, and processed FIFO by
    // a single pump — never reentrantly — so transitions are atomic w.r.t.
    // each other regardless of how the CoreLocation/CoreMotion callbacks fire.
    public enum Event {
        case homeExit(at: Date)
        case homeEnter(at: Date)
        case dwellExit(lat: Double, lng: Double, at: Date)
        case sample(lat: Double, lng: Double, speed: CLLocationSpeed?, at: Date)
        case motion(MotionCoordinator.MotionState, CMMotionActivityConfidence)
        case reconcile(homeInside: Bool)
        // User-initiated outing controls (the manual "Start/End session" UI):
        // modeled as a synthetic leave/return so they reuse the same transitions.
        case manualStart(at: Date)
        case manualEnd(at: Date)
    }
    private var queue: [Event] = []
    private var pumpTask: Task<Void, Never>?

    // Fired on the main actor after each event is fully processed, so the
    // coordinator can mirror the (now-updated) state into its observable UI /
    // Live Activity from one funnel instead of after each call site.
    public var onStateChanged: ((EngineState) -> Void)?
    public var onOutingCompleted: ((String, Date) -> Void)?
    // ─── Tunables (see spec) ─────────────────────────────────────────
    public static let stoppedSpeedMps: CLLocationSpeed = 1.0
    public static let dwellAnchorRadiusM: CLLocationDistance = 50
    public static let dwellConfirmSeconds: TimeInterval = 150
    public static let dwellGeofenceRadiusM: CLLocationDistance = 120
    public static let farRecordMarginM: CLLocationDistance = 50

    public static let homeGeofenceId = "home"
    public static let dwellGeofenceId = "dwell"

    // ─── Collaborators ───────────────────────────────────────────────
    private let control: LocationControlling
    private let backend: ActivityBackend
    private let now: () -> Date
    private let home: () -> (lat: Double, lng: Double, radius: Double)?
    private let persist: (EngineState) -> Void

    public private(set) var state: EngineState

    // Ephemeral (not persisted): latest motion read.
    private var regime: MotionCoordinator.MotionState = .unknown
    private var regimeConfidence: CMMotionActivityConfidence = .low

    public init(
        control: LocationControlling,
        backend: ActivityBackend,
        home: @escaping () -> (lat: Double, lng: Double, radius: Double)?,
        now: @escaping () -> Date = Date.init,
        state: EngineState,
        persist: @escaping (EngineState) -> Void
    ) {
        self.control = control
        self.backend = backend
        self.home = home
        self.now = now
        self.state = state
        self.persist = persist
    }

    // Production wiring: rehydrate durable state and persist to the App Group.
    public static func live(
        control: LocationControlling,
        backend: ActivityBackend,
        home: @escaping () -> (lat: Double, lng: Double, radius: Double)?,
        stateStore: EngineStateStore
    ) -> ActivityEngine {
        ActivityEngine(
            control: control, backend: backend, home: home,
            now: Date.init, state: stateStore.load(), persist: { stateStore.save($0) }
        )
    }

    // ─── Event intake ────────────────────────────────────────────────
    // Enqueue a signal and ensure the pump is running. Synchronous and
    // fire-and-forget: the caller does not block, and because the queue
    // append + pump-kick happen with no `await` between them, concurrent
    // posters on the main actor enqueue in a well-defined order.
    public func post(_ event: Event) {
        queue.append(event)
        if pumpTask == nil { startPump() }
    }

    // Await until the queue is drained. Safe to call from non-reentrant
    // contexts (the coordinator, tests) to order follow-up work — e.g. a WAL
    // drain — after the event has been applied. NEVER call from inside an
    // event's own processing (it would await itself).
    public func waitForIdle() async {
        while let t = pumpTask { await t.value }
    }

    // Post + await: the awaitable form used by the coordinator where ordering
    // matters (drain after the start-outing op is enqueued) and by tests.
    public func handle(_ event: Event) async {
        post(event)
        await waitForIdle()
    }

    private func startPump() {
        pumpTask = Task { @MainActor in
            // No `await` between the emptiness check and clearing pumpTask, so
            // a late post is always picked up before the loop exits.
            while !queue.isEmpty {
                let event = queue.removeFirst()
                await process(event)
                onStateChanged?(state)
            }
            pumpTask = nil
        }
    }

    private func process(_ event: Event) async {
        switch event {
        case let .homeExit(at):              await handleHomeExit(at: at)
        case let .homeEnter(at):             await handleHomeEnter(at: at)
        case let .dwellExit(lat, lng, at):   await handleDwellExit(lat: lat, lng: lng, at: at)
        case let .sample(lat, lng, spd, at): await handleSample(lat: lat, lng: lng, speed: spd, at: at)
        case let .motion(regime, conf):      await handleMotion(regime, confidence: conf)
        case let .reconcile(inside):         await reconcile(homeInside: inside)
        case let .manualStart(at):           await handleManualStart(at: at)
        case let .manualEnd(at):             await handleHomeEnter(at: at)   // same as coming home
        }
    }

    // ─── Lifecycle ───────────────────────────────────────────────────
    // Re-establish radio config matching the rehydrated phase after a cold
    // wake (the CLLocationManager came back blank).
    public func bootstrap() {
        switch state.phase {
        case .transit:
            control.setContinuous(SamplingPolicy.decide(regime: .automotive, speed: nil))
        case .onSite:
            if let lat = state.dwellAnchorLat, let lng = state.dwellAnchorLng {
                control.armGeofence(
                    id: Self.dwellGeofenceId,
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    radius: Self.dwellGeofenceRadiusM
                )
                // Catch a dwell-fence exit that happened while the app was dead:
                // ask for the region state now so didDetermineState can drive an
                // exit if we're already outside it.
                control.requestState(id: Self.dwellGeofenceId)
            }
        case .atHome:
            break
        case .session:
            control.stopContinuous()
        }
    }

    // ─── Signal handlers (reached only via process(_:), never directly) ──
    private func handleMotion(_ regime: MotionCoordinator.MotionState,
                              confidence: CMMotionActivityConfidence) async {
        self.regime = regime
        self.regimeConfidence = confidence

        // While moving in a vehicle, motion flipping to walking with confidence
        // means "got out" — an arrival. (The parked-but-still-automotive case
        // is caught by the speed→0 path in handleSample instead.)
        if state.phase == .transit, regime == .walking, confidence == .high,
           let lat = state.lastSampleLat, let lng = state.lastSampleLng {
            await beginDwell(atLat: lat, lng: lng)
            return
        }

        // While settled, motion returning to a vehicle means departure.
        if state.phase == .onSite, state.currentSegmentType == "onfoot",
           regime.isVehicle, confidence != .low {
            await departToTransit()
        }
    }

    private func handleHomeExit(at when: Date) async {
        // Reconcile: if we already believe we're out, a second exit is spurious
        // (boundary jitter / cold-wake double fire). This is the dup-outing fix:
        // phase is set synchronously below before any await, so a racing exit
        // queued behind this one bails here.
        guard state.phase == .atHome, home() != nil else { return }

        let walking = (regime == .walking)
        state.phase = walking ? .onSite : .transit
        persist(state)

        await startOuting(walking: walking, at: when)
    }

    private func handleHomeEnter(at when: Date) async {
        guard state.phase != .atHome else { return }
        await endOuting(at: when)
    }

    // Manual "Start session": behave like a home-fence exit but tag the source.
    private func handleManualStart(at when: Date) async {
        guard state.phase == .atHome else { return }
        state.phase = .session
        let cid = UUID().uuidString
        state.clientOutingId = cid
        state.outingStartedAt = when
        state.outingMode = nil
        state.maxDistanceMeters = 0
        state.farRecordFlagged = false
        resetSegmentAccumulation()
        persist(state)
        control.stopContinuous()
        state.openOutingId = await backend.startSession(clientOutingId: cid, at: when)
        persist(state)
    }

    // Dwell geofence crossed while GPS was off. coord = best-known position.
    private func handleDwellExit(lat: Double, lng: Double, at when: Date) async {
        guard state.phase == .onSite else { return }
        if regime.isVehicle || regime == .unknown {
            await departToTransit()                    // real departure
        } else {
            // Roaming on foot out of even the large fence (e.g. a big park):
            // re-anchor the dwell here, keep GPS off, stay OnSite.
            state.dwellAnchorLat = lat
            state.dwellAnchorLng = lng
            state.dwellSince = when
            persist(state)
            control.armGeofence(
                id: Self.dwellGeofenceId,
                center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                radius: Self.dwellGeofenceRadiusM
            )
        }
    }

    private func handleSample(lat: Double, lng: Double, speed: CLLocationSpeed?, at when: Date) async {
        guard state.phase == .transit || state.phase == .onSite else { return }
        if let previous = state.lastSampleAt, when <= previous { return }

        // Accepted location fixes provide a backstop when motion is denied or
        // stale. Keep walking/park roaming below the vehicle-speed threshold.
        if state.phase == .onSite {
            var inferredSpeed = 0.0
            if let previous = state.lastSampleAt,
               let plat = state.lastSampleLat, let plng = state.lastSampleLng {
                let elapsed = when.timeIntervalSince(previous)
                let moved = Self.distance(plat, plng, lat, lng)
                if elapsed >= 5, elapsed <= 300, moved >= 200 {
                    inferredSpeed = moved / elapsed
                }
            }
            if (speed ?? 0) >= 6 || inferredSpeed >= 6 {
                await departToTransit()
            }
        }

        // Max distance from home + Far personal-record milestone.
        if let h = home() {
            let d = Self.distance(h.lat, h.lng, lat, lng)
            if d > state.maxDistanceMeters {
                state.maxDistanceMeters = d
                if let cid = state.clientOutingId {
                    await backend.bumpMaxDistance(clientOutingId: cid, meters: d)
                }
                if !state.farRecordFlagged,
                   state.lastPersonalRecord > 0,
                   d > state.lastPersonalRecord + Self.farRecordMarginM,
                   let cid = state.clientOutingId {
                    state.farRecordFlagged = true
                    await backend.markFarRecord(clientOutingId: cid)
                }
            }
        }

        // Per-segment distance + max speed accumulation.
        if let plat = state.lastSampleLat, let plng = state.lastSampleLng {
            state.segmentDistanceMeters += Self.distance(plat, plng, lat, lng)
        }
        state.lastSampleLat = lat
        state.lastSampleLng = lng
        state.lastSampleAt = when
        if let s = speed, s > state.segmentMaxSpeed { state.segmentMaxSpeed = s }

        // Dwell detection only matters while GPS is on (transit). The parked-
        // in-vehicle case: speed→0 held within R for T while still "automotive".
        if state.phase == .transit {
            let stopped = (speed ?? 0) < Self.stoppedSpeedMps
            if stopped {
                if let alat = state.dwellAnchorLat, let alng = state.dwellAnchorLng,
                   Self.distance(alat, alng, lat, lng) <= Self.dwellAnchorRadiusM {
                    if let since = state.dwellSince,
                       when.timeIntervalSince(since) >= Self.dwellConfirmSeconds {
                        await beginDwell(atLat: alat, lng: alng)
                        return
                    }
                } else {
                    state.dwellAnchorLat = lat
                    state.dwellAnchorLng = lng
                    state.dwellSince = when
                }
            } else {
                state.dwellAnchorLat = nil
                state.dwellAnchorLng = nil
                state.dwellSince = nil
            }
        }

        persist(state)
    }

    // ─── Transitions ─────────────────────────────────────────────────
    private func startOuting(walking: Bool, at when: Date, source: String = "slc-auto") async {
        let mode = walking ? "walk" : "drive"
        guard let h = home() else { return }
        // Generate the durable identity SYNCHRONOUSLY; the FSM uses it from here
        // on and never depends on the backend's return (which may be nil offline).
        let cid = UUID().uuidString
        state.clientOutingId = cid
        state.outingMode = mode
        state.outingStartedAt = when
        state.maxDistanceMeters = 0
        state.farRecordFlagged = false
        resetSegmentAccumulation()
        persist(state)

        let serverId = await backend.startOuting(
            clientOutingId: cid, mode: mode, source: source, at: when,
            homeLat: h.lat, homeLng: h.lng
        )
        state.openOutingId = serverId   // advisory (nil offline)

        if walking {
            await openSegment(type: "onfoot", at: when, placeId: nil)
        } else {
            control.setContinuous(SamplingPolicy.decide(regime: regime, speed: nil))
            await openSegment(type: "transit", at: when, placeId: nil)
        }
        persist(state)
    }

    private func beginDwell(atLat lat: Double, lng: Double) async {
        guard state.phase == .transit, state.clientOutingId != nil else { return }
        let when = now()
        // Flip phase + dwell anchor SYNCHRONOUSLY (before any await) so a racing
        // trigger — e.g. motion=walking and a speed→0 sample firing near-
        // simultaneously — bails at the guard above instead of opening a second
        // dwell. This mirrors the synchronous phase-set in handleHomeExit.
        state.phase = .onSite
        state.dwellAnchorLat = lat
        state.dwellAnchorLng = lng
        state.dwellSince = when
        persist(state)

        await closeSegment(at: when)               // close the transit segment
        control.stopContinuous()
        control.armGeofence(
            id: Self.dwellGeofenceId,
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            radius: Self.dwellGeofenceRadiusM
        )
        resetSegmentAccumulation()
        await openSegment(type: "dwell", at: when, placeId: nil)
        if let sid = state.currentClientSegmentId {
            _ = await backend.upsertPlace(lat: lat, lng: lng, at: when, clientSegmentId: sid)
        }
        persist(state)
    }

    private func departToTransit() async {
        guard state.phase == .onSite else { return }
        let when = now()
        // Flip phase SYNCHRONOUSLY before any await so a second departure trigger
        // (dwell-fence exit + a motion=automotive signal) can't open two transits.
        state.phase = .transit
        state.dwellAnchorLat = nil
        state.dwellAnchorLng = nil
        state.dwellSince = nil
        persist(state)

        // An outing that began on foot and is now driving is "mixed" — learn it
        // and tell the backend (the start-time mode was provisional).
        if state.outingMode == "walk", let cid = state.clientOutingId {
            state.outingMode = "mixed"
            await backend.setOutingMode(clientOutingId: cid, mode: "mixed")
        }

        await closeSegment(at: when)               // close the dwell (time-on-site)
        control.removeGeofence(id: Self.dwellGeofenceId)
        control.setContinuous(SamplingPolicy.decide(regime: regime, speed: nil))
        resetSegmentAccumulation()
        await openSegment(type: "transit", at: when, placeId: nil)
        persist(state)
    }

    private func endOuting(at when: Date) async {
        guard state.phase != .atHome else { return }
        // Flip phase SYNCHRONOUSLY so a repeated end trigger (e.g. reconcile
        // firing on every requestState) is idempotent.
        let cid = state.clientOutingId
        let wasSession = state.phase == .session
        state.phase = .atHome
        persist(state)

        await closeSegment(at: when)
        control.stopContinuous()
        control.removeGeofence(id: Self.dwellGeofenceId)
        if let cid {
            await backend.endOuting(clientOutingId: cid, at: when)
            onOutingCompleted?(cid, when)
        }
        if !wasSession, state.maxDistanceMeters > state.lastPersonalRecord {
            state.lastPersonalRecord = state.maxDistanceMeters
            await backend.setFarthest(meters: state.maxDistanceMeters)
        }
        state.phase = .atHome
        state.clientOutingId = nil
        state.openOutingId = nil
        state.outingMode = nil
        state.outingStartedAt = nil
        state.maxDistanceMeters = 0
        state.currentClientSegmentId = nil
        state.currentSegmentType = nil
        state.dwellAnchorLat = nil
        state.dwellAnchorLng = nil
        state.dwellSince = nil
        resetSegmentAccumulation()
        persist(state)
    }

    // ─── Boot reconciliation ─────────────────────────────────────────
    // Correct the persisted phase against reality. Driven by didDetermineState
    // for the home region (which ignores .unknown). Idempotent across repeated
    // requestState callbacks — each branch is a no-op once already reconciled.
    private func reconcile(homeInside: Bool) async {
        // A porch session deliberately starts inside home and survives a
        // relaunch there. Only Done or a real home-entry event closes it.
        if state.phase == .session { return }
        if homeInside {
            // Home now. If we still think we're out, the outing ended while the
            // app was off (battery died, killed) — close it.
            if state.phase != .atHome { await endOuting(at: now()) }
        } else {
            // Away now. If we still think we're home, we left while the app was
            // off and never saw the geofence exit — start an outing. The true
            // departure time is unknown; source flags it as reconstructed.
            if state.phase == .atHome, home() != nil {
                let walking = (regime == .walking)
                state.phase = walking ? .onSite : .transit
                persist(state)
                await startOuting(walking: walking, at: now(), source: "boot-reconcile")
            }
            // else transit/onSite: bootstrap() already re-armed the radio.
        }
    }

    // ─── Segment helpers ─────────────────────────────────────────────
    private func openSegment(type: String, at when: Date, placeId: String?) async {
        guard let cOuting = state.clientOutingId else { return }
        // Generate the segment's durable id SYNCHRONOUSLY before the await.
        let sid = UUID().uuidString
        state.currentClientSegmentId = sid
        state.currentSegmentType = type
        await backend.startSegment(
            clientSegmentId: sid, clientOutingId: cOuting,
            type: type, at: when, placeId: placeId
        )
    }

    private func closeSegment(at when: Date) async {
        guard let sid = state.currentClientSegmentId else { return }
        state.currentClientSegmentId = nil
        state.currentSegmentType = nil
        await backend.endSegment(
            clientSegmentId: sid, at: when,
            distanceMeters: state.segmentDistanceMeters,
            maxSpeed: state.segmentMaxSpeed,
            placeId: nil
        )
    }

    private func resetSegmentAccumulation() {
        state.segmentDistanceMeters = 0
        state.segmentMaxSpeed = 0
        state.lastSampleLat = nil
        state.lastSampleLng = nil
        state.lastSampleAt = nil
    }

    #if DEBUG
    // Test hook: set the current motion synchronously without a CoreMotion
    // manager and without triggering a transition (use handleMotion for that).
    public func _setRegimeForTest(_ r: MotionCoordinator.MotionState, _ c: CMMotionActivityConfidence) {
        self.regime = r
        self.regimeConfidence = c
    }
    #endif

    // ─── Helpers ─────────────────────────────────────────────────────
    public static func distance(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lng1)
            .distance(from: CLLocation(latitude: lat2, longitude: lng2))
    }
}

extension MotionCoordinator.MotionState {
    public var isVehicle: Bool { self == .automotive || self == .cycling }
}
