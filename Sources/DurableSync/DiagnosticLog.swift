import Foundation

/// Optional local diagnostics. SignalKit never transmits logs itself.
public struct DiagnosticLog: Sendable {
    private let handler: @Sendable @MainActor (String, String) -> Void
    public init(_ handler: @escaping @Sendable @MainActor (String, String) -> Void = { _, _ in }) {
        self.handler = handler
    }
    @MainActor public func record(_ event: String, _ detail: String = "") { handler(event, detail) }
}
