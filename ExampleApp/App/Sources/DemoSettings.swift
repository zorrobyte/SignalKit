import Foundation
import HealthKit
import ActivityTracking
import HealthSync

/// Every knob the three products expose, persisted so a relaunch keeps them.
///
/// Most of these are construction-time on the SignalKit side — the coordinators
/// take them once and own them for their lifetime. Changing one here therefore
/// marks the services dirty and the app rebuilds them, which is the same
/// stop-and-recreate dance the docs require before switching accounts.
struct DemoSettings: Codable, Equatable {
    // ─── Server ──────────────────────────────────────────────────────
    /// The simulator reaches the Mac on localhost. For a device, use the Mac's
    /// LAN address and add a matching ATS exception (see the README).
    var host = "127.0.0.1:8787"
    var account = defaultAccount

    // ─── ActivityTracking ────────────────────────────────────────────
    var roaming = false
    /// Roaming only: a stop this long ends the outing and becomes the next base.
    var restThresholdHours = 4.0
    /// Persisted by the package; disables software distance thinning.
    var highAccuracyGPS = false

    // ─── HealthSync ──────────────────────────────────────────────────
    var healthWindowDays = 7
    var metrics: [MetricChoice] = MetricChoice.defaults

    // ─── DurableSync (tracking outbox) ───────────────────────────────
    var batchSize = 25
    var uploadTimeout = 10.0
    var retryDelaySeconds = 30.0
    var minimumFlushInterval = 15.0
    var maxOps = 25_000
    var usesCustomCapSlack = false
    var capSlack = 500
    var compactsDistanceUpdates = false

    static let defaultAccount: String = {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        return "device"
        #endif
    }()

    // ─── Persistence ─────────────────────────────────────────────────

    private static let key = "demo.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> DemoSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(DemoSettings.self, from: data)
        else { return DemoSettings() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // ─── Derived SignalKit inputs ────────────────────────────────────

    var trackingMode: TrackingMode {
        roaming ? .roaming(restThreshold: restThresholdHours * 3600) : .homeAnchored
    }

    var outputConfiguration: DurableTrackingOutput.Configuration {
        var configuration = DurableTrackingOutput.Configuration()
        configuration.batchSize = batchSize
        configuration.uploadTimeout = uploadTimeout
        configuration.retryDelay = retryDelaySeconds
        configuration.minimumFlushInterval = minimumFlushInterval
        configuration.maxOps = maxOps
        configuration.capSlack = usesCustomCapSlack ? capSlack : nil
        configuration.compactsDistanceUpdates = compactsDistanceUpdates
        return configuration
    }

    var healthWindow: HealthWindow { HealthWindow(days: healthWindowDays) }

    @MainActor var selectedMetrics: [HealthMetric] { metrics.filter(\.enabled).map(\.metric) }
}

/// A togglable metric. HealthSync takes an explicit selection — it never asks for
/// everything — so this is the host's permission decision, made visible.
struct MetricChoice: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case steps, heartRate, activeEnergy, restingHeartRate,
                                     distanceWalking, flightsClimbed, exerciseTime, sleep }
    var kind: Kind
    var enabled: Bool
    /// Ignored by metrics whose statistic is fixed (sums and durations).
    var statistic: StatisticChoice = .automatic

    var id: String { kind.rawValue }

    static let defaults: [MetricChoice] = [
        .init(kind: .steps, enabled: true),
        .init(kind: .heartRate, enabled: true, statistic: .average),
        .init(kind: .activeEnergy, enabled: true),
        .init(kind: .restingHeartRate, enabled: false, statistic: .average),
        .init(kind: .distanceWalking, enabled: false),
        .init(kind: .flightsClimbed, enabled: false),
        .init(kind: .exerciseTime, enabled: false),
        .init(kind: .sleep, enabled: false),
    ]

    var label: String {
        switch kind {
        case .steps: return "Steps"
        case .heartRate: return "Heart rate"
        case .activeEnergy: return "Active energy"
        case .restingHeartRate: return "Resting heart rate"
        case .distanceWalking: return "Walking + running distance"
        case .flightsClimbed: return "Flights climbed"
        case .exerciseTime: return "Exercise minutes"
        case .sleep: return "Asleep duration"
        }
    }

    /// True where the value is a sum or a duration, so a statistic makes no sense.
    var statisticIsFixed: Bool {
        switch kind {
        case .heartRate, .restingHeartRate: return false
        default: return true
        }
    }

    @MainActor var metric: HealthMetric {
        switch kind {
        case .steps:
            return .quantity(HKQuantityType(.stepCount), unit: .count(), id: "steps")
        case .heartRate:
            return .quantity(HKQuantityType(.heartRate), unit: .count().unitDivided(by: .minute()),
                             id: "heart_rate", statistic: statistic.value)
        case .activeEnergy:
            return .quantity(HKQuantityType(.activeEnergyBurned), unit: .kilocalorie(), id: "active_energy")
        case .restingHeartRate:
            return .quantity(HKQuantityType(.restingHeartRate), unit: .count().unitDivided(by: .minute()),
                             id: "resting_heart_rate", statistic: statistic.value)
        case .distanceWalking:
            return .quantity(HKQuantityType(.distanceWalkingRunning), unit: .meter(), id: "distance_m")
        case .flightsClimbed:
            return .quantity(HKQuantityType(.flightsClimbed), unit: .count(), id: "flights")
        case .exerciseTime:
            return .quantity(HKQuantityType(.appleExerciseTime), unit: .minute(), id: "exercise_min")
        case .sleep:
            // Asleep values only: in-bed and awake time must not count as sleep.
            return .categoryDuration(HKCategoryType(.sleepAnalysis), values: [
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            ], id: "sleep_min")
        }
    }
}

enum StatisticChoice: String, Codable, CaseIterable, Identifiable {
    case automatic, sum, average, minimum, maximum
    var id: String { rawValue }
    var value: HealthMetric.Statistic {
        switch self {
        case .automatic: return .automatic
        case .sum: return .sum
        case .average: return .average
        case .minimum: return .minimum
        case .maximum: return .maximum
        }
    }
}
