import Foundation
import ActivityTracking
import DurableSync

/// An intentionally simple, backend-neutral wire format. Keep event IDs stable
/// across retries and deduplicate them on your server before applying effects.
public struct TrackingEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: String
    public let fields: [String: String]
    public let sample: LocationSample?
}

/// Retain one instance per account. The transport must throw on a failed ACK.
/// This example preserves every event; production hosts can add a documented
/// sample-only retention policy without discarding lifecycle events.
@MainActor public final class OfflineTrackingOutput: TrackingOutput {
    public let queue: DurableWriteLog<TrackingEvent>
    private let send: @Sendable (TrackingEvent) async throws -> Void

    public init(storageURL: URL, send: @escaping @Sendable (TrackingEvent) async throws -> Void) {
        queue = DurableWriteLog(storageURL: storageURL)
        self.send = send
    }

    private func append(_ kind: String, _ fields: [String: String], sample: LocationSample? = nil) {
        queue.enqueue(TrackingEvent(id: UUID(), kind: kind, fields: fields, sample: sample))
    }

    public func recordSample(_ sample: LocationSample) { append("sample", [:], sample: sample) }
    public func recordHome(_ home: LocationCoordinator.HomeLocation) {
        append("home", ["lat": String(home.lat), "lng": String(home.lng)])
    }
    public func flush() async { await queue.drainAll(execute: send) }
    public func startSession(clientOutingId: String, at: Date) async -> String? {
        append("session.start", ["outing": clientOutingId, "at": String(at.timeIntervalSince1970)])
        return nil // No server identifier is available offline.
    }
    public func startOuting(clientOutingId: String, mode: String, source: String, at: Date, homeLat: Double?, homeLng: Double?) async -> String? {
        var fields = ["outing": clientOutingId, "mode": mode, "source": source, "at": String(at.timeIntervalSince1970)]
        if let homeLat { fields["homeLat"] = String(homeLat) }
        if let homeLng { fields["homeLng"] = String(homeLng) }
        append("outing.start", fields)
        return nil
    }
    public func endOuting(clientOutingId: String, at: Date) async {
        append("outing.end", ["outing": clientOutingId, "at": String(at.timeIntervalSince1970)])
    }
    public func setOutingMode(clientOutingId: String, mode: String) async {
        append("outing.mode", ["outing": clientOutingId, "mode": mode])
    }
    public func markFarRecord(clientOutingId: String) async { append("outing.record", ["outing": clientOutingId]) }
    public func bumpMaxDistance(clientOutingId: String, meters: Double) async {
        append("outing.distance", ["outing": clientOutingId, "meters": String(meters)])
    }
    public func startSegment(clientSegmentId: String, clientOutingId: String, type: String, at: Date, placeId: String?) async {
        var fields = ["segment": clientSegmentId, "outing": clientOutingId, "type": type, "at": String(at.timeIntervalSince1970)]
        fields["place"] = placeId
        append("segment.start", fields)
    }
    public func endSegment(clientSegmentId: String, at: Date, distanceMeters: Double, maxSpeed: Double, placeId: String?) async {
        var fields = ["segment": clientSegmentId, "at": String(at.timeIntervalSince1970), "meters": String(distanceMeters), "maxSpeed": String(maxSpeed)]
        fields["place"] = placeId
        append("segment.end", fields)
    }
    public func upsertPlace(lat: Double, lng: Double, at: Date, clientSegmentId: String) async -> String? {
        append("place.upsert", ["lat": String(lat), "lng": String(lng), "at": String(at.timeIntervalSince1970), "segment": clientSegmentId])
        return nil // The server must link its resolved place using the segment ID.
    }
    public func setFarthest(meters: Double) async { append("farthest", ["meters": String(meters)]) }
}
