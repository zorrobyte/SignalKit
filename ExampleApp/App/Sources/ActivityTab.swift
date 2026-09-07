import CoreLocation
import SwiftUI
import ActivityTracking

/// ActivityTracking: what the engine currently believes, and every knob it takes.
struct ActivityTab: View {
    @Environment(DemoServices.self) private var services

    var body: some View {
        @Bindable var services = services
        NavigationStack {
            List {
                Section("Engine state") {
                    StateRow("phase", "\(services.tracker.location.enginePhase)")
                    StateRow("mode", services.settings.roaming ? "roaming" : "home-anchored")
                    StateRow("anchor", services.tracker.location.anchorCoordinate.map {
                        String(format: "%.4f, %.4f", $0.latitude, $0.longitude) } ?? "none yet")
                    StateRow("outing started", services.tracker.location.currentOutingStartedAt
                        .map { $0.formatted(date: .omitted, time: .standard) } ?? "not in an outing")
                    StateRow("max distance", String(format: "%.0f m",
                                                    services.tracker.location.currentMaxDistanceMeters))
                    StateRow("dwelling", services.tracker.location.isDwelling ? "yes" : "no")
                    StateRow("motion", "\(services.tracker.motion.state.label) "
                             + "(\(services.tracker.motion.confidenceName))")
                    StateRow("last fix", services.tracker.location.lastSample.map {
                        String(format: "%.4f, %.4f ±%.0fm", $0.coordinate.latitude,
                               $0.coordinate.longitude, $0.horizontalAccuracy) } ?? "none")
                    if let error = services.tracker.location.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Permissions") {
                    StateRow("location", authName(services.tracker.location.authStatus),
                             warn: services.tracker.location.authStatus != .authorizedAlways)
                    StateRow("accuracy", services.tracker.location.accuracyStatus == .fullAccuracy
                             ? "full" : "reduced",
                             warn: services.tracker.location.accuracyStatus != .fullAccuracy)
                    StateRow("motion", services.tracker.motion.authStatusName)
                    StateRow("background updates",
                             services.tracker.location.backgroundUpdatesAvailable ? "enabled" : "unavailable",
                             warn: !services.tracker.location.backgroundUpdatesAvailable)
                    if !services.tracker.location.backgroundUpdatesAvailable {
                        Text("The host Info.plist is missing UIBackgroundModes: location. "
                             + "Collection stops when the app suspends, and nothing else reports it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Request location + motion access") {
                        services.tracker.requestAuthorization()
                    }
                    Button("Request precise accuracy") {
                        services.tracker.requestPreciseAccuracy()
                    }
                }

                RebuildBanner()

                Section("Tracking mode") {
                    Toggle("Roaming (no fixed home)", isOn: $services.settings.roaming)
                    if services.settings.roaming {
                        SliderRow(label: "Rest threshold",
                                  value: $services.settings.restThresholdHours,
                                  range: 0.5...12, step: 0.5, format: "%.1f", suffix: " h",
                                  note: "A stop this long ends the outing and becomes the next base. Package default 4 h.")
                    } else {
                        Text("Leaving the home geofence starts an outing; returning ends it. "
                             + "Set a home below, or let the first precise fix propose one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("High-accuracy GPS", isOn: $services.settings.highAccuracyGPS)
                    Text("Disables software distance thinning during transit: denser samples, "
                         + "more battery. Applies immediately, no rebuild.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Home") {
                    StateRow("home", services.tracker.location.home.map {
                        String(format: "%.4f, %.4f  r=%.0fm", $0.lat, $0.lng, $0.radius) } ?? "unset")
                    Button("Set home to current location") {
                        Task { await services.tracker.setHomeToCurrentLocation() }
                    }
                    Button("Adopt last fix as home") {
                        guard let fix = services.tracker.location.lastSample else { return }
                        services.tracker.setHome(.init(lat: fix.coordinate.latitude,
                                                       lng: fix.coordinate.longitude,
                                                       accuracy: fix.horizontalAccuracy,
                                                       radius: 75, setAt: Date()))
                    }
                    .disabled(services.tracker.location.lastSample == nil)
                }

                Section("Outing control") {
                    Button("Start manual session") {
                        Task { await services.tracker.startManualSession() }
                    }
                    Button("End current outing") {
                        Task { await services.tracker.endCurrentOutingManually() }
                    }
                    Button("Refresh tracking state") {
                        Task { await services.tracker.location.refreshTrackingState() }
                    }
                    Text("Refresh re-evaluates the rest threshold with no new sensor data — "
                         + "how a roaming stop that completed while suspended is recognized.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ActivityTracking")
        }
    }

    private func authName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when in use"
        @unknown default: return "unknown"
        }
    }
}
