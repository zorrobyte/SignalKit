import SwiftUI
import ActivityTracking

/// DurableSync: both outboxes, the queue tuning, and a way to prove the thing
/// actually holds work — take the server down, watch pending climb, bring it
/// back, watch it drain.
struct DurableTab: View {
    @Environment(DemoServices.self) private var services

    var body: some View {
        @Bindable var services = services
        NavigationStack {
            List {
                Section("Outboxes") {
                    StateRow("tracking pending", "\(services.tracker.pendingUploads)")
                    StateRow("health pending", "\(services.health.pendingWrites)")
                    StateRow("uploading", services.tracker.uploading ? "yes" : "no")
                    StateRow("last tracking upload", stamp(services.tracker.lastUploadedAt))
                    if let error = services.tracker.lastUploadError {
                        StateRow("tracking error", error, warn: true)
                    }
                    if let error = services.tracker.storageError {
                        StateRow("tracking storage", error, warn: true)
                    }
                    if let error = services.health.storageError {
                        StateRow("health storage", error, warn: true)
                    }
                    Button("Drain both now") { Task { await services.syncEverything() } }
                }

                Section {
                    Toggle("Simulate server outage", isOn: Binding(
                        get: { services.serverOffline },
                        set: { value in Task { await services.setServerOffline(value) } }))
                } header: {
                    Text("Failure injection")
                } footer: {
                    Text("Every write returns 503 while this is on. Move around or seed health "
                         + "data, watch pending climb, then switch it off and drain: the same "
                         + "event ids are redelivered and the server ignores the duplicates.")
                }

                Section("Database") {
                    if let error = services.serverError {
                        StateRow("unreachable", error, warn: true)
                    }
                    StateRow("health rows", "\(services.serverStats["health_rows"] as? Int ?? 0)")
                    StateRow("tracking events", "\(services.serverStats["tracking_events"] as? Int ?? 0)")
                    StateRow("location samples", "\(services.serverStats["location_samples"] as? Int ?? 0)")
                    ForEach(kinds, id: \.0) { kind, count in
                        StateRow(kind, "\(count)")
                    }
                    Button("Refresh") { Task { await services.refreshStats() } }
                }

                RebuildBanner()

                Section {
                    StepperRow(label: "Batch size", value: $services.settings.batchSize,
                               range: 1...200, suffix: " events",
                               note: "Events per upload call. Package default 25.")
                    SliderRow(label: "Upload timeout", value: $services.settings.uploadTimeout,
                              range: 1...60, step: 1, suffix: " s",
                              note: "Per-batch ceiling. A hung transport fails the pass, not the app. Default 10 s.")
                    SliderRow(label: "Retry delay", value: $services.settings.retryDelaySeconds,
                              range: 0...300, step: 5, suffix: " s",
                              note: "Delay before a fresh drain while work remains. 0 disables retries. Default 30 s.")
                    SliderRow(label: "Minimum flush interval",
                              value: $services.settings.minimumFlushInterval,
                              range: 0...120, step: 1, suffix: " s",
                              note: "Spacing for the engine's opportunistic flushes; explicit drains ignore it. Default 15 s.")
                } header: {
                    Text("Upload tuning")
                }

                Section {
                    StepperRow(label: "Max ops", value: $services.settings.maxOps,
                               range: 10...50_000, step: 500,
                               note: "Log cap. Oldest raw samples trim past it; lifecycle events never do. Default 25,000.")
                    Toggle("Custom cap slack", isOn: $services.settings.usesCustomCapSlack)
                    if services.settings.usesCustomCapSlack {
                        StepperRow(label: "Cap slack", value: $services.settings.capSlack,
                                   range: 0...5_000, step: 50,
                                   note: "Overshoot allowed before trimming. Default max(500, maxOps/20), "
                                       + "so a small cap does not trim promptly on its own.")
                    }
                    Toggle("Compact distance updates", isOn: $services.settings.compactsDistanceUpdates)
                    Text("Collapses superseded outing.distance and farthest events to the newest "
                         + "per outing. Correct only if your backend treats them as \"set to\", "
                         + "not \"add\" — off by default because a wrong guess loses data silently.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Storage tuning")
                }

                Section("Server") {
                    LabeledContent("Host") {
                        TextField("127.0.0.1:8787", text: $services.settings.host)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: 190)
                    }
                    LabeledContent("Account") {
                        TextField("account", text: $services.settings.account)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: 190)
                    }
                    Text("Rows are keyed by account. On a physical device use the Mac's LAN "
                         + "address and add a matching ATS exception — see the README.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Lifecycle") {
                    Button("Bootstrap") { services.bootstrap() }
                    Button("Stop collection", role: .destructive) { services.stopEverything() }
                    Text("Stop halts observation and retries. It deletes nothing: durable files "
                         + "stay on disk and replay on the next drain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DurableSync")
        }
    }

    private var kinds: [(String, Int)] {
        (services.serverStats["event_kinds"] as? [[String: Any]] ?? []).compactMap {
            guard let kind = $0["kind"] as? String, let count = $0["n"] as? Int else { return nil }
            return (kind, count)
        }
    }

    private func stamp(_ date: Date?) -> String {
        date.map { $0.formatted(date: .omitted, time: .standard) } ?? "never"
    }
}
