import Foundation
import HealthKit
import HealthSync

/// Explicit read selection, seven calendar days, and account-scoped storage.
/// Retain the result and call bootstrap at launch. Request authorization only
/// from a user action after configuring the host's HealthKit entitlement/copy.
@MainActor public func makeHealthSync(
    directory: URL, defaults: UserDefaults,
    send: @escaping @Sendable ([HealthAggregate]) async throws -> Void
) -> HealthSyncCoordinator {
    HealthSyncCoordinator(storageDirectory: directory, defaults: defaults, metrics: [
        .quantity(HKQuantityType(.stepCount), unit: .count(), id: "steps"),
        .quantity(HKQuantityType(.heartRate), unit: .count().unitDivided(by: .minute()),
                  id: "heart_rate", statistic: .average),
    ], window: HealthWindow(days: 7), uploadBatch: send)
}
