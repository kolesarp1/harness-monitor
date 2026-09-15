import Foundation

// Cursor's dashboard RPC — the only place Cursor exposes usage. A Connect-RPC style POST with an
// empty JSON object body; all three headers are required.
//
// Only the current-period call is implemented. openusage additionally carries a cookie-based REST
// fallback, a credits endpoint, and team-account dollar rendering; those serve account shapes outside
// what this widget draws.
public enum CursorUsageClient {
    static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    public enum Outcome: Sendable {
        case ok(UsageSnapshot)
        // A 200 that parsed but has nothing to meter: the account's usage is disabled, or its billing
        // cycle has ended. Filing it as `.failed` reported a working endpoint as a network failure.
        case empty
        case unauthorized  // 401 — the stored token is stale; Cursor refreshes it on its own
        case rateLimited(retryAfter: Date?)  // 429
        case failed  // any other status, or a transport error
    }

    public static func fetch(token: String, session: URLSession, now: Date) async -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return .failed }

        switch http.statusCode {
        case 200:
            switch CursorUsageLogic.reading(from: data, now: now) {
            case .usage(let snapshot): return .ok(snapshot)
            case .nothingToReport: return .empty
            case .undecodable: return .failed
            }
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited(retryAfter: UsageEndpoint.retryAfter(from: http, now: now))
        default:
            return .failed
        }
    }
}
