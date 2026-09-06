import Foundation
import Testing
import ActivityTracking
import SignalKitExamples

@MainActor struct ExampleTests {
    @Test func offlineLifecycleReopensAndUploadsInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let first = OfflineTrackingOutput(storageURL: url) { _ in throw URLError(.notConnectedToInternet) }
        let at = Date(timeIntervalSince1970: 100)
        _ = await first.startOuting(clientOutingId: "outing", mode: "walking", source: "gps", at: at, homeLat: 1, homeLng: 2)
        _ = await first.startSession(clientOutingId: "session", at: at)
        await first.setOutingMode(clientOutingId: "outing", mode: "automotive")
        await first.markFarRecord(clientOutingId: "outing")
        await first.bumpMaxDistance(clientOutingId: "outing", meters: 123)
        await first.startSegment(clientSegmentId: "segment", clientOutingId: "outing", type: "travel", at: at, placeId: nil)
        await first.endSegment(clientSegmentId: "segment", at: at, distanceMeters: 123, maxSpeed: 5, placeId: "place")
        _ = await first.upsertPlace(lat: 1, lng: 2, at: at, clientSegmentId: "segment")
        await first.setFarthest(meters: 123)
        first.recordHome(.init(lat: 1, lng: 2, accuracy: 5, radius: 100, setAt: at))
        first.recordSample(.init(clientOutingId: "outing", timestamp: 100, lat: 1, lng: 2, accuracy: 5, source: "gps"))
        await first.endOuting(clientOutingId: "outing", at: at)
        let saved = first.queue.load()
        #expect(saved.count == 12 && Set(saved.map(\.id)).count == 12)
        let received = Events()
        let reopened = OfflineTrackingOutput(storageURL: url) { await received.append($0) }
        #expect(reopened.queue.load() == saved)
        await reopened.flush()
        #expect(await received.values == saved)
        #expect(reopened.queue.pendingCount == 0)
    }

    @Test func healthExampleConstructsWithoutRequestingPermission() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "ExampleTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let sync = makeHealthSync(directory: directory, defaults: defaults) { _ in }
        #expect(sync.pendingWrites == 0)
        #expect(!defaults.bool(forKey: "health.authorizationRequested"))
        sync.stop()
    }
}

private actor Events {
    var values: [TrackingEvent] = []
    func append(_ event: TrackingEvent) { values.append(event) }
}
