import Foundation
import DurableSync
import HealthKit
import Observation
import UIKit

/// Configurable daily reconciliation with a durable, backend-independent outbox.
/// The host chooses metrics, storage, permission timing, and upload behavior.
@MainActor
@Observable
public final class HealthSyncCoordinator {
    private let reader: any HealthReading
    private let observation: any HealthObserving
    private let metrics: [HealthMetric]
    private let defaults: UserDefaults
    private let log: DiagnosticLog
    public let status: HealthSyncStatus
    public let window: HealthWindow
    private let upload: HealthUploadPipeline
    public var onTodayChanged: (([TypeAggregate]) -> Void)?
    public var onReadCompleted: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var requestBackgroundWork: (() -> Void)? {
        didSet { upload.requestBackgroundWork = requestBackgroundWork }
    }
    private var readTypes: Set<HKObjectType> { Set(metrics.flatMap(\.readTypes)) }

    public var lastSyncAt: Date? {
        get { status.lastHealthReadAt }
        set { status.lastHealthReadAt = newValue }
    }
    public var lastError: String?
    public var todayAggregates: [TypeAggregate] = []
    public var lastUploadedAt: Date? {
        get { status.lastHealthUploadAt }
        set { status.lastHealthUploadAt = newValue }
    }
    private var observers: [() -> Void] = []
    private var nextIndexType = 0
    private var observationGeneration = 0
    private var syncTask: Task<Void, Never>?
    private var requestedDays = 0
    private let changes: HealthChangeJournal
    private let uploadCheckpoint: HealthUploadCheckpoint
    private var passUploads: [HealthAggregate] = []
    private var queuedTotals = 0
    private var databaseLocked = false
    private var readFailed = false
    private var dayFailed = false
    private var retryTask: Task<Void, Never>?
    private var unlockObserver: NSObjectProtocol?

    public func bootstrap() {
        guard isAvailable, observers.isEmpty else { return }
        let generation = observationGeneration
        // Register on every launch, including upgrades whose old build never
        // wrote our authorizationRequested preference. This does not prompt.
        if unlockObserver == nil {
            unlockObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.syncRecent() }
                }
        }
        for type in readTypes.compactMap({ $0 as? HKSampleType }) {
            let cancel = observation.observe(type) { [weak self] error, completion in
                Task { @MainActor in
                    defer { completion() }
                    guard self?.observationGeneration == generation else { return }
                    if let error { self?.readError(error); self?.scheduleRetry(); return }
                    await self?.syncRecent()
                }
            }
            observers.append(cancel)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let enabled = try await observation.enableBackgroundDelivery(type)
                    guard observationGeneration == generation else { return }
                    if enabled { status.healthBackgroundEnabledTypes += 1 }
                } catch {
                    guard observationGeneration == generation else { return }
                    status.recordError("Health background delivery: \(error.localizedDescription)")
                }
            }
        }
    }

    public struct TypeAggregate: Identifiable, Hashable {
        public let id: String
        public let label: String
        public let value: Double
        public let unit: String
    }

    public init(storageDirectory: URL, defaults: UserDefaults, metrics: [HealthMetric],
                window: HealthWindow = HealthWindow(), store: HKHealthStore = HKHealthStore(),
                log: DiagnosticLog = DiagnosticLog(), reader: (any HealthReading)? = nil,
                observation: (any HealthObserving)? = nil,
                uploadBatch: @escaping @Sendable ([HealthAggregate]) async throws -> Void) {
        precondition(Set(metrics.map(\.id)).count == metrics.count, "Metric IDs must be unique")
        let reader = reader ?? HealthDataReader(store: store)
        self.reader = reader
        self.observation = observation ?? HealthKitObservation(store: reader.store)
        self.defaults = defaults; self.metrics = metrics; self.window = window; self.log = log
        let status = HealthSyncStatus(defaults: defaults)
        self.status = status
        do { try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true) }
        catch { status.recordError("Storage: " + error.localizedDescription) }
        self.changes = HealthChangeJournal(url: storageDirectory.appendingPathComponent("health-changes-v1.json"))
        self.uploadCheckpoint = HealthUploadCheckpoint(url: storageDirectory.appendingPathComponent("health-upload-checkpoint-v1.json"), window: window)
        self.upload = HealthUploadPipeline(url: storageDirectory.appendingPathComponent("health-uploads-v1.jsonl"),
            window: window, status: status, log: log, uploadBatch: uploadBatch)
    }

    public var pendingWrites: Int { upload.pendingCount }
    public var storageError: String? { upload.storageError }
    public func drainUploads() async { await upload.drain() }


    public var isAvailable: Bool { reader.isAvailable }

    /// Stops observing and scheduled retries. Durable data remains for replay.
    /// An already submitted server request may still complete; keep it idempotent.
    public func stop() {
        observationGeneration += 1
        observers.forEach { $0() }; observers = []
        retryTask?.cancel(); retryTask = nil
        syncTask?.cancel()
        upload.cancelRetry()
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        unlockObserver = nil
        status.healthBackgroundEnabledTypes = 0
    }

    // ─── Authorization ───────────────────────────────────────────────
    public func requestAuthorization() async {
        guard isAvailable else {
            log.record("health", "not available on this device")
            return
        }
        do {
            try await reader.requestAuthorization(read: readTypes)
            defaults.set(true, forKey: "health.authorizationRequested")
            observers.forEach { $0() }
            observers = []
            observationGeneration += 1
            status.healthBackgroundEnabledTypes = 0
            try changes.revisitKnownDates()
            bootstrap()
            await syncRecent()
            log.record("health.auth", "request returned")
        } catch {
            log.record("health.auth.error", error.localizedDescription)
            readError(error)
        }
    }

    // ─── Backfill last N days ────────────────────────────────────────
    // Aggregates and upserts the prior N daily buckets (today included)
    // so a fresh install populates the configured window.
    // Hosts must provide idempotent upserts keyed by account, date, and type.
    public func syncRecent(days: Int = Int.max, reconcile: Bool = true) async {
        guard isAvailable else { return }
        if reconcile { requestedDays = max(requestedDays, min(window.days, max(1, days))) }
        if let running = syncTask { await running.value; return }
        let task = Task { @MainActor in
            status.healthReading = true
            defer { syncTask = nil; status.healthReading = false }
            lastError = nil
            readFailed = false
            databaseLocked = false
            queuedTotals = 0
            passUploads = []
            await captureChanges()
            var completedDates = Set<String>()
            if requestedDays > 0 && !databaseLocked {
                let days = requestedDays
                requestedDays = 0
                let cal = Calendar.current
                let today = cal.startOfDay(for: Date())
                for offset in stride(from: days - 1, through: 0, by: -1) {
                    guard !Task.isCancelled else { return }
                    if databaseLocked { break }
                    guard let start = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
                    let end = min(Date(), cal.date(byAdding: .day, value: 1, to: start) ?? Date())
                    let fresh = await syncDay(start: start, end: end)
                    if !dayFailed { completedDates.insert(isoDate(start)) }
                    if offset == 0 && !dayFailed {
                        todayAggregates = fresh
                        onTodayChanged?(fresh)
                    }
                }
            }
            do {
                var datesToAcknowledge = Set<String>()
                let moreChanges = try readTypes.compactMap { $0 as? HKSampleType }
                    .contains { try !changes.isCaughtUp(type: $0.identifier) }
                status.healthHistoryCatchingUp = moreChanges
                // Reconcile only this week, without reading successful days twice.
                for date in try changes.pendingDates() where !moreChanges && window.contains(date) {
                    guard !Task.isCancelled else { return }
                    if databaseLocked { break }
                    if completedDates.contains(date) {
                        datesToAcknowledge.insert(date)
                        continue
                    }
                    guard let start = dateFromKey(date), let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { continue }
                    _ = await syncDay(start: start, end: min(Date(), end))
                    if !dayFailed { datesToAcknowledge.insert(date) }
                }
                // Queue the complete pass synchronously before starting any
                // upload, then acknowledge corrections only after durability.
                queuedTotals = try uploadCheckpoint.enqueueChanged(passUploads, enqueue: upload.enqueue)
                for date in datesToAcknowledge { try changes.acknowledge(date: date) }
                status.pendingHealthDays = try changes.pendingDates().count
                if readFailed || requestedDays > 0 || status.pendingHealthDays > 0 || moreChanges {
                    scheduleRetry(seconds: readFailed ? 60 : 3, reconcile: readFailed || requestedDays > 0)
                }
            } catch { readError(error); scheduleRetry() }
            if !readFailed {
                lastSyncAt = Date()
                status.clearError(matchingPrefix: "Health:")
                onReadCompleted?()
            }
            log.record("health.read", readFailed ? "Read incomplete; retry pending" : "Read complete; changed totals queued=\(queuedTotals)")
            // HealthKit's observer completion must not wait for connectivity.
            // Aggregates are already durable in the WAL at this point.
            Task { await self.upload.drain() }
        }
        syncTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    // ─── Daily aggregation ───────────────────────────────────────────
    // syncToday is a thin shim over syncDay that also updates the in-memory
    // todayAggregates list used by TodayView and pushes Time in Daylight into
    // the widget snapshot. Backfills go through syncDay directly.
    public func syncToday() async {
        await syncRecent(days: 1)
    }

    // Aggregates one day's worth of HealthKit data and writes the rollups to
    // the durable outbox. Skips silently for unauthorized / empty types.
    @discardableResult
    private func syncDay(start: Date, end: Date) async -> [TypeAggregate] {
        dayFailed = false
        var fresh: [TypeAggregate] = []
        let date = isoDate(start)
        for metric in metrics {
            guard !databaseLocked, !Task.isCancelled else { break }
            do {
                var value: Double?
                do {
                    value = try await metric.read(reader, DateInterval(start: start, end: end))
                } catch let error as NSError where error.domain == HKErrorDomain
                    && error.code == HKError.errorNoData.rawValue {
                    value = nil
                }
                if value == nil, let type = metric.deletionTypeIdentifier,
                   try changes.canClearEmpty(type: type, date: date) { value = 0 }
                if let value {
                    guard value.isFinite else { throw HealthReadError.invalidValue }
                    fresh.append(TypeAggregate(id: metric.id, label: metric.label, value: value, unit: metric.unit))
                    passUploads.append(HealthAggregate(date: date, type: metric.id, value: value,
                        unit: metric.unit, recordedAt: Date().timeIntervalSince1970 * 1000))
                }
            } catch { readError(error) }
        }
        return fresh
    }

    private func readError(_ error: Error) {
        let e = error as NSError
        if e.domain == HKErrorDomain && e.code == HKError.errorNoData.rawValue { return }
        readFailed = true
        dayFailed = true
        if e.domain == HKErrorDomain && e.code == HKError.errorDatabaseInaccessible.rawValue {
            databaseLocked = true
        }
        lastError = e.domain == HKErrorDomain && e.code == HKError.errorDatabaseInaccessible.rawValue
            ? "Health data is locked. Retry after unlocking the iPhone."
            : error.localizedDescription
        status.recordError("Health: \(lastError!)")
        onError?(lastError!)
    }

    private func scheduleRetry(seconds: Double = 60, reconcile: Bool = true) {
        guard !Task.isCancelled else { return }
        requestBackgroundWork?()
        // The unlock notification and next foreground wake resume a locked read.
        guard !databaseLocked else { return }
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            retryTask = nil
            await syncRecent(reconcile: reconcile)
        }
    }

    private func dateFromKey(_ key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = .init(identifier: .gregorian)
        f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    private func captureChanges() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var pageCount = 0
        defer { log.record("health.index", "pages=\(pageCount) locked=\(databaseLocked)") }
        let windowStart = window.start()
        do { try changes.prepareWindow(start: isoDate(windowStart), end: isoDate(Date())) }
        catch { readError(error); return }
        let types = readTypes.compactMap { $0 as? HKSampleType }.sorted { $0.identifier < $1.identifier }
        guard !types.isEmpty else { return }
        let first = nextIndexType % types.count
        for offset in types.indices {
            let index = (first + offset) % types.count
            let type = types[index]
            guard !Task.isCancelled, !databaseLocked else { return }
            // Rotate before querying so a large/high-volume type cannot starve
            // the rest when this pass reaches its between-page time budget.
            nextIndexType = (index + 1) % types.count
            do {
              repeat {
                guard !Task.isCancelled, !databaseLocked, ContinuousClock.now < deadline else { return }
                let encoded = try changes.anchor(for: type.identifier)
                let anchor = try encoded.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) } ?? nil
                let page = try await reader.changes(type: type, start: windowStart, end: nil, anchor: anchor, limit: 500)
                let footprints = page.samples.map { sample in
                    var dates: [String] = []
                    var day = max(windowStart, Calendar.current.startOfDay(for: sample.startDate))
                    repeat {
                        if day <= Date() { dates.append(self.isoDate(day)) }
                        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }
                        day = next
                    } while day < min(sample.endDate, Date())
                    return HealthChangeJournal.Footprint(id: sample.uuid.uuidString, dates: dates)
                }
                let data = try NSKeyedArchiver.archivedData(withRootObject: page.anchor, requiringSecureCoding: true)
                try changes.apply(type: type.identifier, anchor: data, added: footprints,
                    deleted: page.deletedIDs.map(\.uuidString), caughtUp: !page.hasMore)
                pageCount += 1
              } while try !changes.isCaughtUp(type: type.identifier)
            } catch { readError(error) }
        }
    }

    private func isoDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = .init(identifier: .gregorian)
        f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
