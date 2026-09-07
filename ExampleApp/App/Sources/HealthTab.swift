import SwiftUI
import HealthSync

/// HealthSync: the reconciliation state, the metric selection the host is
/// responsible for, and the window it summarizes.
struct HealthTab: View {
    @Environment(DemoServices.self) private var services

    var body: some View {
        @Bindable var services = services
        NavigationStack {
            List {
                Section("Status") {
                    StateRow("HealthKit available", services.health.isAvailable ? "yes" : "no",
                             warn: !services.health.isAvailable)
                    StateRow("reading", services.health.status.healthReading ? "in progress" : "idle")
                    StateRow("uploading", services.health.status.uploading ? "in progress" : "idle")
                    StateRow("observers registered", "\(services.health.status.healthBackgroundEnabledTypes)",
                             warn: services.health.status.healthBackgroundEnabledTypes == 0)
                    StateRow("days awaiting reconcile", "\(services.health.status.pendingHealthDays)")
                    StateRow("history catching up",
                             services.health.status.healthHistoryCatchingUp ? "yes" : "no")
                    StateRow("last read", stamp(services.health.lastSyncAt))
                    StateRow("last upload", stamp(services.health.lastUploadedAt))
                    if let error = services.health.status.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if services.health.status.healthBackgroundEnabledTypes == 0 {
                        Text("Zero registered observers usually means the "
                             + "com.apple.developer.healthkit.background-delivery entitlement is "
                             + "missing. The simulator declines registration regardless.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Today") {
                    if services.health.todayAggregates.isEmpty {
                        Text("No values yet. Grant access, then sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(services.health.todayAggregates) { aggregate in
                        StateRow(aggregate.label, String(format: "%.1f %@", aggregate.value, aggregate.unit))
                    }
                }

                Section("Actions") {
                    Button("Request read access") {
                        Task { await services.health.requestAuthorization() }
                    }
                    Button("Sync window + upload") { Task { await services.syncHealth() } }
                    Button("Sync today only") {
                        Task { await services.health.syncToday(); await services.refreshStats() }
                    }
                    Button("Sync without reconciling") {
                        Task { await services.syncHealth(reconcile: false) }
                    }
                    Button("Seed sample data (simulator)") {
                        Task { await services.seedHealthSamples() }
                    }
                    if let message = services.seedMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }

                RebuildBanner()

                Section("Window") {
                    StepperRow(label: "Calendar days", value: $services.settings.healthWindowDays,
                               range: 1...30, suffix: " days",
                               note: "Calendar days including today, not a rolling 24×N hours. "
                                   + "Package default 7, maximum 365.")
                }

                Section {
                    ForEach($services.settings.metrics) { $choice in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(choice.label, isOn: $choice.enabled)
                            if choice.enabled && !choice.statisticIsFixed {
                                Picker("Statistic", selection: $choice.statistic) {
                                    ForEach(StatisticChoice.allCases) { option in
                                        Text(option.rawValue.capitalized).tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                } header: {
                    Text("Metrics — \(services.settings.selectedMetrics.count) of "
                         + "\(services.settings.metrics.count) selected")
                } footer: {
                    Text("HealthSync never asks for everything: the read request is exactly the "
                         + "union of these. This OS exposes \(services.catalogCount) types through "
                         + "HealthTypeCatalog; asking for more than the app uses is a permission "
                         + "prompt users are right to refuse.")
                }
            }
            .navigationTitle("HealthSync")
        }
    }

    private func stamp(_ date: Date?) -> String {
        date.map { $0.formatted(date: .omitted, time: .standard) } ?? "never"
    }
}
