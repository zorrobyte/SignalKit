import CoreLocation
import Foundation

public enum HomeDefaultPolicy {
    public static func isFreshPrecise(_ fix: CLLocation, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(fix.timestamp)
        return fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 100 && age >= -5 && age <= 15
    }
    public static func shouldSetHome(existingHome: Bool, preciseAuthorization: Bool, fix: CLLocation, now: Date = Date()) -> Bool {
        !existingHome && preciseAuthorization && isFreshPrecise(fix, now: now)
    }
}
