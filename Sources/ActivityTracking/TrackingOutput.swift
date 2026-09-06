import Foundation

/// A retained GPS or visit observation. Coordinates and distances remain SI units.
public struct LocationSample: Codable, Sendable, Equatable {
    public let clientOutingId: String?
    public let timestamp: Double
    public let lat: Double
    public let lng: Double
    public let accuracy: Double
    public let source: String
    public let altitude: Double?
    public let speed: Double?
    public init(clientOutingId: String?, timestamp: Double, lat: Double, lng: Double,
                accuracy: Double, source: String, altitude: Double? = nil, speed: Double? = nil) {
        self.clientOutingId = clientOutingId; self.timestamp = timestamp
        self.lat = lat; self.lng = lng; self.accuracy = accuracy
        self.source = source; self.altitude = altitude; self.speed = speed
    }
}

/// Supply a durable local sink. These calls must not wait for connectivity.
/// `flush` is an opportunity to upload; keep it bounded during background wakes.
@MainActor
public protocol TrackingOutput: ActivityBackend {
    func recordSample(_ sample: LocationSample)
    func recordHome(_ home: LocationCoordinator.HomeLocation)
    func flush() async
}
