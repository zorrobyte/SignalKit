import Foundation

public struct HealthWindow: Sendable {
    public let days: Int
    public init(days: Int = 7) { precondition(days > 0 && days <= 365); self.days = days }
    public func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now))!
    }
    public func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public func contains(_ date: String, now: Date = Date()) -> Bool {
        date >= dateKey(start(now: now)) && date <= dateKey(now)
    }
}

// Anchor, UUID-to-day mapping, and pending reconciliation are committed together.
// No Health values are cached here. An empty read alone never authorizes a zero.
@MainActor
public final class HealthChangeJournal {
    public struct Footprint: Codable, Equatable {
        public init(id: String, dates: [String]) { self.id = id; self.dates = dates }
        let id: String
        let dates: [String]
    }
    struct Cursor: Codable {
        var anchor: Data?
        var samples: [String: [String]] = [:]
        var caughtUp = false
    }
    struct State: Codable {
        var windowStart: String?
        var cursors: [String: Cursor] = [:]
        var dirtyDates: Set<String> = []
        var deletionEvidence: Set<String> = []
    }
    private let url: URL
    private var state: State?
    public init(url: URL) { self.url = url }
    private func load() throws -> State {
        if let state { return state }
        let loaded = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
        state = loaded
        return loaded
    }
    private func save(_ next: State) throws {
        try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = next
    }
    public func anchor(for type: String) throws -> Data? { try load().cursors[type]?.anchor }
    public func pendingDates() throws -> [String] { try load().dirtyDates.sorted() }
    public func hasMoreChanges() throws -> Bool { try load().cursors.values.contains { !$0.caughtUp } }
    public func isCaughtUp(type: String) throws -> Bool { try load().cursors[type]?.caughtUp ?? false }
    // Anchors belong to a fixed predicate. Reset them when the rolling window
    // changes, retaining recent UUIDs so deletions still have evidence.
    public func prepareWindow(start: String, end: String) throws {
        var next = try load()
        let changed = next.windowStart != start
        for type in Array(next.cursors.keys) {
            var cursor = next.cursors[type]!
            cursor.samples = cursor.samples.compactMapValues { dates in
                let kept = dates.filter { $0 >= start && $0 <= end }
                return kept.isEmpty ? nil : kept
            }
            if changed { cursor.anchor = nil; cursor.caughtUp = false }
            next.cursors[type] = cursor
        }
        next.dirtyDates = next.dirtyDates.filter { $0 >= start && $0 <= end }
        next.deletionEvidence = next.deletionEvidence.filter {
            guard let date = $0.split(separator: "|").last else { return false }
            return String(date) >= start && String(date) <= end
        }
        next.windowStart = start
        try save(next)
    }
    public func apply(type: String, anchor: Data, added: [Footprint], deleted: [String], caughtUp: Bool) throws {
        var next = try load()
        var cursor = next.cursors[type] ?? Cursor()
        for sample in added {
            next.dirtyDates.formUnion(cursor.samples[sample.id] ?? [])
            cursor.samples[sample.id] = sample.dates
            next.dirtyDates.formUnion(sample.dates)
        }
        for id in deleted {
            // Unknown UUIDs cannot justify clearing an aggregate.
            for date in cursor.samples.removeValue(forKey: id) ?? [] {
                next.dirtyDates.insert(date)
                next.deletionEvidence.insert(type + "|" + date)
            }
        }
        cursor.anchor = anchor
        cursor.caughtUp = caughtUp
        next.cursors[type] = cursor
        try save(next)
    }
    public func canClearEmpty(type: String, date: String) throws -> Bool {
        let state = try load()
        guard let cursor = state.cursors[type], cursor.caughtUp,
              state.deletionEvidence.contains(type + "|" + date) else { return false }
        return !cursor.samples.values.contains { $0.contains(date) }
    }
    public func acknowledge(date: String) throws {
        var next = try load()
        next.dirtyDates.remove(date)
        next.deletionEvidence = next.deletionEvidence.filter { !$0.hasSuffix("|" + date) }
        try save(next)
    }

    public func revisitKnownDates() throws {
        var next = try load()
        for cursor in next.cursors.values {
            for dates in cursor.samples.values { next.dirtyDates.formUnion(dates) }
        }
        try save(next)
    }
}
