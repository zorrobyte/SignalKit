import Foundation

/// A caller-named numeric summary. `recordedAt` is a revision timestamp in milliseconds.
public struct HealthAggregate: Codable, Equatable, Sendable {
    public let date: String
    public let type: String
    public let value: Double
    public let unit: String
    public let recordedAt: Double
    public init(date: String, type: String, value: Double, unit: String, recordedAt: Double) {
        self.date = date; self.type = type; self.value = value
        self.unit = unit; self.recordedAt = recordedAt
    }
}
