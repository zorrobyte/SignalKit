import Foundation
import DurableSync

/// A backend-neutral tracking event. The `id` is generated on device before any
/// await, so it is stable across retries and process restarts: deduplicate on it
/// server-side and replay becomes safe. `recordedAt` is a device revision stamp
/// in Unix milliseconds, matching `HealthAggregate`; it is when the event was
/// observed, not when it was delivered, and a replay can arrive much later.
public struct TrackingEvent: Codable, Equatable, Sendable, Identifiable {
    /// The closed event vocabulary. Raw values are the wire strings.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sample
        case home
        case sessionStart = "session.start"
        case outingStart = "outing.start"
        case outingEnd = "outing.end"
        case outingMode = "outing.mode"
        case outingRecord = "outing.record"
        case outingDistance = "outing.distance"
        case segmentStart = "segment.start"
        case segmentEnd = "segment.end"
        case placeUpsert = "place.upsert"
        case farthest

        /// Raw observations may be dropped under storage pressure. Lifecycle
        /// events carry state transitions and never are.
        public var isDroppable: Bool { self == .sample }
    }

    public let id: UUID
    public let kind: Kind
    public let fields: [String: String]
    public let sample: LocationSample?
    public let recordedAt: Double

    public init(id: UUID = UUID(), kind: Kind, fields: [String: String] = [:],
                sample: LocationSample? = nil, recordedAt: Double = Date().timeIntervalSince1970 * 1000) {
        self.id = id; self.kind = kind; self.fields = fields
        self.sample = sample; self.recordedAt = recordedAt
    }

    /// The outing this event belongs to, where one applies.
    public var clientOutingId: String? { fields["outing"] ?? sample?.clientOutingId }
}

/// A ready-to-use `TrackingOutput`: it records every engine event into a durable
/// FIFO log and replays it through a host-supplied uploader.
///
/// The host supplies transport and schema. This type owns the parts that are
/// facts about tracking rather than about an app: which events survive storage
/// pressure, how large a batch may be, how long one may hang, and when to retry.
/// It is the `ActivityTracking` counterpart of `HealthSync`'s upload pipeline.
///
/// Delivery is at least once. Return from `uploadBatch` only after the server has
/// acknowledged, and throw on anything else, or the work is dropped.
@MainActor
@Observable
public final class DurableTrackingOutput: TrackingOutput {
    public struct Configuration: Sendable {
        /// Log cap. Oldest droppable events trim past it; lifecycle never does.
        public var maxOps: Int = 25_000
        /// How far the log may overshoot `maxOps` before trimming, so a trim is
        /// one rewrite per `capSlack` writes rather than one per write at the
        /// cap. `nil` uses `DurableWriteLog`'s default of `max(500, maxOps/20)`,
        /// which is why a small `maxOps` does not trim promptly on its own.
        public var capSlack: Int?
        /// Events per upload call. Keep it under any server request limit.
        public var batchSize: Int = 25
        /// Per-batch ceiling; a hung transport fails the pass instead of the app.
        public var uploadTimeout: TimeInterval = 10
        /// Delays between no-progress passes within a single drain.
        public var retryBackoff: [TimeInterval] = [1.5, 3, 5]
        /// Delay before a fresh drain when work is still pending afterwards.
        public var retryDelay: TimeInterval = 30
        /// Minimum spacing between opportunistic flushes. Explicit `flush()`
        /// ignores it; the engine can request a flush every few seconds while
        /// moving, and each one is a network attempt.
        public var minimumFlushInterval: TimeInterval = 15
        /// Collapse superseded `outing.distance` and `farthest` events to the
        /// newest per outing. Both are monotonic within an outing, so the last
        /// value is the true one — but only enable it if the backend treats them
        /// as "set to", not "add". Off by default because that is the host's
        /// schema decision, and a wrong guess silently loses data.
        public var compactsDistanceUpdates: Bool = false

        public init() {}
    }

    @ObservationIgnored private let queue: DurableWriteLog<TrackingEvent>
    @ObservationIgnored private let uploadBatch: @Sendable ([TrackingEvent]) async throws -> Void
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let log: DiagnosticLog
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var lastFlushAt: Date = .distantPast

    /// Called when work remains after a drain, so the host can schedule a
    /// background opportunity. Mirrors `HealthSyncCoordinator`.
    public var requestBackgroundWork: (() -> Void)?

    /// Durable plus not-yet-written events. Non-zero is not an error.
    public var pendingCount: Int { queue.pendingCount }
    /// A write to disk failed. Check this independently of `lastError`.
    public var storageError: String? { queue.lastStorageError }
    public private(set) var lastUploadedAt: Date?
    /// The last upload failure. Cleared by a pass that fully drains.
    public private(set) var lastError: String?
    public private(set) var uploading = false

    public init(storageURL: URL, configuration: Configuration = Configuration(),
                log: DiagnosticLog = DiagnosticLog(),
                now: @escaping @Sendable () -> Date = { Date() },
                uploadBatch: @escaping @Sendable ([TrackingEvent]) async throws -> Void) {
        self.uploadBatch = uploadBatch
        self.configuration = configuration
        self.log = log
        self.now = now
        let compactsDistanceUpdates = configuration.compactsDistanceUpdates
        let batchSize = max(1, configuration.batchSize)
        queue = DurableWriteLog(
            storageURL: storageURL,
            maxOps: configuration.maxOps,
            capSlack: configuration.capSlack,
            isDroppable: { $0.kind.isDroppable },
            compact: { events in
                guard compactsDistanceUpdates else { return events }
                // Keep the newest superseding update per outing; every other
                // event, and the ordering of what remains, is preserved.
                var newest: [String: Int] = [:]
                for (index, event) in events.enumerated() {
                    switch event.kind {
                    case .outingDistance: newest["d|" + (event.clientOutingId ?? "")] = index
                    case .farthest: newest["f"] = index
                    default: continue
                    }
                }
                guard !newest.isEmpty else { return events }
                let superseded = Set(newest.values)
                return events.enumerated().compactMap { index, event in
                    switch event.kind {
                    case .outingDistance, .farthest: return superseded.contains(index) ? event : nil
                    default: return event
                    }
                }
            },
            batch: { Array($0.dropFirst($1).prefix(batchSize)) },
            log: log)
    }

    // ─── Uploading ───────────────────────────────────────────────────

    /// The engine's opportunistic upload trigger. Rate limited by
    /// `minimumFlushInterval`; concurrent callers await the same pass.
    public func flush() async {
        guard now().timeIntervalSince(lastFlushAt) >= configuration.minimumFlushInterval else { return }
        await drain()
    }

    /// Upload now, ignoring the flush interval. Use on network recovery, in a
    /// background handler, and from an explicit user action.
    public func drain() async {
        if let drainTask { await drainTask.value; return }
        let task = Task { @MainActor in
            defer { drainTask = nil }
            await performDrain()
        }
        drainTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func performDrain() async {
        lastFlushAt = now()
        uploading = true
        defer { uploading = false }
        let uploadBatch = self.uploadBatch
        let timeout = configuration.uploadTimeout
        let result = await queue.drainAll(backoff: configuration.retryBackoff, executeBatch: { batch in
            try await withTimeout(timeout) { try await uploadBatch(batch) }
            self.lastUploadedAt = self.now()
            self.log.record("tracking.upload", "batch=\(batch.count)")
        }) { _ in }
        lastError = result.lastError.map { $0.localizedDescription }
        if (queue.pendingCount > 0 || queue.lastStorageError != nil) && !Task.isCancelled {
            requestBackgroundWork?()
            scheduleRetry()
        } else {
            lastError = nil
            retry?.cancel(); retry = nil
        }
    }

    private func scheduleRetry() {
        guard retry == nil, configuration.retryDelay > 0 else { return }
        retry = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(configuration.retryDelay)) } catch { return }
            self.retry = nil
            await self.drain()
        }
    }

    /// Stop retrying. Durable events are preserved for a later drain.
    public func stop() {
        retry?.cancel(); retry = nil
        drainTask?.cancel()
    }

    // ─── Recording ───────────────────────────────────────────────────
    // Every call persists locally and returns; none of them wait on a network.

    private func append(_ kind: TrackingEvent.Kind, _ fields: [String: String] = [:],
                        sample: LocationSample? = nil) {
        queue.enqueue(TrackingEvent(kind: kind, fields: fields, sample: sample,
                                    recordedAt: now().timeIntervalSince1970 * 1000))
    }

    public func recordSample(_ sample: LocationSample) { append(.sample, sample: sample) }

    public func recordHome(_ home: LocationCoordinator.HomeLocation) {
        append(.home, ["lat": String(home.lat), "lng": String(home.lng),
                       "accuracy": String(home.accuracy), "radius": String(home.radius),
                       "at": stamp(home.setAt)])
    }

    // ─── ActivityBackend ─────────────────────────────────────────────
    // Server identifiers are advisory and unavailable offline, so these return
    // nil: the engine's client-generated IDs are the durable identity.

    public func startSession(clientOutingId: String, at: Date) async -> String? {
        append(.sessionStart, ["outing": clientOutingId, "at": stamp(at)])
        return nil
    }

    public func startOuting(clientOutingId: String, mode: String, source: String, at: Date,
                            homeLat: Double?, homeLng: Double?) async -> String? {
        var fields = ["outing": clientOutingId, "mode": mode, "source": source, "at": stamp(at)]
        if let homeLat { fields["homeLat"] = String(homeLat) }
        if let homeLng { fields["homeLng"] = String(homeLng) }
        append(.outingStart, fields)
        return nil
    }

    public func endOuting(clientOutingId: String, at: Date) async {
        append(.outingEnd, ["outing": clientOutingId, "at": stamp(at)])
    }

    public func setOutingMode(clientOutingId: String, mode: String) async {
        append(.outingMode, ["outing": clientOutingId, "mode": mode])
    }

    public func markFarRecord(clientOutingId: String) async {
        append(.outingRecord, ["outing": clientOutingId])
    }

    public func bumpMaxDistance(clientOutingId: String, meters: Double) async {
        append(.outingDistance, ["outing": clientOutingId, "meters": String(meters)])
    }

    public func startSegment(clientSegmentId: String, clientOutingId: String, type: String,
                             at: Date, placeId: String?) async {
        var fields = ["segment": clientSegmentId, "outing": clientOutingId,
                      "type": type, "at": stamp(at)]
        fields["place"] = placeId
        append(.segmentStart, fields)
    }

    public func endSegment(clientSegmentId: String, at: Date, distanceMeters: Double,
                           maxSpeed: Double, placeId: String?) async {
        var fields = ["segment": clientSegmentId, "at": stamp(at),
                      "meters": String(distanceMeters), "maxSpeed": String(maxSpeed)]
        fields["place"] = placeId
        append(.segmentEnd, fields)
    }

    public func upsertPlace(lat: Double, lng: Double, at: Date, clientSegmentId: String) async -> String? {
        append(.placeUpsert, ["lat": String(lat), "lng": String(lng),
                              "at": stamp(at), "segment": clientSegmentId])
        return nil
    }

    public func setFarthest(meters: Double) async { append(.farthest, ["meters": String(meters)]) }

    private func stamp(_ date: Date) -> String { String(date.timeIntervalSince1970) }
}
