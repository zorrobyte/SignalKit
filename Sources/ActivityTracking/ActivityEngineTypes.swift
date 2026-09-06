import CoreLocation
import Foundation

// Pure types for the Activity Engine. No CoreLocation/CoreMotion *manager*
// dependencies here — only value types — so the engine and these are unit
// testable. See Documentation/ActivityTracking.md.

// ─── Sampling ────────────────────────────────────────────────────────
// What the engine wants the GPS configured to while it's on.
public struct SamplingDecision: Equatable {
    public let accuracy: CLLocationAccuracy
    public let distanceFilter: CLLocationDistance
    public let activityType: CLActivityType
    public init(accuracy: CLLocationAccuracy, distanceFilter: CLLocationDistance, activityType: CLActivityType) {
        self.accuracy = accuracy; self.distanceFilter = distanceFilter; self.activityType = activityType
    }
}

// Decides GPS params from motion regime + instantaneous speed. GPS only runs
// during transit, so this only really tunes the driving band; finest when
// slow, coarsest at highway speed (a fix roughly every 3s).
public enum SamplingPolicy {
    public static func decide(regime: MotionCoordinator.MotionState,
                       speed: CLLocationSpeed?) -> SamplingDecision {
        switch regime {
        case .cycling:
            return SamplingDecision(
                accuracy: kCLLocationAccuracyNearestTenMeters,
                distanceFilter: 15,
                activityType: .fitness
            )
        case .automotive:
            // Target ~a fix every 4-7s while driving (real data showed the old
            // ×3/floor-20 produced ~every 2s — finer than a path needs and ~3×
            // the sample volume). Floor at 50m (== dwell anchor radius) so a
            // stop still lands a fix near the anchor.
            let s = speed ?? -1
            let filter: CLLocationDistance = s > 0 ? min(120, max(50, s * 5)) : 60
            let acc = s > 25 ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters
            return SamplingDecision(
                accuracy: acc,
                distanceFilter: filter,
                activityType: .automotiveNavigation
            )
        default:
            // walking/running/stationary/unknown — only reached if continuous
            // is ever used off-vehicle; kept sensible regardless.
            return SamplingDecision(
                accuracy: kCLLocationAccuracyNearestTenMeters,
                distanceFilter: 10,
                activityType: .fitness
            )
        }
    }
}

// ─── The control seam ────────────────────────────────────────────────
// The engine commands the radio through this. LocationCoordinator implements
// it for real; tests use a fake that records the call sequence.
@MainActor
public protocol LocationControlling: AnyObject {
    /// Start or update continuous GPS with the given sampling params.
    func setContinuous(_ decision: SamplingDecision)
    /// Stop continuous GPS entirely.
    func stopContinuous()
    /// Arm (or replace) a monitored region by identifier.
    func armGeofence(id: String, center: CLLocationCoordinate2D, radius: CLLocationDistance)
    /// Remove a monitored region by identifier.
    func removeGeofence(id: String)
    /// Ask iOS for the current inside/outside state of a monitored region
    /// (drives a didDetermineState callback). Used on cold boot to catch a
    /// region crossing that happened while the app was dead.
    func requestState(id: String)
}

// ─── The persistence/event seam ──────────────────────────────────────
// Structured-event writes (outings/segments/places/PR). The real impl wraps
// the host's durable sink; tests record calls and return synthetic ids.
// All outing/segment ops are addressed by device-generated client IDs so they
// work offline (no server _id needed) and are idempotent on replay. startOuting
// returns the server _id when online (advisory, used only for tagging raw
// samples until that path moves to clientOutingId too); the FSM never depends
// on it.
@MainActor
public protocol ActivityBackend: AnyObject {
    func startSession(clientOutingId: String, at: Date) async -> String?
    func startOuting(clientOutingId: String, mode: String, source: String, at: Date, homeLat: Double?, homeLng: Double?) async -> String?
    func endOuting(clientOutingId: String, at: Date) async
    func setOutingMode(clientOutingId: String, mode: String) async
    func markFarRecord(clientOutingId: String) async
    func bumpMaxDistance(clientOutingId: String, meters: Double) async
    func startSegment(clientSegmentId: String, clientOutingId: String, type: String, at: Date, placeId: String?) async
    func endSegment(clientSegmentId: String, at: Date, distanceMeters: Double, maxSpeed: Double, placeId: String?) async
    func upsertPlace(lat: Double, lng: Double, at: Date, clientSegmentId: String) async -> String?
    func setFarthest(meters: Double) async
}

// ─── Durable FSM state ───────────────────────────────────────────────
// Persisted to the App Group so cold SLC/geofence wakes resume correctly —
// and so a double exit can't create a second outing (openOutingId is set
// before any await and reconciled on wake).
public struct EngineState: Codable, Equatable {
    public init() {}
    public enum Phase: String, Codable { case atHome, transit, onSite, session }

    public var phase: Phase = .atHome
    // Durable device-generated identity — the FSM's source of truth, set
    // synchronously and never dependent on a network round-trip.
    public var clientOutingId: String?
    // Server _id when online (advisory; used only to tag raw samples). Nil offline.
    public var openOutingId: String?
    public var outingMode: String?          // 'drive' | 'walk' | 'mixed'
    // True outing start, persisted so a cold wake mid-outing shows correct
    // elapsed time (not "since the app noticed it was away").
    public var outingStartedAt: Date?

    public var currentClientSegmentId: String?
    public var currentSegmentType: String?  // 'transit' | 'dwell' | 'onfoot'

    // Dwell tracking (anchor + when we first parked there).
    public var dwellAnchorLat: Double?
    public var dwellAnchorLng: Double?
    public var dwellSince: Date?

    // Per-segment accumulation.
    public var lastSampleLat: Double?
    public var lastSampleLng: Double?
    public var lastSampleAt: Date?
    public var segmentDistanceMeters: Double = 0
    public var segmentMaxSpeed: Double = 0

    // Outing + PR.
    public var maxDistanceMeters: Double = 0
    public var lastPersonalRecord: Double = 0
    public var farRecordFlagged: Bool = false
}

// App Group persistence for EngineState.
public struct EngineStateStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    private let key = "activityEngine.state.v2"

    public func load() -> EngineState {
        guard let data = defaults.data(forKey: key),
              var s = try? JSONDecoder().decode(EngineState.self, from: data)
        else { return EngineState() }
        if s.phase != .atHome && s.clientOutingId == nil {
            // Repair phantom outings produced by older no-home manual starts.
            let record = s.lastPersonalRecord
            s = EngineState()
            s.lastPersonalRecord = record
        }
        return s
    }

    public func save(_ s: EngineState) {
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: key)
        }
    }
}
