import CoreLocation
import CoreMotion
import Foundation
import Testing
@testable import ActivityTracking

@MainActor struct MotionAndPolicyTests {
    @Test func motionAvailabilityLifecycleAndNoiseFiltering() {
        let source = FakeMotionDriver(), coordinator = MotionCoordinator(driver: FakeMotionDriver())
        coordinator.start(); #expect(!coordinator.isActive)
        source.available = true; source.authorizationStatus = .authorized
        let motion = MotionCoordinator(driver: source)
        var emitted: [MotionCoordinator.MotionState] = []
        motion.onChange = { emitted.append($0); _ = $1 }
        motion.start(); motion.start(); #expect(source.starts == 1)
        source.handler?(.init(walking: true, confidence: .low, startDate: Date()))
        #expect(motion.state == .walking && emitted.isEmpty && motion.confidenceName == "low")
        source.handler?(.init(walking: true, automotive: true, confidence: .high, startDate: Date()))
        source.handler?(.init(walking: true, confidence: .medium, startDate: Date()))
        #expect(emitted == [.walking] && motion.liveActivityLabel == "Walking")
        source.handler?(.init(confidence: .high, startDate: Date()))
        #expect(emitted == [.walking] && motion.liveActivityLabel == nil)
        for value in [MotionObservation(running: true, confidence: .high, startDate: Date()),
                      .init(cycling: true, confidence: .high, startDate: Date()),
                      .init(automotive: true, confidence: .high, startDate: Date()),
                      .init(stationary: true, confidence: .high, startDate: Date())] { source.handler?(value) }
        #expect(emitted == [.walking, .running, .cycling, .automotive, .stationary])
        #expect(motion.authStatusName == "authorized" && motion.confidenceName == "high")
        motion.stop(); motion.stop(); #expect(source.stops == 1 && !motion.isActive)
        for state in [MotionCoordinator.MotionState.walking, .running, .cycling, .automotive, .stationary, .unknown] {
            #expect(!state.label.isEmpty && !state.symbolName.isEmpty)
        }
    }
    @Test func allAppleFlagsAndCombinationsRemainAvailable() {
        let source = FakeMotionDriver()
        source.available = true
        let motion = MotionCoordinator(driver: source)
        #expect(motion.latestObservation == nil && motion.confirmedState == nil)
        var observations: [MotionObservation] = []
        motion.onObservation = { observation in
            #expect(motion.latestObservation == observation)
            #expect(motion.updatedAt == observation.startDate)
            #expect(motion.confidence == observation.confidence)
            observations.append(observation)
        }
        motion.start()
        // All 64 combinations, including explicit unknown and no asserted flags.
        for mask in 0..<64 {
            let observation = MotionObservation(
                walking: mask & 1 != 0, running: mask & 2 != 0,
                cycling: mask & 4 != 0, automotive: mask & 8 != 0,
                stationary: mask & 16 != 0, unknown: mask & 32 != 0,
                confidence: .high, startDate: Date(timeIntervalSince1970: Double(mask)))
            source.handler?(observation)
            #expect(observations.last == observation)
            let expected: MotionCoordinator.MotionState = observation.walking ? .walking
                : observation.running ? .running : observation.cycling ? .cycling
                : observation.automotive ? .automotive : observation.stationary ? .stationary : .unknown
            #expect(motion.state == expected)
        }
        #expect(observations.count == 64)
        motion.stop()
    }

    @Test func stoppedVehicleAndUncertainUpdatesDoNotReplaceConfirmedActivity() {
        let source = FakeMotionDriver()
        source.available = true
        let motion = MotionCoordinator(driver: source)
        var changes: [MotionCoordinator.MotionState] = []
        var observations: [MotionObservation] = []
        motion.onChange = { state, _ in changes.append(state) }
        motion.onObservation = { observations.append($0) }
        motion.start()
        source.handler?(.init(automotive: true, confidence: .high, startDate: Date()))
        source.handler?(.init(automotive: true, stationary: true, confidence: .high, startDate: Date()))
        #expect(motion.latestObservation?.stationary == true)
        #expect(motion.latestObservation?.automotive == true)
        #expect(motion.confirmedState == .automotive && changes == [.automotive])
        source.handler?(.init(walking: true, confidence: .low, startDate: Date()))
        #expect(motion.state == .walking && motion.confirmedState == .automotive)
        source.handler?(.init(unknown: true, confidence: .high, startDate: Date()))
        #expect(motion.state == .unknown && motion.confirmedState == .automotive)
        #expect(motion.latestObservation?.unknown == true)
        source.handler?(.init(confidence: .high, startDate: Date()))
        #expect(motion.state == .unknown && motion.latestObservation?.unknown == false)
        #expect(changes == [.automotive] && observations.count == 5)
        source.handler?(.init(walking: true, confidence: .medium, startDate: Date()))
        #expect(motion.confirmedState == .walking && changes == [.automotive, .walking])
        motion.stop()
    }

    @Test func samplingPolicyCoversMotionAndSpeedBoundaries() {
        #expect(SamplingPolicy.decide(regime: .automotive, speed: nil).distanceFilter == 60)
        #expect(SamplingPolicy.decide(regime: .automotive, speed: 1).distanceFilter == 50)
        #expect(SamplingPolicy.decide(regime: .automotive, speed: 100).distanceFilter == 120)
        #expect(SamplingPolicy.decide(regime: .automotive, speed: 30).accuracy == kCLLocationAccuracyHundredMeters)
        #expect(SamplingPolicy.decide(regime: .cycling, speed: nil).activityType == .fitness)
        #expect(SamplingPolicy.decide(regime: .walking, speed: nil).distanceFilter == 10)
    }
    @Test func homePolicyBoundariesAndStoredStateRecovery() throws {
        let f = TrackingFixture(); defer { f.clean() }
        let now = Date()
        func fix(_ age: Double, _ accuracy: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 40, longitude: -86), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        for (age, accuracy, valid) in [(15.0, 100.0, true), (15.1, 100, false), (-5, 0, true), (-5.1, 5, false), (0, -1, false)] {
            #expect(HomeDefaultPolicy.isFreshPrecise(fix(age, accuracy), now: now) == valid)
        }
        #expect(!HomeDefaultPolicy.shouldSetHome(existingHome: true, preciseAuthorization: true, fix: fix(0, 5), now: now))
        #expect(!HomeDefaultPolicy.shouldSetHome(existingHome: false, preciseAuthorization: false, fix: fix(0, 5), now: now))
        let store = EngineStateStore(defaults: f.stateDefaults)
        #expect(store.load() == EngineState())
        f.stateDefaults.set(Data([0xff]), forKey: "activityEngine.state.v2")
        #expect(store.load() == EngineState())
        var state = EngineState(); state.phase = .transit; state.lastPersonalRecord = 500
        store.save(state)
        #expect(store.load().phase == .atHome && store.load().lastPersonalRecord == 500)
        state.clientOutingId = "stable"; state.outingStartedAt = now; store.save(state)
        #expect(store.load() == state)
    }
}
