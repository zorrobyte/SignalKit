import Foundation
import Testing
import ActivityTracking
import SignalKitExamples

@MainActor struct ExampleTests {
    @Test func trackingExampleQueuesLifecycleDurablyAndReplaysAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "ExampleTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let received = Events()
        let tracker = makeActivityTracker(directory: directory, defaults: defaults) { batch in
            await received.append(batch)
        }
        defer { tracker.stop() }
        let at = Date(timeIntervalSince1970: 100)
        _ = await tracker.output.startOuting(clientOutingId: "outing", mode: "drive",
                                             source: "slc-auto", at: at, homeLat: 1, homeLng: 2)
        tracker.output.recordSample(.init(clientOutingId: "outing", timestamp: 100, lat: 1, lng: 2,
                                          accuracy: 5, source: "continuous"))
        await tracker.output.endOuting(clientOutingId: "outing", at: at)
        #expect(tracker.pendingUploads == 3)

        await tracker.drainUploads()
        #expect(tracker.pendingUploads == 0)
        let delivered = await received.values
        #expect(delivered.map(\.kind) == [.outingStart, .sample, .outingEnd])
        #expect(Set(delivered.map(\.id)).count == 3)
        #expect(tracker.lastUploadError == nil)
        #expect(tracker.storageError == nil)
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
    func append(_ batch: [TrackingEvent]) { values.append(contentsOf: batch) }
}
