import CoreLocation
import CoreMotion
import Foundation
import Testing
@testable import ActivityTracking

@MainActor final class FakeMotionDriver: MotionActivityDriving {
    var available = false
    var authorizationStatus: CMAuthorizationStatus = .notDetermined
    var starts = 0, stops = 0
    var handler: (@MainActor (MotionObservation) -> Void)?
    func start(_ handler: @escaping @MainActor (MotionObservation) -> Void) { starts += 1; self.handler = handler }
    func stop() { stops += 1; handler = nil }
}

@MainActor final class FakeLocationDriver: LocationDriving {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var desiredAccuracy: CLLocationAccuracy = 0
    var activityType: CLActivityType = .other
    var pausesLocationUpdatesAutomatically = false
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    var distanceFilter: CLLocationDistance = 0
    var monitoredRegions: Set<CLRegion> = []
    var calls: [String] = []
    func requestWhenInUseAuthorization() { calls.append("whenInUse") }
    func requestAlwaysAuthorization() { calls.append("always") }
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey key: String) { calls.append("precise:" + key) }
    func requestLocation() { calls.append("fix") }
    func startMonitoringSignificantLocationChanges() { calls.append("slc.start") }
    func stopMonitoringSignificantLocationChanges() { calls.append("slc.stop") }
    func startMonitoringVisits() { calls.append("visits.start") }
    func stopMonitoringVisits() { calls.append("visits.stop") }
    func startUpdatingLocation() { calls.append("gps.start") }
    func stopUpdatingLocation() { calls.append("gps.stop") }
    func startMonitoring(for region: CLRegion) { monitoredRegions.insert(region); calls.append("arm:" + region.identifier) }
    func stopMonitoring(for region: CLRegion) { monitoredRegions.remove(region); calls.append("remove:" + region.identifier) }
    func requestState(for region: CLRegion) { calls.append("state:" + region.identifier) }
    func beginBackgroundActivity() -> () -> Void {
        calls.append("background.start")
        return { [weak self] in self?.calls.append("background.end") }
    }
}

@MainActor final class TrackingFixture {
    let suite = "SignalKitTrackingTests." + UUID().uuidString
    let stateSuite = "SignalKitStateTests." + UUID().uuidString
    let defaults: UserDefaults, stateDefaults: UserDefaults
    let radio = FakeLocationDriver(), motionDriver = FakeMotionDriver(), output = FakeBackend()
    let nativeCallbackSender = CLLocationManager()
    let coordinator: LocationCoordinator
    init(authorized: CLAuthorizationStatus = .authorizedAlways, precise: CLAccuracyAuthorization = .fullAccuracy,
         mode: TrackingMode = .homeAnchored, motionAvailable: Bool = false) {
        defaults = UserDefaults(suiteName: suite)!
        stateDefaults = UserDefaults(suiteName: stateSuite)!
        radio.authorizationStatus = authorized; radio.accuracyAuthorization = precise
        motionDriver.available = motionAvailable   // read once by MotionCoordinator.init
        coordinator = LocationCoordinator(output: output, defaults: defaults, stateDefaults: stateDefaults,
            motion: MotionCoordinator(driver: motionDriver), driver: radio, mode: mode)
    }
    func clean() {
        coordinator.stopContinuous(); coordinator.motion.stop()
        defaults.removePersistentDomain(forName: suite)
        stateDefaults.removePersistentDomain(forName: stateSuite)
    }
    func fix(lat: Double = 40, lng: Double = -86, age: Double = 0, accuracy: Double = 5,
             speed: Double = -1, verticalAccuracy: Double = -1) -> CLLocation {
        CLLocation(coordinate: .init(latitude: lat, longitude: lng), altitude: 100,
            horizontalAccuracy: accuracy, verticalAccuracy: verticalAccuracy, course: -1, speed: speed,
            timestamp: Date().addingTimeInterval(-age))
    }
    func send(_ locations: [CLLocation]) async {
        let prior = output.flushes
        coordinator.locationManager(nativeCallbackSender, didUpdateLocations: locations)
        await settle { self.output.flushes > prior }
    }
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "Delegate work should complete without a sensor or network wait")
    }
}
