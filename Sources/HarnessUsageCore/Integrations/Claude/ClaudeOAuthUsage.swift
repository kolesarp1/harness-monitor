import Foundation

// Claude's real 5h/7-day meters from the OAuth usage endpoint. Read-only: the token comes from
// `ClaudeCredentials` and is never refreshed or written back.
//
// The endpoint uses `utilization` and an ISO-8601 STRING for `resets_at`. Keeping those details here
// avoids treating its response like a local usage record.
public enum ClaudeOAuthUsage {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.69"

    // Named `Outcome`, not `Result`: a nested `Result` shadows `Swift.Result` for the whole file.
    public enum Outcome: Sendable {
        case ok(UsageSnapshot)
        case unauthorized(status: Int)  // 401/403 — the token is expired, rejected, or server-side blocked
        case rateLimited(retryAfter: Date?)  // 429
        case failed  // any other status, or a transport error
    }

    public static func fetch(token: ClaudeCredentials.Token, session: URLSession, now: Date) async -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return .failed }

        switch http.statusCode {
        case 200:
            guard var snapshot = parse(data, now: now) else { return .failed }
            snapshot.accountEmail = token.accountEmail
            return .ok(snapshot)
        // 403 is the documented server-side block on third-party use of a consumer OAuth token, and it
        // is permanent for this login — filing it as `.failed` would retry it every 300s forever. Same
        // mapping as the Codex client (ref: CodexBar's fetcher maps both).
        case 401, 403:
            return .unauthorized(status: http.statusCode)
        case 429:
            return .rateLimited(retryAfter: UsageEndpoint.retryAfter(from: http, now: now))
        default:
            return .failed
        }
    }

    private struct Response: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    // One entry of the `limits` array: the account's caps, restated as a flat list. Most of them
    // duplicate `five_hour`/`seven_day` (`kind: "session"`, `kind: "weekly_all"`); the ones that do
    // not are scoped to a single model via `scope.model` — a promotional weekly cap on "Fable", say —
    // and those are the only rows this endpoint reports nowhere else. `scope.model.id` is the stable
    // identity when present; `display_name` is what the user reads.
    private struct Limit: Decodable {
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        enum CodingKeys: String, CodingKey {
            case percent
            case resetsAt = "resets_at"
            case scope
        }
        struct Scope: Decodable {
            let model: Model?
            struct Model: Decodable {
                let id: String?
                let displayName: String?
                enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                }
            }
        }
    }

    /// The remote probe's entry point — the same decoder the local tier uses, so an account read
    /// over ssh builds its windows through exactly the code that builds a local one's.
    public static func snapshot(fromResponseData data: Data, now: Date) -> UsageSnapshot? {
        parse(data, now: now)
    }

    // nil when neither window parses. The caller then falls through to the local token estimate.
    public static func parse(_ data: Data, now: Date) -> UsageSnapshot? {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        var windows: [UsageWindow] = []
        if let session = window(
            decoded.fiveHour, id: "5h", title: "Session", period: 5 * 3_600,
            kind: .account, now: now
        ) {
            windows.append(session)
        }
        if let week = window(
            decoded.sevenDay, id: "7d", title: "Weekly", period: 7 * 86_400,
            kind: .account, now: now
        ) {
            windows.append(week)
        }
        windows.append(contentsOf: extras(decoded.limits, now: now))
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(
            windows: windows, localTokensToday: nil, localTokensWeek: nil,
            source: .claudeOAuth, lastUpdated: now)
    }

    // The model-scoped limits, in the order the endpoint lists them. Selection is by scope, not by the
    // entries' own `is_active` flag: on this account the live payload marks the account session limit
    // active and the real "Fable" cap inactive, so `is_active` reads as "the limit currently binding",
    // not "the limit exists" — filtering on it would drop the one row worth adding and keep a
    // duplicate of Session. An unscoped entry is always a restatement of a window we already show.
    private static func extras(_ limits: [Limit]?, now: Date) -> [UsageWindow] {
        guard let limits else { return [] }
        var seen: Set<String> = []
        return limits.compactMap { limit in
            guard let name = limit.scope?.model?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty,
                // An "all models" scope is the account-wide weekly cap wearing a scope (seen in the
                // CodexBar reference's own mapper), i.e. the `seven_day` row again under another name.
                name.lowercased() != "all models"
            else { return nil }
            // The window id is what a stored "Notch shows" choice points at, so it takes the model's
            // own id whenever the payload carries one: a display name is marketing copy and "Fable"
            // becoming "Fable 2" would silently reset the user's choice. The display name is still what
            // the row is titled and what the Settings switch says ("Show Fable").
            let id = limit.scope?.model?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (id?.isEmpty == false ? id : nil) ?? name
            guard
                let window = window(
                    Window(utilization: limit.percent, resetsAt: limit.resetsAt), id: "model:\(key)",
                    title: name, period: nil, kind: .model(name), now: now),
                seen.insert(key).inserted
            else { return nil }
            return window
        }
    }

    // One window: clamp to 0...100 and parse the ISO-8601 `resets_at`. A window whose reset already
    // passed is dropped, because that snapshot is stale.
    private static func window(
        _ w: Window?, id: String, title: String, period: TimeInterval?, kind: UsageWindow.Kind, now: Date
    ) -> UsageWindow? {
        guard let w, let pct = w.utilization else { return nil }
        let resetsAt = w.resetsAt.flatMap { UsageParser.parseResetDate($0) }
        return UsageMath.window(
            id: id, title: title, percent: pct, period: period, resetsAt: resetsAt, kind: kind, now: now)
    }

}
