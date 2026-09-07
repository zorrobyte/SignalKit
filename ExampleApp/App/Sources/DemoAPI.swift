import Foundation
import ActivityTracking

/// The host's transport. SignalKit never imports a backend SDK, so everything
/// network-shaped lives here: two idempotent endpoints, and an error thrown on
/// anything but a 200 so the durable outboxes keep their work.
struct DemoAPI: Sendable {
    struct Rejected: LocalizedError {
        let status: Int
        var errorDescription: String? { "server returned \(status)" }
    }

    let baseURL: URL
    let account: String

    init(host: String, account: String) {
        baseURL = URL(string: "http://\(host)") ?? URL(string: "http://127.0.0.1:8787")!
        self.account = account
    }

    private func request(_ path: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 8
        return request
    }

    private func send(_ request: URLRequest) async throws {
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Returning normally is the acknowledgement SignalKit treats as "sent".
        guard status == 200 else { throw Rejected(status: status) }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws {
        try await send(request(path, body: try JSONSerialization.data(withJSONObject: body)))
    }

    /// Deduplicated by the client-generated event id, so replay is safe.
    /// `TrackingEvent` is Codable, so the module's wire shape goes out as is.
    func sendTracking(_ events: [TrackingEvent]) async throws {
        struct Envelope: Encodable { let account: String; let events: [TrackingEvent] }
        try await send(request("/v1/tracking", body: try JSONEncoder().encode(Envelope(account: account, events: events))))
    }

    /// Upserted by (account, date, type); an older recordedAt is rejected.
    func sendHealth(_ records: [[String: Any]]) async throws {
        try await post("/v1/health", ["account": account, "records": records])
    }

    /// Client-reported collection state, so it is visible in the database too.
    func sendStatus(_ status: [String: Any]) async throws {
        try await post("/v1/status", ["account": account, "status": status])
    }

    func stats() async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: "/v1/stats"))
        request.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func setServerOffline(_ offline: Bool) async throws {
        try await post("/v1/admin/offline", ["offline": offline])
    }
}
