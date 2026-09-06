import CoreLocation
import CoreMotion
import DurableSync
import Foundation
import Observation


// CoreLocation orchestration with injected persistence and presentation hooks.
//
// Responsibilities:
//   - Request Always + Precise authorization.
//   - Start SLC (Significant Location Changes) — wakes the app from
//     terminated state on ~500m moves, like a weather app.
//   - Start visit monitoring — fires arrival/departure for dwells.
//   - Maintain a single home-geofence region — entry/exit drive outing
//     auto-start and auto-end.
//   - Send retained observations to the host's durable output.
//   - Notify the host when outing state or presentation inputs change.
//
// Lifecycle: must be instantiated from the App's init() so SLC wake-ups
// from terminated state find a registered delegate. App keeps a strong
// reference; this class never deallocates during process lifetime.
@MainActor
@Observable
public final class LocationCoordinator: NSObject {

    private let manager: any LocationDriving
    private let output: TrackingOutput
    private let defaults: UserDefaults
    private let stateDefaults: UserDefaults
    public let motion: MotionCoordinator
    public let log: DiagnosticLog
    public var onSnapshot: (() -> Void)?
    public var onOutingEnded: (() -> Void)?
    public var onContextChanged: (() -> Void)?
    public var onDistanceChanged: ((Double) -> Void)?
    public var onStateChanged: (() -> Void)?
    public var onOutingCompleted: ((String, Date) -> Void)?
    public var onWake: (() -> Void)?

    // ─── Observable state for UI ─────────────────────────────────────
    public internal(set) var authStatus: CLAuthorizationStatus = .notDetermined
    public internal(set) var accuracyStatus: CLAccuracyAuthorization = .reducedAccuracy
    public internal(set) var lastSample: CLLocation?
    public internal(set) var currentOutingStartedAt: Date?
    public internal(set) var currentMaxDistanceMeters: Double = 0
    public internal(set) var home: HomeLocation?
    public internal(set) var lastError: String?
    public internal(set) var currentOutingIsSession = false
    private var didBootstrap = false
    // Sustained high-accuracy GPS. Default off: iOS is allowed to pause the
    // continuous stream (pausesLocationUpdatesAutomatically = true), which
    // throttles fixes to brief windows — low power, coarse route, dwells still
    // detected. On: keep the stream alive (pause off) for a dense continuous
    // track. Only flips the pause flag; continuous GPS is armed in transit
    // either way, so dwell detection is unaffected.
    public var highAccuracyGPS: Bool {
        didSet { highAccuracyGPSDidChange() }
    }
    public internal(set) var continuousActive: Bool = false

    // ─── Background continuous GPS (iOS 16.4+ suspension avoidance) ───
    // We do NOT use CLLocationManager.distanceFilter to thin fixes — a numeric
    // distanceFilter is one of the conditions that makes iOS suspend background
    // location. Instead we let Core Location deliver freely (distanceFilter =
    // None) and thin in SOFTWARE here: keep a continuous fix only once it has
    // moved `thinMeters` OR `thinMinInterval` has elapsed (the time floor keeps
    // dwell detection fed while stopped). highAccuracyGPS on → thinMeters 0 =
    // keep every fix (dense track).
    private static let thinMinInterval: TimeInterval = 8
    private var thinMeters: CLLocationDistance = 0
    private var coarseThin: CLLocationDistance = 60   // the engine's requested cadence
    private var lastKeptContinuous: CLLocation?
    // Retained for the duration of a transit leg so iOS keeps the app alive in
    // the background for continuous updates (Apple's sanctioned keep-alive,
    // iOS 17+). Deallocating it ends the session, so it must be a held property.
    private var endBackgroundActivity: (() -> Void)?

    // Activity Engine: the sole outing pipeline. See Documentation/ActivityTracking.md.
    // Mirror of the engine's phase for host UI (the engine itself is not
    // @Observable, so we copy its phase here after each signal).
    public internal(set) var enginePhase: EngineState.Phase = .atHome
    @ObservationIgnored private lazy var engine: ActivityEngine = ActivityEngine.live(
        control: self,
        backend: output,   // structured writes go through the offline write-ahead log
        home: { [weak self] in
            guard let h = self?.home else { return nil }
            return (lat: h.lat, lng: h.lng, radius: h.radius)
        },
        stateStore: EngineStateStore(defaults: stateDefaults),
        mode: initialTrackingMode
    )
    private let initialTrackingMode: TrackingMode
    /// Home-anchored (default) or roaming. Change at runtime with `setTrackingMode(_:)`.
    public var trackingMode: TrackingMode { engine.mode }
    /// The coordinate outings are measured from: home, or the roaming base.
    public var anchorCoordinate: CLLocationCoordinate2D? {
        engine.anchor.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }
    // Roaming: best-effort timer that posts `.tick` when the current stop
    // reaches the rest threshold while the app is alive. The engine also
    // re-checks on every event, so a suspended timer only delays the boundary.
    @ObservationIgnored private var restTimer: Task<Void, Never>?

    // Dwell state — surfaced to the host's presentation so it can show at a
    // glance whether iOS thinks the user is stopped somewhere.
    public internal(set) var isDwelling: Bool = false
    public internal(set) var dwellingSince: Date?
    public internal(set) var dwellingPlaceLabel: String?
    public internal(set) var dwellingCoord: CLLocationCoordinate2D?
    // Throttle onSnapshot in continuous mode. 5s feels live enough for a
    // lock-screen surface without excessive churn.
    private var lastSnapshotPublishAt: Date = .distantPast
    // Tracks whether the host has been told an outing is being presented, so
    // mirrorEngineState signals its start/end exactly once per outing boundary.
    private var outingPresented = false

    public struct HomeLocation: Equatable, Sendable {
        public init(lat: Double, lng: Double, accuracy: Double, radius: Double, setAt: Date) {
            self.lat = lat; self.lng = lng; self.accuracy = accuracy; self.radius = radius; self.setAt = setAt
        }
        public var lat: Double
        public var lng: Double
        public var accuracy: Double
        public var radius: Double
        public var setAt: Date
    }

    // Persisted across launches so SLC wake-ups know where home is.
    private let precisePurposeKey: String
    private let homeKey = "location.home.v1"
    private let highAccuracyGPSKey = "location.highAccuracyGPS.v1"

    // ─── Sampling tuning ─────────────────────────────────────────────
    // Live GPS fixes worse than this are noise (a cell-tower fix can report
    // accuracy in the thousands of meters) and would otherwise record a bogus
    // personal-distance record and pollute the trail. Visit events bypass it.
    private static let maxAcceptableAccuracyMeters: CLLocationDistance = 100
    // Drop cached/stale fixes — common on a cold SLC wake, where the first
    // delivered location can be minutes old and far from the user now.
    private static let maxSampleAgeSeconds: TimeInterval = 60

    // The current geofence region (if any). Single region — only home.
    private var homeRegion: CLCircularRegion?

    // Pending one-shot fix request (e.g. "Set this spot as home"). At rest the
    // app only runs SLC, which can hand back a stale cached fix that the
    // freshness gate rejects — so lastSample may be nil. This lets the UI ask
    // for a fresh fix on demand. @ObservationIgnored so it doesn't churn views.
    @ObservationIgnored private var freshFixContinuation: CheckedContinuation<CLLocation?, Never>?
    private var freshFixRequestId: UUID?

    // The "set home" button should be tappable whenever we can legally get a
    // fix, not gated on a prior sample having arrived.
    public var canGetFix: Bool {
        authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse
    }


    public init(output: TrackingOutput, defaults: UserDefaults, stateDefaults: UserDefaults,
                motion: MotionCoordinator, log: DiagnosticLog = DiagnosticLog(),
                precisePurposeKey: String = "preciseForOuting", driver: (any LocationDriving)? = nil,
                mode: TrackingMode = .homeAnchored) {
        self.initialTrackingMode = mode
        self.output = output
        self.defaults = defaults
        self.stateDefaults = stateDefaults
        self.motion = motion
        self.log = log
        self.precisePurposeKey = precisePurposeKey
        self.manager = driver ?? CoreLocationDriver()
        self.highAccuracyGPS = defaults.bool(forKey: "location.highAccuracyGPS.v1")
        super.init()
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyBest
        self.manager.activityType = .other
        self.manager.pausesLocationUpdatesAutomatically = true
        self.manager.allowsBackgroundLocationUpdates = true
        // MUST be true: iOS 16.4+ suspends background continuous location when
        // the indicator is off (esp. with a distanceFilter set and SLC running,
        // and when updates are started from a background wake). That suspension
        // is what blacked out the outbound leg of a drive. See setContinuous().
        self.manager.showsBackgroundLocationIndicator = true

        self.authStatus = manager.authorizationStatus
        self.accuracyStatus = manager.accuracyAuthorization
        self.home = loadHomeFromDefaults()
    }

    // Call once from App.init() so SLC wake-ups land on a live delegate.
    public func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        log.record("location", "bootstrap auth=\(authStatusName) mode=\(trackingMode.isRoaming ? "roaming" : "home")")
        if let h = home, !trackingMode.isRoaming {
            installGeofence(h)
        }
        if authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse {
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        }
        // Motion classification gates the engine's GPS (driving ⇒ GPS on) and
        // keeps the Live Activity context label fresh. Nearly free to run always.
        // The engine mirrors its own state back via onStateChanged after it
        // processes each event (serial intake).
        engine.onStateChanged = { [weak self] _ in self?.mirrorEngineState() }
        engine.onOutingCompleted = { [weak self] id, at in self?.onOutingCompleted?(id, at) }
        motion.onChange = { [weak self] state, confidence in
            guard let self else { return }
            self.onContextChanged?()
            self.engine.post(.motion(state, confidence))
        }
        motion.start()
        engine.bootstrap()
        mirrorEngineState()
        if needsInitialFix, canGetFix { manager.requestLocation() }
        Task { await output.flush() }
        // Every delegate event will reschedule too, but call once here so
        // a fresh launch immediately re-arms the dead-man notification
        // even before iOS delivers any location events.
        onWake?()
    }

    // Home mode wants a first fix to propose a default home; roaming wants one
    // to adopt the starting rest stop as the base.
    private var needsInitialFix: Bool {
        trackingMode.isRoaming ? engine.state.baseLat == nil : home == nil
    }

    /// Switch between home-anchored and roaming tracking. Any open outing ends
    /// first. In roaming mode the home fence is released and the current
    /// position (or the next fix) becomes the base; switching back reinstalls
    /// the home fence and reconciles against it.
    public func setTrackingMode(_ mode: TrackingMode) async {
        guard mode != trackingMode else { return }
        await engine.handle(.setMode(mode))
        if mode.isRoaming {
            if let r = homeRegion { manager.stopMonitoring(for: r); homeRegion = nil }
            if let l = lastSample, isAcceptableFix(l) {
                await engine.handle(.sample(lat: l.coordinate.latitude, lng: l.coordinate.longitude,
                                            speed: nil, at: l.timestamp))
            } else if canGetFix {
                manager.requestLocation()
            }
        } else if let h = home {
            installGeofence(h)
        }
        log.record("mode", mode.isRoaming ? "roaming" : "home")
        mirrorEngineState()
        await output.flush()
    }

    /// Re-evaluate time-based state with no new sensor data: in roaming mode a
    /// stop that has reached the rest threshold ends the outing. Call from a
    /// background refresh task or on foreground entry. Cheap in every mode.
    public func refreshTrackingState() async {
        await engine.handle(.tick(at: Date()))
        await output.flush()
    }

    // Copy the engine's current phase/dwell into the observable mirror that the
    // Today diagnostics card renders. Called after each forwarded signal.
    private func mirrorEngineState() {
        scheduleRestTimer()
        enginePhase = engine.state.phase
        isDwelling = engine.state.phase == .onSite
        dwellingSince = engine.state.dwellSince
        if engine.state.phase != .onSite { dwellingPlaceLabel = nil }
        // In engine mode the FSM owns max distance; surface it so the Live
        // Activity / widget show the real value (the legacy currentMaxDistance
        // accumulator is never updated on this path).
        currentMaxDistanceMeters = engine.state.maxDistanceMeters
        currentOutingIsSession = engine.state.phase == .session

        // Drive the Live Activity off the engine's outing boundary (the engine
        // owns outings, so the legacy startOuting/endOuting hooks never fire).
        // Also sets currentOutingStartedAt, which the Today card + the existing
        // updateLiveActivity() both key off.
        let away = engine.state.clientOutingId != nil && engine.state.outingStartedAt != nil
        if away, !outingPresented {
            outingPresented = true
            // Use the FSM's persisted start so elapsed is correct even after a
            // cold wake mid-outing (falls back to now for a brand-new outing).
            currentOutingStartedAt = engine.state.outingStartedAt
            onSnapshot?()
        } else if !away, outingPresented {
            outingPresented = false
            currentOutingStartedAt = nil
            onOutingEnded?()
            onSnapshot?()
        }
        onStateChanged?()
    }

    private func scheduleRestTimer() {
        restTimer?.cancel()
        restTimer = nil
        guard let threshold = trackingMode.restThreshold, engine.state.phase == .onSite,
              let since = engine.state.dwellSince else { return }
        let delay = max(0, threshold - Date().timeIntervalSince(since))
        restTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.engine.handle(.tick(at: Date()))
            await self.output.flush()
        }
    }

    private func highAccuracyGPSDidChange() {
        defaults.set(highAccuracyGPS, forKey: highAccuracyGPSKey)
        log.record("highAccuracyGPS", "set=\(highAccuracyGPS)")
        // Apply immediately if a stream is live, so toggling mid-outing sticks.
        // On = keep every fix (dense); off = thin to the engine's cadence.
        if continuousActive {
            thinMeters = highAccuracyGPS ? 0 : coarseThin
        }
    }

    // ─── Authorization ───────────────────────────────────────────────
    public func requestAuthorization() {
        if authStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if authStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    public func requestPreciseAccuracy() {
        if accuracyStatus == .reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: precisePurposeKey
            )
        }
    }

    // ─── On-demand fresh fix ─────────────────────────────────────────
    // Force a current GPS fix instead of relying on whatever SLC last handed
    // us (which may be a stale cached fix the gate rejected). Resolves via the
    // didUpdateLocations delegate or a timeout.
    public func requestFreshFix(timeout: TimeInterval = 12) async -> CLLocation? {
        guard canGetFix else { return nil }
        guard freshFixContinuation == nil else { return nil }
        // A genuinely recent fix is good enough; don't spin up a new request.
        if let l = lastSample, Self.isHomeFix(l) {
            return l
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            let requestId = UUID()
            freshFixRequestId = requestId
            freshFixContinuation = cont
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if freshFixRequestId == requestId, let c = freshFixContinuation {
                    freshFixRequestId = nil
                    freshFixContinuation = nil
                    log.record("location.fix.timeout", "after \(Int(timeout))s")
                    c.resume(returning: nil)
                }
            }
        }
    }

    // ─── Home location ───────────────────────────────────────────────
    public func setHomeToCurrentLocation() async {
        lastError = nil
        guard let l = await requestFreshFix() else {
            log.record("location.setHome.error", "no fresh fix (authorized=\(canGetFix))")
            lastError = "Couldn't get a precise location. Check location access and try again outside."
            return
        }
        saveHome(l)
    }

    private static func isHomeFix(_ location: CLLocation) -> Bool {
        HomeDefaultPolicy.isFreshPrecise(location)
    }

    private func saveHome(_ l: CLLocation) {
        setHome(HomeLocation(
            lat: l.coordinate.latitude,
            lng: l.coordinate.longitude,
            accuracy: l.horizontalAccuracy,
            radius: 75,
            setAt: Date()
        ))
    }

    /// Adopt a host-supplied home (restored from a server or chosen on a map).
    /// Persists it, installs the home region, and records it through the output.
    public func setHome(_ h: HomeLocation) {
        self.home = h
        saveHomeToDefaults(h)
        installGeofence(h)
        log.record("location.setHome", "lat=\(h.lat) lng=\(h.lng) r=\(h.radius)m")
        onSnapshot?()

        output.recordHome(h)
    }

    // ─── Manual outing controls ──────────────────────────────────────
    // Routed through the engine (the sole outing pipeline) as a synthetic
    // leave/return, then drained so the write reaches the backend promptly.
    public func startManualSession() async {
        await engine.handle(.manualStart(at: Date()))
        await output.flush()
    }

    public func endCurrentOutingManually(note: String? = nil) async {
        await engine.handle(.manualEnd(at: Date()))
        await output.flush()
    }

    // ─── Sample append ───────────────────────────────────────────────
    private func appendSample(_ location: CLLocation, source: String) async {
        // Gate noisy fixes from live GPS sources before they reach lastSample,
        // the Live Activity, or the WAL. Visit events bypass the gate: they're
        // discrete arrivals/departures whose pseudo-locations carry
        // intentionally-historical timestamps and looser accuracy.
        if Self.isLiveFixSource(source), !isAcceptableFix(location) {
            log.record("sample.reject",
                       "src=\(source) acc=\(Int(location.horizontalAccuracy))m age=\(Int(-location.timestamp.timeIntervalSinceNow))s")
            return
        }
        // Software-thin the continuous stream (we run distanceFilter=None to
        // avoid iOS background suspension). Drop a fix only if it's both within
        // thinMeters of the last kept fix AND within the time floor — the time
        // floor keeps the dwell detector fed while stopped.
        if source == "continuous", thinMeters > 0, let last = lastKeptContinuous,
           location.distance(from: last) < thinMeters,
           location.timestamp.timeIntervalSince(last.timestamp) < Self.thinMinInterval {
            return
        }
        if source == "continuous" { lastKeptContinuous = location }
        self.lastSample = location
        if Self.isLiveFixSource(source), !trackingMode.isRoaming,
           HomeDefaultPolicy.shouldSetHome(existingHome: home != nil,
                                           preciseAuthorization: accuracyStatus == .fullAccuracy, fix: location) {
            saveHome(location)
        }

        // The ActivityEngine owns max-distance + outing logic. Forward live
        // fixes to it (await so the WAL enqueue below sees the up-to-date
        // clientOutingId); visit pseudo-fixes are a secondary signal and don't
        // drive the FSM. State is mirrored back via onStateChanged.
        if Self.isLiveFixSource(source) {
            let spd: Double? = location.speed >= 0 ? location.speed : nil
            await engine.handle(.sample(
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speed: spd, at: location.timestamp
            ))
        }
        if let a = engine.anchor {
            let d = distance(a.lat, a.lng, location.coordinate.latitude, location.coordinate.longitude)
            onDistanceChanged?(d)
            let minGap: TimeInterval = continuousActive ? 5 : 0
            if Date().timeIntervalSince(lastSnapshotPublishAt) >= minGap {
                onSnapshot?()
                lastSnapshotPublishAt = Date()
            }
        }

        // Durable write-ahead log: survives offline; associates to the outing by
        // clientOutingId; userId resolved at drain, so even a first-ever-launch-
        // offline sample is kept.
        let altitude: Double? = location.verticalAccuracy >= 0 ? location.altitude : nil
        let speed: Double? = location.speed >= 0 ? location.speed : nil
        output.recordSample(LocationSample(
            clientOutingId: source.hasPrefix("visit-") || currentOutingIsSession ? nil : engine.state.clientOutingId,
            timestamp: location.timestamp.timeIntervalSince1970 * 1000,
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            source: source,
            altitude: altitude,
            speed: speed
        ))
    }

    // ─── Geofence helpers ────────────────────────────────────────────
    private func installGeofence(_ h: HomeLocation) {
        // Only re-install the home region; leave the engine's "dwell" region
        // (if any) intact.
        for r in manager.monitoredRegions where r.identifier == "home" {
            manager.stopMonitoring(for: r)
        }
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: h.lat, longitude: h.lng),
            radius: h.radius,
            identifier: "home"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        homeRegion = region
        manager.requestState(for: region)
        log.record("geofence.install", "r=\(h.radius)m")
    }

    private func saveHomeToDefaults(_ h: HomeLocation) {
        let dict: [String: Any] = [
            "lat": h.lat, "lng": h.lng, "accuracy": h.accuracy,
            "radius": h.radius, "setAt": h.setAt.timeIntervalSince1970,
        ]
        defaults.set(dict, forKey: homeKey)
        stateDefaults.set(dict, forKey: homeKey)
    }

    private func loadHomeFromDefaults() -> HomeLocation? {
        guard let dict = defaults.dictionary(forKey: homeKey),
              let lat = dict["lat"] as? Double,
              let lng = dict["lng"] as? Double,
              let acc = dict["accuracy"] as? Double,
              let radius = dict["radius"] as? Double,
              let setAt = dict["setAt"] as? TimeInterval else { return nil }
        return HomeLocation(
            lat: lat, lng: lng, accuracy: acc, radius: radius,
            setAt: Date(timeIntervalSince1970: setAt)
        )
    }

    // ─── Helpers ─────────────────────────────────────────────────────
    public func distance(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let p1 = CLLocation(latitude: lat1, longitude: lng1)
        let p2 = CLLocation(latitude: lat2, longitude: lng2)
        return p1.distance(from: p2)
    }

    // Live GPS fixes ("slc"/"continuous") are gated for noise; discrete visit
    // events are not — their pseudo-locations are intentionally old and loose.
    private static func isLiveFixSource(_ source: String) -> Bool {
        source == "continuous" || source == "slc"
    }

    private func isAcceptableFix(_ location: CLLocation) -> Bool {
        let acc = location.horizontalAccuracy
        guard acc >= 0, acc <= Self.maxAcceptableAccuracyMeters else { return false }
        let age = -location.timestamp.timeIntervalSinceNow
        return age >= -5 && age <= Self.maxSampleAgeSeconds
    }

    private var authStatusName: String {
        switch authStatus {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationCoordinator: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let manager = self.manager
            self.authStatus = manager.authorizationStatus
            self.accuracyStatus = manager.accuracyAuthorization
            log.record("auth.changed", "\(authStatusName) accuracy=\(accuracyStatus == .fullAccuracy ? "full" : "reduced")")
            if authStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            if authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse {
                manager.startMonitoringSignificantLocationChanges()
                manager.startMonitoringVisits()
                if let h = home, !trackingMode.isRoaming {
                    installGeofence(h)
                }
                if needsInitialFix {
                    manager.requestLocation()
                }
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let snapshot = locations
        Task { @MainActor in
            // Every iOS event into the app counts as "alive" — push the
            // dead-man notification forward. Cheap; safe to call always.
            onWake?()
            let src = continuousActive ? "continuous" : "slc"
            for loc in snapshot {
                await appendSample(loc, source: src)
            }
            if !continuousActive {
                log.record("slc", "received \(snapshot.count) sample(s)")
            }
            // We're awake with execution time — drain the write-ahead log.
            // Resolve a pending on-demand fix request with the freshest valid
            // fix (bypasses the persist gate's strict thresholds — the user is
            // standing here asking for it; a coarse current fix beats nothing).
            if let cont = freshFixContinuation,
               let fix = snapshot.last(where: {
                   Self.isHomeFix($0)
               }) {
                freshFixContinuation = nil
                freshFixRequestId = nil
                cont.resume(returning: fix)
            }
            await output.flush()
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            log.record("location.error", error.localizedDescription)
            // Don't leave a pending fix request hanging until timeout.
            if let cont = freshFixContinuation {
                freshFixContinuation = nil
                freshFixRequestId = nil
                cont.resume(returning: nil)
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in
            onWake?()
            if id == ActivityEngine.homeGeofenceId {
                log.record("geofence", "entered home")
                await engine.handle(.homeEnter(at: Date()))
            }
            // An outing may have just ended — we're awake; flush the WAL now.
            await output.flush()
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in
            onWake?()
            if id == ActivityEngine.homeGeofenceId {
                log.record("geofence", "exited home")
                await engine.handle(.homeExit(at: Date()))
            } else if id == ActivityEngine.dwellGeofenceId {
                let c = lastSample?.coordinate
                log.record("geofence", "exited dwell")
                await engine.handle(.dwellExit(
                    lat: c?.latitude ?? engine.anchor?.lat ?? 0,
                    lng: c?.longitude ?? engine.anchor?.lng ?? 0,
                    at: Date()
                ))
            }
            await output.flush()
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        let id = region.identifier
        let rs = state
        Task { @MainActor in
            let s = rs == .inside ? "inside" : rs == .outside ? "outside" : "unknown"
            log.record("geofence.state", "\(id)=\(s)")
            // Boot reconciliation: fires on launch via requestState(for: home).
            // Ignore .unknown (common on cold boot before a fix exists).
            if id == ActivityEngine.homeGeofenceId, rs != .unknown {
                await engine.handle(.reconcile(homeInside: rs == .inside))
                await output.flush()
            }
            // Cold-boot dwell reconcile: bootstrap re-armed the dwell fence and
            // asked for its state. If we're already outside it, we left the
            // destination while the app was dead — drive the exit now. (The
            // engine no-ops unless it's still OnSite.)
            if id == ActivityEngine.dwellGeofenceId, rs == .outside {
                let c = lastSample?.coordinate
                log.record("geofence.state", "dwell outside on boot → exit")
                await engine.handle(.dwellExit(
                    lat: c?.latitude ?? engine.anchor?.lat ?? 0,
                    lng: c?.longitude ?? engine.anchor?.lng ?? 0,
                    at: Date()
                ))
                await output.flush()
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let arrival = visit.arrivalDate
        let departure = visit.departureDate
        let isArrival = departure == Date.distantFuture
        let coord = visit.coordinate
        let horiz = visit.horizontalAccuracy
        Task { @MainActor in
            onWake?()
            let pseudo = CLLocation(
                coordinate: coord,
                altitude: 0,
                horizontalAccuracy: horiz,
                verticalAccuracy: -1,
                timestamp: isArrival ? arrival : departure
            )
            await appendSample(pseudo, source: isArrival ? "visit-arrival" : "visit-departure")
            log.record("visit", "isArrival=\(isArrival) at=\(coord.latitude),\(coord.longitude)")

            if isArrival {
                self.isDwelling = true
                self.dwellingSince = pseudo.timestamp
                self.dwellingCoord = coord
                self.dwellingPlaceLabel = nil
                onContextChanged?()
                // The ActivityEngine owns dwell/place creation; CLVisit is a
                // secondary display-only signal here.
            } else {
                self.isDwelling = false
                self.dwellingSince = nil
                self.dwellingPlaceLabel = nil
                self.dwellingCoord = nil
                onContextChanged?()
            }
        }
    }
}

// MARK: - LocationControlling (the seam the ActivityEngine commands)
extension LocationCoordinator: LocationControlling {
    public func setContinuous(_ decision: SamplingDecision) {
        manager.desiredAccuracy = decision.accuracy
        manager.activityType = decision.activityType
        // Background-safe config: NO numeric distanceFilter (it triggers iOS
        // background suspension), no auto-pause (the engine owns GPS on/off and
        // cuts it at the dwell). Thinning is done in software via thinMeters.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        coarseThin = decision.distanceFilter
        thinMeters = highAccuracyGPS ? 0 : coarseThin
        lastKeptContinuous = nil
        // Keep the app alive in the background for the whole transit leg.
        if endBackgroundActivity == nil {
            endBackgroundActivity = manager.beginBackgroundActivity()
        }
        if !continuousActive {
            manager.startUpdatingLocation()
            continuousActive = true
        }
        log.record("engine.gps", "on acc=\(Int(decision.accuracy)) thin=\(Int(thinMeters))m bgSession=on")
    }

    public func stopContinuous() {
        if continuousActive {
            manager.stopUpdatingLocation()
            continuousActive = false
        }
        endBackgroundActivity?()
        endBackgroundActivity = nil
        lastKeptContinuous = nil
        manager.distanceFilter = kCLDistanceFilterNone
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = true   // resting default (SLC only)
        log.record("engine.gps", "off")
    }

    public func armGeofence(id: String, center: CLLocationCoordinate2D, radius: CLLocationDistance) {
        for r in manager.monitoredRegions where r.identifier == id {
            manager.stopMonitoring(for: r)
        }
        let region = CLCircularRegion(center: center, radius: radius, identifier: id)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        log.record("engine.geofence", "arm \(id) r=\(Int(radius))m")
    }

    public func removeGeofence(id: String) {
        for r in manager.monitoredRegions where r.identifier == id {
            manager.stopMonitoring(for: r)
        }
        log.record("engine.geofence", "remove \(id)")
    }

    public func requestState(id: String) {
        for r in manager.monitoredRegions where r.identifier == id {
            manager.requestState(for: r)
        }
    }
}
