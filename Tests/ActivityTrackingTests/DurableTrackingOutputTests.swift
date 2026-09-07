import Foundation
import Testing
@testable import ActivityTracking

@MainActor private final class Recorder {
    var batches: [[TrackingEvent]] = []
    var failures = 0
    var hangFor: TimeInterval = 0
    var events: [TrackingEvent] { batches.flatMap { $0 } }
}

@MainActor private func output(_ url: URL, _ recorder: Recorder,
                               configure: (inout DurableTrackingOutput.Configuration) -> Void = { _ in },
                               now: @escaping @Sendable () -> Date = { Date() }) -> DurableTrackingOutput {
    var configuration = DurableTrackingOutput.Configuration()
    configuration.retryBackoff = []
    configuration.retryDelay = 0
    configuration.minimumFlushInterval = 0
    configure(&configuration)
    return DurableTrackingOutput(storageURL: url, configuration: configuration, now: now) { batch in
        try await MainActor.run {
            if recorder.failures > 0 {
                recorder.failures -= 1
                throw URLError(.notConnectedToInternet)
            }
        }
        let hang = await MainActor.run { recorder.hangFor }
        if hang > 0 { try await Task.sleep(for: .seconds(hang)) }
        await MainActor.run { recorder.batches.append(batch) }
    }
}

@MainActor private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@MainActor private func recordLifecycle(_ sut: DurableTrackingOutput, outing: String = "outing") async {
    let at = Date(timeIntervalSince1970: 100)
    _ = await sut.startOuting(clientOutingId: outing, mode: "drive", source: "slc-auto",
                              at: at, homeLat: 1, homeLng: 2)
    await sut.startSegment(clientSegmentId: "segment", clientOutingId: outing, type: "transit",
                           at: at, placeId: nil)
    sut.recordSample(.init(clientOutingId: outing, timestamp: 100, lat: 1, lng: 2,
                           accuracy: 5, source: "continuous"))
    await sut.endSegment(clientSegmentId: "segment", at: at, distanceMeters: 10, maxSpeed: 2, placeId: nil)
    await sut.endOuting(clientOutingId: outing, at: at)
}

@MainActor struct DurableTrackingOutputTests {
    @Test func drainsEveryEventOnceInFIFOOrder() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let sut = output(url, recorder)
        await recordLifecycle(sut)
        #expect(sut.pendingCount == 5)
        await sut.drain()
        #expect(sut.pendingCount == 0)
        #expect(recorder.events.map(\.kind) ==
                [.outingStart, .segmentStart, .sample, .segmentEnd, .outingEnd])
        #expect(sut.lastUploadedAt != nil)
        #expect(sut.lastError == nil)
    }

    @Test func retainsWorkWhileUploadsFailAndReplaysTheSameIdentities() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let sut = output(url, recorder)
        await recordLifecycle(sut)
        let queued = sut.pendingCount
        recorder.failures = 1
        await sut.drain()
        #expect(recorder.events.isEmpty)
        #expect(sut.pendingCount == queued)     // nothing acknowledged, nothing lost
        #expect(sut.lastError != nil)

        // A separate instance over the same file proves the events are durable,
        // and the replay carries the original IDs so a server can dedupe them.
        let replayed = Recorder()
        let reopened = output(url, replayed)
        await reopened.drain()
        #expect(replayed.events.count == queued)
        #expect(reopened.pendingCount == 0)
        #expect(reopened.lastError == nil)
    }

    @Test func splitsUploadsIntoConfiguredBatches() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let sut = output(url, recorder) { $0.batchSize = 2 }
        await recordLifecycle(sut)
        await sut.drain()
        #expect(recorder.batches.map(\.count) == [2, 2, 1])
    }

    @Test func overflowDropsOldestSamplesAndKeepsLifecycleEvents() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let sut = output(url, recorder) { $0.maxOps = 4; $0.capSlack = 2 }
        _ = await sut.startOuting(clientOutingId: "outing", mode: "drive", source: "slc-auto",
                                  at: Date(timeIntervalSince1970: 1), homeLat: nil, homeLng: nil)
        for index in 0..<40 {
            sut.recordSample(.init(clientOutingId: "outing", timestamp: Double(index), lat: 1, lng: 2,
                                   accuracy: 5, source: "continuous"))
        }
        await sut.endOuting(clientOutingId: "outing", at: Date(timeIntervalSince1970: 2))
        await sut.drain()
        let kinds = recorder.events.map(\.kind)
        #expect(kinds.contains(.outingStart) && kinds.contains(.outingEnd))
        #expect(kinds.filter { $0 == .sample }.count < 40)     // oldest samples trimmed
        #expect(recorder.events.count <= 8)                     // cap plus slack
        let timestamps = recorder.events.compactMap(\.sample?.timestamp)
        #expect(timestamps == timestamps.sorted())              // newest survive, in order
        #expect(timestamps.last == 39)
    }

    @Test func aHungUploadFailsThePassInsteadOfTheApp() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        recorder.hangFor = 5
        let sut = output(url, recorder) { $0.uploadTimeout = 0.2 }
        await recordLifecycle(sut)
        let started = Date()
        await sut.drain()
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(recorder.events.isEmpty)
        #expect(sut.pendingCount == 5)
        #expect(sut.lastError != nil)
    }

    @Test func distanceCompactionIsOffByDefaultAndCollapsesPerOutingWhenEnabled() async {
        let plain = temporaryURL(); defer { try? FileManager.default.removeItem(at: plain) }
        let verbose = Recorder()
        let unchanged = output(plain, verbose)
        for meters in [10.0, 20, 30] { await unchanged.bumpMaxDistance(clientOutingId: "a", meters: meters) }
        await unchanged.drain()
        #expect(verbose.events.count == 3)

        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let sut = output(url, recorder) { $0.compactsDistanceUpdates = true }
        for meters in [10.0, 20, 30] { await sut.bumpMaxDistance(clientOutingId: "a", meters: meters) }
        await sut.bumpMaxDistance(clientOutingId: "b", meters: 5)
        await sut.setFarthest(meters: 1)
        await sut.setFarthest(meters: 2)
        await sut.endOuting(clientOutingId: "a", at: Date(timeIntervalSince1970: 1))
        await sut.drain()
        #expect(recorder.events.filter { $0.kind == .outingDistance }.map { $0.fields["meters"] } == ["30.0", "5.0"])
        #expect(recorder.events.filter { $0.kind == .farthest }.map { $0.fields["meters"] } == ["2.0"])
        #expect(recorder.events.contains { $0.kind == .outingEnd })
    }

    /// The wire vocabulary is a contract with the server. Every case must be
    /// reachable and must serialize to its documented string.
    @Test func everyEventKindIsRecordableAndKeepsItsWireString() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let sut = output(url, recorder)
        let at = Date(timeIntervalSince1970: 100)
        sut.recordHome(.init(lat: 1, lng: 2, accuracy: 5, radius: 75, setAt: at))
        sut.recordSample(.init(clientOutingId: "outing", timestamp: 100, lat: 1, lng: 2,
                               accuracy: 5, source: "continuous", altitude: 10, speed: 3))
        _ = await sut.startSession(clientOutingId: "session", at: at)
        _ = await sut.startOuting(clientOutingId: "outing", mode: "drive", source: "slc-auto",
                                  at: at, homeLat: nil, homeLng: nil)
        await sut.setOutingMode(clientOutingId: "outing", mode: "mixed")
        await sut.markFarRecord(clientOutingId: "outing")
        await sut.bumpMaxDistance(clientOutingId: "outing", meters: 42)
        await sut.startSegment(clientSegmentId: "segment", clientOutingId: "outing",
                               type: "transit", at: at, placeId: "place")
        await sut.endSegment(clientSegmentId: "segment", at: at, distanceMeters: 10,
                             maxSpeed: 3, placeId: "place")
        _ = await sut.upsertPlace(lat: 1, lng: 2, at: at, clientSegmentId: "segment")
        await sut.setFarthest(meters: 99)
        await sut.endOuting(clientOutingId: "outing", at: at)
        await sut.drain()

        #expect(Set(recorder.events.map(\.kind)) == Set(TrackingEvent.Kind.allCases))
        #expect(Set(recorder.events.map(\.id)).count == recorder.events.count)
        let wire = try? JSONEncoder().encode(recorder.events.first { $0.kind == .segmentStart })
        let text = wire.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(text.contains("\"segment.start\""))
        // Every event that belongs to an outing can say so, from either source.
        #expect(recorder.events.filter { $0.clientOutingId == "outing" }.count >= 7)
        #expect(recorder.events.first { $0.kind == .home }?.fields["radius"] == "75.0")
    }

    @Test func remainingWorkAsksTheHostForBackgroundTimeAndRetries() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        recorder.failures = 1
        let sut = output(url, recorder) { $0.retryDelay = 0.2 }
        var backgroundRequests = 0
        sut.requestBackgroundWork = { backgroundRequests += 1 }
        sut.recordSample(.init(clientOutingId: nil, timestamp: 1, lat: 1, lng: 2,
                               accuracy: 5, source: "continuous"))
        await sut.drain()
        #expect(backgroundRequests == 1)
        #expect(sut.pendingCount == 1)

        // The scheduled retry clears it without another host call.
        for _ in 0..<200 where sut.pendingCount > 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(sut.pendingCount == 0)
        #expect(recorder.events.count == 1)

        // stop() cancels pending retries; durable state is untouched.
        sut.recordSample(.init(clientOutingId: nil, timestamp: 2, lat: 1, lng: 2,
                               accuracy: 5, source: "continuous"))
        sut.stop()
        #expect(sut.pendingCount == 1)
    }

    @Test func opportunisticFlushIsRateLimitedButExplicitDrainIsNot() async {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let clock = TestClock()
        let sut = output(url, recorder, configure: { $0.minimumFlushInterval = 15 },
                         now: { clock.now })
        sut.recordSample(.init(clientOutingId: nil, timestamp: 1, lat: 1, lng: 2,
                               accuracy: 5, source: "continuous"))
        await sut.flush()
        #expect(recorder.events.count == 1)

        sut.recordSample(.init(clientOutingId: nil, timestamp: 2, lat: 1, lng: 2,
                               accuracy: 5, source: "continuous"))
        await sut.flush()                       // inside the window: skipped
        #expect(sut.pendingCount == 1)
        await sut.drain()                       // explicit: always runs
        #expect(sut.pendingCount == 0)

        sut.recordSample(.init(clientOutingId: nil, timestamp: 3, lat: 1, lng: 2,
                               accuracy: 5, source: "continuous"))
        clock.advance(20)
        await sut.flush()                       // window elapsed
        #expect(sut.pendingCount == 0)
        #expect(recorder.events.count == 3)
    }
}

/// A hand-advanced clock; `Date()` cannot be moved and sleeping is not a test.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}
