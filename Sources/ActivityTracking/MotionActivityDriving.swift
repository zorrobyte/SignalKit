import CoreMotion
import Foundation

/// Value snapshot of Apple's possibly overlapping motion classifications.
public struct MotionObservation: Sendable, Equatable {
    public var walking, running, cycling, automotive, stationary, unknown: Bool
    public var confidence: CMMotionActivityConfidence
    public var startDate: Date
    public init(walking: Bool = false, running: Bool = false, cycling: Bool = false,
                automotive: Bool = false, stationary: Bool = false, unknown: Bool = false,
                confidence: CMMotionActivityConfidence, startDate: Date) {
        self.walking = walking; self.running = running; self.cycling = cycling
        self.automotive = automotive; self.stationary = stationary; self.unknown = unknown
        self.confidence = confidence; self.startDate = startDate
    }
}

@MainActor public protocol MotionActivityDriving: AnyObject {
    var available: Bool { get }
    var authorizationStatus: CMAuthorizationStatus { get }
    func start(_ handler: @escaping @MainActor (MotionObservation) -> Void)
    func stop()
}

@MainActor public final class CoreMotionDriver: MotionActivityDriving {
    private let manager = CMMotionActivityManager()
    public init() {}
    public var available: Bool { CMMotionActivityManager.isActivityAvailable() }
    public var authorizationStatus: CMAuthorizationStatus { CMMotionActivityManager.authorizationStatus() }
    public func start(_ handler: @escaping @MainActor (MotionObservation) -> Void) {
        manager.startActivityUpdates(to: .main) { activity in
            guard let a = activity else { return }
            MainActor.assumeIsolated {
                handler(MotionObservation(walking: a.walking, running: a.running, cycling: a.cycling,
                    automotive: a.automotive, stationary: a.stationary, unknown: a.unknown, confidence: a.confidence, startDate: a.startDate))
            }
        }
    }
    public func stop() { manager.stopActivityUpdates() }
}
