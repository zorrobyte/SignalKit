import CoreLocation

/// Injectable radio boundary. Implementations must deliver native delegate
/// callbacks using the same semantics as CLLocationManager.
@MainActor public protocol LocationDriving: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var activityType: CLActivityType { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    var distanceFilter: CLLocationDistance { get set }
    var monitoredRegions: Set<CLRegion> { get }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey: String)
    func requestLocation()
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
    func startMonitoringVisits()
    func stopMonitoringVisits()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startMonitoring(for: CLRegion)
    func stopMonitoring(for: CLRegion)
    func requestState(for: CLRegion)
    /// Begins background activity and returns the matching invalidation action.
    func beginBackgroundActivity() -> () -> Void
}

/// Production adapter. Sensor behavior remains owned by CoreLocation.
@MainActor public final class CoreLocationDriver: LocationDriving {
    private let manager = CLLocationManager()
    public init() {}
    public var delegate: CLLocationManagerDelegate? { get { manager.delegate } set { manager.delegate = newValue } }
    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    public var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }
    public var desiredAccuracy: CLLocationAccuracy { get { manager.desiredAccuracy } set { manager.desiredAccuracy = newValue } }
    public var activityType: CLActivityType { get { manager.activityType } set { manager.activityType = newValue } }
    public var pausesLocationUpdatesAutomatically: Bool { get { manager.pausesLocationUpdatesAutomatically } set { manager.pausesLocationUpdatesAutomatically = newValue } }
    public var allowsBackgroundLocationUpdates: Bool { get { manager.allowsBackgroundLocationUpdates } set { manager.allowsBackgroundLocationUpdates = newValue } }
    public var showsBackgroundLocationIndicator: Bool { get { manager.showsBackgroundLocationIndicator } set { manager.showsBackgroundLocationIndicator = newValue } }
    public var distanceFilter: CLLocationDistance { get { manager.distanceFilter } set { manager.distanceFilter = newValue } }
    public var monitoredRegions: Set<CLRegion> { manager.monitoredRegions }
    public func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    public func requestAlwaysAuthorization() { manager.requestAlwaysAuthorization() }
    public func requestTemporaryFullAccuracyAuthorization(withPurposeKey key: String) { manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: key) }
    public func requestLocation() { manager.requestLocation() }
    public func startMonitoringSignificantLocationChanges() { manager.startMonitoringSignificantLocationChanges() }
    public func stopMonitoringSignificantLocationChanges() { manager.stopMonitoringSignificantLocationChanges() }
    public func startMonitoringVisits() { manager.startMonitoringVisits() }
    public func stopMonitoringVisits() { manager.stopMonitoringVisits() }
    public func startUpdatingLocation() { manager.startUpdatingLocation() }
    public func stopUpdatingLocation() { manager.stopUpdatingLocation() }
    public func startMonitoring(for region: CLRegion) { manager.startMonitoring(for: region) }
    public func stopMonitoring(for region: CLRegion) { manager.stopMonitoring(for: region) }
    public func requestState(for region: CLRegion) { manager.requestState(for: region) }
    public func beginBackgroundActivity() -> () -> Void {
        let session = CLBackgroundActivitySession()
        return { session.invalidate() }
    }
}
