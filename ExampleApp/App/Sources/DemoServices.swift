import Foundation
import HealthKit
import Observation
import SwiftUI
import ActivityTracking
import DurableSync
import HealthSync

/// Composition root. It owns storage, the metric selection, permission timing,
/// and transport; SignalKit owns collection, durability, and replay.
///
/// Most settings are construction-time, so changing one marks the services dirty
/// and `rebuild()` stops the old instances and constructs new ones over the same
/// directory. Durable files survive that, which is the point: pending uploads
/// from the previous configuration are still there afterwards.
@MainActor
@Observable
final class DemoServices {
    static let shared = DemoServices()

    private(set) var health: HealthSyncCoordinator
    private(set) var tracker: ActivityTracker

    var settings: DemoSettings {
        didSet {
            settings.save()
            if settings != oldValue { settingsChanged(from: oldValue) }
        }
    }
    /// True when a construction-time setting changed and the live services no
    /// longer match what is on screen.
    private(set) var needsRebuild = false

    private(set) var diagnostics: [String] = []
    private(set) var serverStats: [String: Any] = [:]
    private(set) var serverError: String?
    private(set) var seedMessage: String?
    var serverOffline = false

    /// How many HealthKit types this OS exposes, versus what the app selected.
    let catalogCount = HealthTypeCatalog.available().count

    @ObservationIgnored private var logSink: DiagnosticSink
    private var api: DemoAPI

    private static var storageDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "SignalKitExample", directoryHint: .isDirectory)
    }

    private init() {
        let settings = DemoSettings.load()
        self.settings = settings
        let api = DemoAPI(host: settings.host, account: settings.account)
        self.api = api
        let sink = DiagnosticSink()
        logSink = sink
        let built = Self.build(settings: settings, api: api, log: sink.log)
        tracker = built.0
        health = built.1
        sink.handler = { [weak self] event, detail in self?.note(event, detail) }
        installCallbacks()
    }

    /// One place where every setting reaches SignalKit.
    private static func build(settings: DemoSettings, api: DemoAPI, log: DiagnosticLog)
        -> (ActivityTracker, HealthSyncCoordinator) {
        let tracker = ActivityTracker(
            storageDirectory: storageDirectory,
            defaults: .standard,
            mode: settings.trackingMode,
            configuration: settings.outputConfiguration,
            log: log,
            uploadBatch: { events in try await api.sendTracking(events) })
        tracker.location.highAccuracyGPS = settings.highAccuracyGPS

        let health = HealthSyncCoordinator(
            storageDirectory: storageDirectory,
            defaults: .standard,
            metrics: settings.selectedMetrics,
            window: settings.healthWindow,
            log: log,
            uploadBatch: { totals in
                try await api.sendHealth(totals.map {
                    ["date": $0.date, "type": $0.type, "value": $0.value,
                     "unit": $0.unit, "recordedAt": $0.recordedAt]
                })
            })
        return (tracker, health)
    }

    private func installCallbacks() {
        // Presentation only — the tracker already drives its own outbox. These
        // must be set on the tracker, never on tracker.location.
        tracker.onOutingCompleted = { [weak self] id, _ in self?.note("outing.completed", id) }
        tracker.requestBackgroundWork = { [weak self] in self?.note("background.requested", "tracking outbox") }
        health.requestBackgroundWork = { [weak self] in self?.note("background.requested", "health outbox") }
        health.onReadCompleted = { [weak self] in self?.note("health.read", "ok") }
        health.onError = { [weak self] message in self?.note("health.error", message) }
    }

    private func settingsChanged(from old: DemoSettings) {
        if settings.host != old.host || settings.account != old.account {
            api = DemoAPI(host: settings.host, account: settings.account)
            needsRebuild = true                 // the uploaders captured the old API
        }
        // Runtime-changeable without a rebuild.
        if settings.highAccuracyGPS != old.highAccuracyGPS {
            tracker.location.highAccuracyGPS = settings.highAccuracyGPS
        }
        if settings.trackingMode != old.trackingMode {
            Task { await tracker.setTrackingMode(settings.trackingMode) }
        }
        // Everything else is construction-time.
        if old.batchSize != settings.batchSize
            || old.uploadTimeout != settings.uploadTimeout
            || old.retryDelaySeconds != settings.retryDelaySeconds
            || old.minimumFlushInterval != settings.minimumFlushInterval
            || old.maxOps != settings.maxOps
            || old.capSlack != settings.capSlack
            || old.usesCustomCapSlack != settings.usesCustomCapSlack
            || old.compactsDistanceUpdates != settings.compactsDistanceUpdates
            || old.healthWindowDays != settings.healthWindowDays
            || old.metrics != settings.metrics {
            needsRebuild = true
        }
    }

    /// Stop the current services and construct new ones. Durable files are left
    /// in place, so anything already queued survives the swap.
    func rebuild() {
        let pending = tracker.pendingUploads + health.pendingWrites
        tracker.stop()
        health.stop()
        let sink = DiagnosticSink()
        logSink = sink
        let built = Self.build(settings: settings, api: api, log: sink.log)
        tracker = built.0
        health = built.1
        sink.handler = { [weak self] event, detail in self?.note(event, detail) }
        installCallbacks()
        needsRebuild = false
        note("services.rebuilt", "\(pending) queued item(s) preserved")
        bootstrap()
    }

    func note(_ event: String, _ detail: String = "") {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        diagnostics.insert("\(stamp)  \(event)\(detail.isEmpty ? "" : "  \(detail)")", at: 0)
        if diagnostics.count > 300 { diagnostics.removeLast(diagnostics.count - 300) }
    }

    func clearLog() { diagnostics.removeAll() }

    // MARK: Lifecycle

    func bootstrap() {
        health.bootstrap()
        tracker.bootstrap()
        note("bootstrap", "health + location armed")
        Task { await refreshStats() }
    }

    func onForeground() {
        tracker.onForeground()
        Task {
            await health.syncRecent()
            await health.drainUploads()
            await refreshStats()
        }
    }

    func stopEverything() {
        tracker.stop()
        health.stop()
        note("stop", "observation and retries halted; durable files preserved")
    }

    func requestPermissions() async {
        tracker.requestAuthorization()
        await health.requestAuthorization()
        note("permissions", "requested")
        await refreshStats()
    }

    // MARK: Uploads

    func syncEverything() async {
        await health.syncRecent()
        await health.drainUploads()
        await tracker.drainUploads()
        await refreshStats()
    }

    func syncHealth(days: Int? = nil, reconcile: Bool = true) async {
        if let days { await health.syncRecent(days: days, reconcile: reconcile) }
        else { await health.syncRecent(reconcile: reconcile) }
        await health.drainUploads()
        await refreshStats()
    }

    func refreshStats() async {
        try? await api.sendStatus([
            "backgroundEnabledTypes": health.status.healthBackgroundEnabledTypes,
            "backgroundUpdatesAvailable": tracker.location.backgroundUpdatesAvailable,
            "pendingHealthWrites": health.pendingWrites,
            "pendingTrackingOps": tracker.pendingUploads,
            "locationAuth": tracker.location.authStatus.rawValue,
            "preciseLocation": tracker.location.accuracyStatus == .fullAccuracy,
            "enginePhase": String(describing: tracker.location.enginePhase),
            "trackingMode": String(describing: tracker.trackingMode),
            "lastError": health.status.lastError ?? tracker.lastUploadError ?? "",
        ])
        do {
            serverStats = try await api.stats()
            serverError = nil
            serverOffline = (serverStats["offline"] as? Bool) ?? false
        } catch {
            serverError = error.localizedDescription
        }
    }

    func setServerOffline(_ offline: Bool) async {
        do {
            try await api.setServerOffline(offline)
            serverOffline = offline
            note("server.offline", String(offline))
        } catch {
            serverError = error.localizedDescription
        }
        await refreshStats()
    }

    // MARK: Demo data

    /// The simulator ships no Health data, so the app writes its own samples.
    /// This is host-side seeding through plain HealthKit; SignalKit only reads.
    func seedHealthSamples() async {
        let store = HKHealthStore()
        let types: Set<HKSampleType> = [HKQuantityType(.stepCount), HKQuantityType(.heartRate),
                                        HKQuantityType(.activeEnergyBurned)]
        do {
            try await store.requestAuthorization(toShare: types, read: [])
        } catch {
            seedMessage = "write permission failed: \(error.localizedDescription)"
            return
        }
        var samples: [HKSample] = []
        let calendar = Calendar.current
        for dayOffset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date()),
                  let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) else { continue }
            let anchor = min(noon, Date().addingTimeInterval(-60))
            for step in 0..<6 {
                let start = anchor.addingTimeInterval(Double(step) * -600)
                let end = start.addingTimeInterval(300)
                samples.append(HKQuantitySample(type: HKQuantityType(.stepCount),
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(300 + step * 47)),
                    start: start, end: end))
                samples.append(HKQuantitySample(type: HKQuantityType(.heartRate),
                    quantity: HKQuantity(unit: .count().unitDivided(by: .minute()),
                                         doubleValue: Double(62 + step * 3)),
                    start: start, end: start))
                samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(18 + step * 4)),
                    start: start, end: end))
            }
        }
        do {
            try await store.save(samples)
            seedMessage = "wrote \(samples.count) samples across 3 days"
            note("seed", seedMessage ?? "")
        } catch {
            seedMessage = "save failed: \(error.localizedDescription)"
        }
    }
}
