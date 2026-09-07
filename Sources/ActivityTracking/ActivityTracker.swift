import Foundation
import DurableSync

/// The whole tracking stack behind one object: motion classification, location
/// collection, the outing state machine, a durable outbox, and replay.
///
/// This is the `ActivityTracking` counterpart of `HealthSyncCoordinator`. The
/// host supplies persistent storage and an idempotent uploader; everything below
/// that line is owned here. Retain it for the process lifetime — it is not a
/// short-lived view model — and construct one per tracking identity.
///
/// ```swift
/// tracker = ActivityTracker(storageDirectory: directory, defaults: .standard) { events in
///     try await api.send(events)          // return only after acknowledgement
/// }
/// tracker.onOutingCompleted = { id, at in DailyProgress.record(id: id, at: at) }
/// tracker.bootstrap()
/// ```
///
/// Assign presentation callbacks on **this** object, not on `location`: the
/// tracker installs its own handlers there to drive uploads, and overwriting
/// them stops the outbox from draining. Commands and observable state that are
/// not forwarded here remain available on `location` and `motion`.
///
/// Host setup this type cannot perform: Info.plist purpose strings, the location
/// background mode, and permission timing. See `Documentation/ActivityTracking.md`.
@MainActor
@Observable
public final class ActivityTracker {
    /// The location coordinator. Read its observable state and call commands on
    /// it freely; do not assign its callbacks.
    public let location: LocationCoordinator
    public let motion: MotionCoordinator
    /// The durable outbox. Inspect `pendingCount` and `storageError`.
    public let output: DurableTrackingOutput

    // ─── Host callbacks ──────────────────────────────────────────────
    // Same names and signatures as LocationCoordinator's, forwarded after the
    // tracker has taken its own action. All optional, all on the main actor.

    /// A snapshot-worthy change: refresh a widget or lock-screen surface.
    public var onSnapshot: (() -> Void)?
    /// Current distance from the anchor, in meters.
    public var onDistanceChanged: ((Double) -> Void)?
    /// Motion or dwell presentation context changed.
    public var onContextChanged: (() -> Void)?
    /// Engine phase changed.
    public var onStateChanged: (() -> Void)?
    /// The active outing ended.
    public var onOutingEnded: (() -> Void)?
    /// An outing completed, with its stable client ID and completion date.
    public var onOutingCompleted: ((String, Date) -> Void)?
    /// A lightweight background wake; do bounded work only.
    public var onWake: (() -> Void)?

    /// Forwarded to the outbox: work remains, so schedule a background task.
    public var requestBackgroundWork: (() -> Void)? {
        get { output.requestBackgroundWork }
        set { output.requestBackgroundWork = newValue }
    }

    // ─── Upload state ────────────────────────────────────────────────

    public var pendingUploads: Int { output.pendingCount }
    public var lastUploadedAt: Date? { output.lastUploadedAt }
    public var uploading: Bool { output.uploading }
    /// The last upload failure, if the most recent pass did not fully drain.
    public var lastUploadError: String? { output.lastError }
    /// A durable-storage failure. Check independently of `lastUploadError`.
    public var storageError: String? { output.storageError }

    /// - Parameters:
    ///   - storageDirectory: A persistent directory, isolated per account. Use
    ///     Application Support or an App Group, never a temporary directory.
    ///   - defaults: Ordinary app preferences (home, accuracy switch).
    ///   - stateDefaults: Engine state store; pass an App Group suite when
    ///     extensions share the identity. Defaults to `defaults`.
    ///   - mode: `.homeAnchored` (default) or `.roaming(restThreshold:)`.
    ///   - uploadBatch: Sends one batch; return only after acknowledgement and
    ///     throw otherwise. Must be idempotent — delivery is at least once.
    public init(storageDirectory: URL,
                defaults: UserDefaults,
                stateDefaults: UserDefaults? = nil,
                mode: TrackingMode = .homeAnchored,
                configuration: DurableTrackingOutput.Configuration = .init(),
                fileName: String = "tracking-events-v1.jsonl",
                log: DiagnosticLog = DiagnosticLog(),
                precisePurposeKey: String = "preciseForOuting",
                locationDriver: (any LocationDriving)? = nil,
                motionDriver: (any MotionActivityDriving)? = nil,
                uploadBatch: @escaping @Sendable ([TrackingEvent]) async throws -> Void) {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        output = DurableTrackingOutput(storageURL: storageDirectory.appendingPathComponent(fileName),
                                       configuration: configuration, log: log, uploadBatch: uploadBatch)
        motion = MotionCoordinator(log: log, driver: motionDriver)
        location = LocationCoordinator(output: output, defaults: defaults,
                                       stateDefaults: stateDefaults ?? defaults,
                                       motion: motion, log: log,
                                       precisePurposeKey: precisePurposeKey, driver: locationDriver,
                                       mode: mode)
        installCallbacks()
    }

    private func installCallbacks() {
        // Each handler forwards to the host, and the ones that mark real
        // progress also drive the outbox. A host that assigned these directly
        // would have to remember to do the same at every site.
        location.onSnapshot = { [weak self] in
            self?.onSnapshot?()
            self?.flushOpportunistically()
        }
        location.onOutingCompleted = { [weak self] id, at in
            self?.onOutingCompleted?(id, at)
            self?.uploadNow()
        }
        location.onOutingEnded = { [weak self] in
            self?.onOutingEnded?()
            self?.uploadNow()
        }
        location.onWake = { [weak self] in
            self?.onWake?()
            self?.flushOpportunistically()
        }
        location.onDistanceChanged = { [weak self] meters in self?.onDistanceChanged?(meters) }
        location.onContextChanged = { [weak self] in self?.onContextChanged?() }
        location.onStateChanged = { [weak self] in self?.onStateChanged?() }
    }

    // ─── Lifecycle ───────────────────────────────────────────────────

    /// Call at app launch. Starts motion observation, restores home monitoring
    /// and engine state, and drains anything left from a previous run.
    public func bootstrap() {
        motion.start()
        location.bootstrap()
        uploadNow()
    }

    /// Call on foreground entry. Re-evaluates tracking state (which recognizes a
    /// rest that completed while suspended, in roaming mode) and uploads.
    public func onForeground() {
        Task { @MainActor in
            await location.refreshTrackingState()
            await drainUploads()
        }
    }

    /// Await the active upload pass. Use on network recovery and in a
    /// BGProcessing handler; end the background task exactly once afterwards.
    public func drainUploads() async { await output.drain() }

    /// Stop observation and retries. Durable events are preserved for replay.
    /// This is not an account-deletion API and does not undo a sent upload.
    public func stop() {
        motion.stop()
        output.stop()
    }

    private func uploadNow() { Task { @MainActor [weak self] in await self?.output.drain() } }
    private func flushOpportunistically() { Task { @MainActor [weak self] in await self?.output.flush() } }

    // ─── Forwarded commands ──────────────────────────────────────────

    /// Request When In Use, then escalate an existing grant to Always.
    public func requestAuthorization() { location.requestAuthorization() }
    /// Request temporary full accuracy, only when reduced accuracy is active.
    public func requestPreciseAccuracy() { location.requestPreciseAccuracy() }
    public func setHomeToCurrentLocation() async { await location.setHomeToCurrentLocation() }
    public func setHome(_ home: LocationCoordinator.HomeLocation) { location.setHome(home) }
    public func setTrackingMode(_ mode: TrackingMode) async { await location.setTrackingMode(mode) }
    public func startManualSession() async { await location.startManualSession() }
    public func endCurrentOutingManually(note: String? = nil) async {
        await location.endCurrentOutingManually(note: note)
    }
    public var trackingMode: TrackingMode { location.trackingMode }
}
