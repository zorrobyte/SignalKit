import Foundation

/// A retained GPS or visit observation. Coordinates and distances remain SI units.
public struct LocationSample: Codable, Sendable, Equatable {
    public let clientOutingId: String?
    public let timestamp: Double
    public let lat: Double
    public let lng: Double
    public let accuracy: Double
    /// Whether Core Location granted full-accuracy coordinates when this
    /// observation was produced. `accuracy` still carries the reported radius;
    /// consumers need both values because reduced authorization must never be
    /// mistaken for precise route evidence.
    public let hasFullAccuracyAuthorization: Bool
    public let source: String
    public let altitude: Double?
    public let speed: Double?
    /// Original paired CLVisit endpoints in Unix milliseconds. Present together only
    /// on a completed native visit, never on inferred engine/foreground closures.
    public let nativeVisitArrivalTimestamp: Double?
    public let nativeVisitDepartureTimestamp: Double?
    public init(clientOutingId: String?, timestamp: Double, lat: Double, lng: Double,
                accuracy: Double, source: String, altitude: Double? = nil, speed: Double? = nil,
                hasFullAccuracyAuthorization: Bool = true,
                nativeVisitArrivalTimestamp: Double? = nil, nativeVisitDepartureTimestamp: Double? = nil) {
        self.clientOutingId = clientOutingId; self.timestamp = timestamp
        self.lat = lat; self.lng = lng; self.accuracy = accuracy
        self.hasFullAccuracyAuthorization = hasFullAccuracyAuthorization
        self.source = source; self.altitude = altitude; self.speed = speed
        self.nativeVisitArrivalTimestamp = nativeVisitArrivalTimestamp
        self.nativeVisitDepartureTimestamp = nativeVisitDepartureTimestamp
    }

    private enum CodingKeys: String, CodingKey {
        case clientOutingId
        case timestamp
        case lat
        case lng
        case accuracy
        case hasFullAccuracyAuthorization
        case source
        case altitude
        case speed
        case nativeVisitArrivalTimestamp, nativeVisitDepartureTimestamp
    }

    /// Samples written before authorization fidelity was retained came from
    /// SignalKit's old <=100 m full-accuracy gate, so treating those as full
    /// accuracy preserves their original meaning.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientOutingId = try container.decodeIfPresent(String.self, forKey: .clientOutingId)
        timestamp = try container.decode(Double.self, forKey: .timestamp)
        lat = try container.decode(Double.self, forKey: .lat)
        lng = try container.decode(Double.self, forKey: .lng)
        accuracy = try container.decode(Double.self, forKey: .accuracy)
        hasFullAccuracyAuthorization = try container.decodeIfPresent(Bool.self, forKey: .hasFullAccuracyAuthorization) ?? true
        source = try container.decode(String.self, forKey: .source)
        altitude = try container.decodeIfPresent(Double.self, forKey: .altitude)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        nativeVisitArrivalTimestamp = try container.decodeIfPresent(Double.self, forKey: .nativeVisitArrivalTimestamp)
        nativeVisitDepartureTimestamp = try container.decodeIfPresent(Double.self, forKey: .nativeVisitDepartureTimestamp)
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
