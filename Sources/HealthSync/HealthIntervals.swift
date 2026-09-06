import Foundation

public enum HealthIntervals {
    // Calendar-day intersections, merged across sources and sleep stages.
    public static func minutes(_ intervals: [DateInterval], within day: DateInterval) -> Double {
        let clipped = intervals.compactMap { $0.intersection(with: day) }.sorted { $0.start < $1.start }
        var total = 0.0
        var current: DateInterval?
        for interval in clipped {
            if let prior = current {
                if interval.start <= prior.end {
                    current = DateInterval(start: prior.start, end: max(prior.end, interval.end))
                } else {
                    total += prior.duration
                    current = interval
                }
            } else { current = interval }
        }
        return (total + (current?.duration ?? 0)) / 60
    }
}
