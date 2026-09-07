import Foundation

/// A retained diagnostic target whose handler can be set after construction.
///
/// `DiagnosticLog` takes its handler at initialization, but a host usually wants
/// the sink to be its own composition root — which does not exist yet while the
/// coordinators that need the log are still being constructed. Hold a sink,
/// hand `log` to the coordinators, and set `handler` once `self` is available.
///
/// ```swift
/// let sink = DiagnosticSink()
/// let coordinator = LocationCoordinator(..., log: sink.log)
/// sink.handler = { [weak self] event, detail in self?.record(event, detail) }
/// ```
///
/// The handler is invoked on the main actor. A nil handler discards events, so
/// events recorded before the host attaches are dropped rather than buffered.
@MainActor
public final class DiagnosticSink {
    public init() {}

    /// Receives `(event, detail)` pairs. Keep it fast; never upload from here.
    public var handler: ((String, String) -> Void)?

    /// A log that forwards to whatever `handler` holds at the time of the call.
    public var log: DiagnosticLog {
        DiagnosticLog { [weak self] event, detail in self?.handler?(event, detail) }
    }
}
