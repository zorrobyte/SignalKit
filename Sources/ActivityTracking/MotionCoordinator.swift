import CoreMotion
import Foundation
import Observation
import DurableSync

// Wraps CMMotionActivityManager — the device's always-on motion coprocessor
// classification of what the user is doing (stationary / walking / running /
// cycling / automotive). It is extremely low power (runs on the M-series
// motion chip, not the main CPU), which makes it the ideal *gate* for the
// expensive GPS: we can let location updates rest while the user is stationary
// and wake them the moment motion resumes.
//
// Responsibilities:
//   - Request + track CoreMotion authorization.
//   - Stream live activity classifications, exposed as observable state for
//     the Today diagnostics readout and the Live Activity contextLabel.
//   - Notify a subscriber (LocationCoordinator) on meaningful changes so it
//     can adapt GPS sampling.
//
// Requires NSMotionUsageDescription in Info.plist or startActivityUpdates
// traps. Lives as a process-lifetime singleton like the other coordinators.
@MainActor
@Observable
public final class MotionCoordinator: NSObject {

    public enum MotionState: String, Sendable {
        case stationary
        case walking
        case running
        case cycling
        case automotive
        case unknown

        // Human-facing label for the diagnostics readout.
        public var label: String {
            switch self {
            case .stationary: return "Stationary"
            case .walking: return "Walking"
            case .running: return "Running"
            case .cycling: return "Cycling"
            case .automotive: return "Driving"
            case .unknown: return "Unknown"
            }
        }

        public var symbolName: String {
            switch self {
            case .stationary: return "figure.stand"
            case .walking: return "figure.walk"
            case .running: return "figure.run"
            case .cycling: return "bicycle"
            case .automotive: return "car.fill"
            case .unknown: return "questionmark.circle"
            }
        }

        public var isMoving: Bool {
            switch self {
            case .walking, .running, .cycling, .automotive: return true
            case .stationary, .unknown: return false
            }
        }
    }

    private let driver: any MotionActivityDriving
    private let log: DiagnosticLog

    // ─── Observable state ────────────────────────────────────────────
    public private(set) var available: Bool
    public private(set) var authStatus: CMAuthorizationStatus
    public private(set) var state: MotionState = .unknown
    public private(set) var confidence: CMMotionActivityConfidence = .low
    public private(set) var updatedAt: Date?
    public private(set) var isActive = false

    /// The complete most recent observation, including overlapping flags, explicit unknown,
    /// and low-confidence updates. Nil until the first observation arrives.
    public private(set) var latestObservation: MotionObservation?

    /// Last known medium/high-confidence classification. Unlike `state`, this does not
    /// fluctuate with low-confidence/unknown observations. This is a retained classification, not a guarantee of current activity.
    public private(set) var confirmedState: MotionState?

    /// Every observation, after observable state is updated. Independent of the engine's
    /// filtered `onChange` callback; hosts may subscribe without replacing engine wiring.
    /// Repeated, unknown, and low-confidence observations are intentionally included.
    public var onObservation: ((MotionObservation) -> Void)?

    // LocationCoordinator subscribes here to adapt GPS sampling. Fired only on
    // a meaningful change (state or confidence), on the main actor.
    public var onChange: ((MotionState, CMMotionActivityConfidence) -> Void)?

    public init(log: DiagnosticLog = DiagnosticLog(), driver: (any MotionActivityDriving)? = nil) {
        let driver = driver ?? CoreMotionDriver()
        self.driver = driver
        self.log = log
        self.available = driver.available
        self.authStatus = driver.authorizationStatus
        super.init()
    }

    // ─── Lifecycle ───────────────────────────────────────────────────
    // Start streaming classifications. The first call triggers the CoreMotion
    // permission prompt. Safe to call repeatedly.
    public func start() {
        guard available else {
            log.record("motion", "activity classification unavailable on this device")
            return
        }
        guard !isActive else { return }
        isActive = true
        // OperationQueue.main guarantees the handler runs on the main thread,
        // so assumeIsolated is sound and avoids hopping a non-Sendable
        // CMMotionActivity across an actor boundary.
        driver.start { [weak self] activity in self?.ingest(activity) }
        log.record("motion", "updates started auth=\(authStatusName)")
    }

    public func stop() {
        guard isActive else { return }
        driver.stop()
        isActive = false
        log.record("motion", "updates stopped")
    }

    // ─── Ingest ──────────────────────────────────────────────────────
    private func ingest(_ a: MotionObservation) {
        // Receiving any update confirms we're authorized.
        self.authStatus = driver.authorizationStatus
        self.latestObservation = a
        defer { onObservation?(a) }

        let newState: MotionState = {
            // Order matters: CoreMotion can flag multiple bits at once during
            // transitions. Prefer the most specific moving state, fall back to
            // stationary, then unknown.
            if a.walking { return .walking }
            if a.running { return .running }
            if a.cycling { return .cycling }
            if a.automotive { return .automotive }
            if a.stationary { return .stationary }
            return .unknown
        }()

        // Keep observable state live for the diagnostics readout — confidence
        // is shown alongside, so a brief low-confidence blip is self-explained.
        self.state = newState
        self.confidence = a.confidence
        self.updatedAt = a.startDate

        // Dampen noise: only log/persist + notify on a *confident* change to a
        // new, known state. Drops low-confidence jitter, no-op repeats, and the
        // stationary/unknown flapping a parked phone otherwise emits redundant writes.
        guard a.confidence != .low,
              newState != .unknown,
              newState != confirmedState else { return }
        confirmedState = newState
        log.record("motion.state", "\(newState.rawValue) conf=\(confidenceName)")
        onChange?(newState, a.confidence)
    }

    // ─── Display helpers ─────────────────────────────────────────────
    // Live Activity contextLabel value — only surfaces while actually moving;
    // stationary/unknown return nil so the dwell label (or nothing) wins.
    public var liveActivityLabel: String? {
        state.isMoving ? state.label : nil
    }

    public var confidenceName: String {
        switch confidence {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        @unknown default: return "?"
        }
    }

    public var authStatusName: String {
        switch authStatus {
        case .notDetermined: return "not asked"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
