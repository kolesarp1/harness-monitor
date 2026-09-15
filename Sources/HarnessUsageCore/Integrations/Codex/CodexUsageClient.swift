import Foundation

// Codex's live 5h/weekly meters from the ChatGPT backend, using the access token the Codex CLI
// already stores on this Mac. Read-only: the token is never refreshed or written back (see
// `CodexAuth`). When this tier can't deliver, the monitor falls back to the rollout-file tail, which
// still supplies today's token counts and cost either way.
public struct CodexUsageClient: Sendable {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // Named `Outcome`, not `Result`: a nested `Result` shadows `Swift.Result` for the whole file.
    public enum Outcome: Sendable {
        case ok(UsageSnapshot)
        case unauthorized  // 401 or 403 — the token is expired or refused
        case rateLimited(retryAfter: Date?)  // 429
        case failed  // any other status, or a transport error
    }

    private static var userAgent: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        return "HarnessUsage/\(version)"
    }

    public static func fetch(token: CodexAuth.Token, session: URLSession, now: Date) async -> Outcome {
        // Cached meters are worse than none: the whole point is the current number.
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accountId = token.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return .failed }

        switch http.statusCode {
        case 200:
            guard var snapshot = snapshot(fromResponseData: data, now: now) else { return .failed }
            snapshot.accountEmail = token.accountEmail
            return .ok(snapshot)
        // 403 as well as 401: the endpoint uses it for a refused token, and filing it as `.failed`
        // would retry every 300s forever instead of falling back once.
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited(retryAfter: UsageEndpoint.retryAfter(from: http, now: now))
        default:
            return .failed
        }
    }

    // Deliberately looser than the reference's decoder: `limit_window_seconds` is optional here, so a
    // response that omits it falls back to positional mapping instead of throwing the whole window
    // away. nil when nothing parses — the caller then keeps the rollout-derived meters.
    //
    // The account rows are the TOP-LEVEL `rate_limit` bucket alone: that is the plan-wide cap, the
    // same meter ChatGPT itself prints as "N% left". The `additional_rate_limits` entries are
    // MODEL-scoped caps (e.g. GPT-5.3-Codex-Spark) — exhausting one blocks that model, not the
    // account — so they never take an account row; each of their windows becomes a labeled extra row
    // instead (openusage's "Spark"/"Spark Weekly", tokscale's named metrics). The earlier
    // fullest-window-wins rule let a dormant model window print 0% as the account's Session meter
    // while the account's real usage was nowhere on screen.
    static func snapshot(fromResponseData data: Data, now: Date) -> UsageSnapshot? {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        // `limit_window_seconds >= 86_400` marks the weekly window — the same rule (and the same defect
        // class) as the rollout parser's `window_minutes >= 1440`. Without the field, fall back to
        // position: primary is the short window, secondary the long one.
        var session: UsageWindow?
        var week: UsageWindow?
        for (index, snapshot) in [decoded.rateLimit?.primaryWindow, decoded.rateLimit?.secondaryWindow].enumerated() {
            guard let snapshot else { continue }
            let isWeek = snapshot.limitWindowSeconds.map { $0 >= 86_400 } ?? (index == 1)
            let id = isWeek ? "7d" : "5h"
            let title = isWeek ? "Weekly" : "Session"
            let period = snapshot.limitWindowSeconds.map(TimeInterval.init)
            guard
                let window = window(
                    snapshot, id: id, title: title, period: period, kind: .account, now: now)
            else { continue }
            if isWeek { week = window } else { session = window }
        }

        // Codex suffixes and keeps colliding labels: a nameless limit is a distinct cap. Claude
        // deliberately drops a repeated model name instead, because its duplicate is the same cap
        // listed twice. These are different payload rules, so the labels must stay disambiguated here.
        // Rows are labeled by the entry's own name, shortened to its distinctive tail: OpenAI names
        // model limits "<family>-<line>-<variant>" (GPT-5.3-Codex-Spark), and the variant is the part
        // a person recognizes — openusage prints these rows as plain "Spark"/"Spark Weekly". A name
        // whose tail is not a plain word (a bare version, say) stays whole rather than mislabeling.
        func displayName(_ raw: String) -> String {
            let tail = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).last.map(String.init) ?? raw
            guard !tail.isEmpty, tail.allSatisfy(\.isLetter) else { return raw }
            return tail.prefix(1).uppercased() + tail.dropFirst()
        }
        var usedLabels: Set<String> = []
        var usedIDs: Set<String> = []
        let modelWindows = (decoded.additionalRateLimits ?? []).flatMap { entry -> [UsageWindow] in
            let name = displayName(entry.name)
            var windows = candidateWindows(entry.rateLimit, name: entry.name, title: name, now: now)
            for index in windows.indices {
                let window = windows[index]
                var id = window.id
                var label = window.title
                var suffix = 2
                while usedIDs.contains(id) {
                    id = "\(window.id):\(suffix)"
                    suffix += 1
                }
                usedIDs.insert(id)
                suffix = 2
                while usedLabels.contains(label) {
                    label = "\(window.title) \(suffix)"
                    suffix += 1
                }
                usedLabels.insert(label)
                if id != window.id || label != window.title {
                    windows[index] = UsageWindow(
                        id: id, title: label, utilization: window.utilization,
                        period: window.period, resetsAt: window.resetsAt, kind: window.kind)
                }
            }
            return windows
        }
        let windows = [session, week].compactMap { $0 } + modelWindows

        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(
            windows: windows, localTokensToday: nil, localTokensWeek: nil,
            source: .codexUsageAPI, lastUpdated: now)
    }

    // `limit_window_seconds >= 86_400` marks the weekly window; without the field, positional:
    // primary is the short window, secondary the long one. The seconds also ride along as the row's
    // period, so the snapshot can order model limits by their true length among account windows.
    private static func candidateWindows(
        _ limits: RateLimit?, name: String, title: String, now: Date
    ) -> [UsageWindow] {
        guard let limits else { return [] }
        return [limits.primaryWindow, limits.secondaryWindow].enumerated().compactMap { index, snapshot in
            guard let snapshot else { return nil }
            let isWeek = snapshot.limitWindowSeconds.map { $0 >= 86_400 } ?? (index == 1)
            let suffix = isWeek ? "Weekly" : "5h"
            let id = "model:\(name):\(isWeek ? "7d" : "5h")"
            let label = "\(title) \(suffix)"
            let period = snapshot.limitWindowSeconds.map(TimeInterval.init)
            return window(
                snapshot, id: id, title: label, period: period, kind: .model(title), now: now)
        }
    }

    // One window: clamp to 0...100 and read the epoch-seconds reset. A window whose reset already
    // passed is dropped — that reading describes a period that has ended (the donor's shared rule).
    private static func window(
        _ snapshot: WindowSnapshot, id: String, title: String, period: TimeInterval?,
        kind: UsageWindow.Kind, now: Date
    ) -> UsageWindow? {
        guard let pct = snapshot.usedPercent else { return nil }
        let resetsAt = snapshot.resetAt.map { Date(timeIntervalSince1970: $0) }
        return UsageMath.window(
            id: id, title: title, percent: pct, period: period, resetsAt: resetsAt, kind: kind, now: now)
    }

    private struct Response: Decodable {
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalLimit]?
        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rateLimit = try? container.decode(RateLimit.self, forKey: .rateLimit)
            // Decoded per element through `Lossy`, which never throws: one malformed entry must not
            // discard its valid siblings — nor, since this whole decode is a `try?`, the account's own
            // windows (CodexBar `CodexOAuthUsageFetcher.swift:47-61`).
            let entries = try? container.decode([Lossy<AdditionalLimit>].self, forKey: .additionalRateLimits)
            additionalRateLimits = entries?.compactMap(\.value)
        }
    }

    // Any element that fails to decode becomes nil instead of failing the array around it.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct AdditionalLimit: Decodable {
        let name: String  // the entry's display name, for the row label it may need
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // `limit_name` is the human label ("GPT-5.3-Codex-Spark"); `metered_feature` is its
            // internal codename ("codex_bengalfox") and stands in only when the label is absent. A
            // nameless entry still gets a row rather than vanishing, so "Extra" is the last resort.
            let names = [CodingKeys.limitName, .meteredFeature].compactMap { try? container.decode(String.self, forKey: $0) }
            name = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Extra"
            rateLimit = try? container.decode(RateLimit.self, forKey: .rateLimit)
        }
    }

    private struct RateLimit: Decodable {
        let primaryWindow: WindowSnapshot?
        let secondaryWindow: WindowSnapshot?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        // Per window, so a malformed one leaves the other standing.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try? container.decode(WindowSnapshot.self, forKey: .primaryWindow)
            secondaryWindow = try? container.decode(WindowSnapshot.self, forKey: .secondaryWindow)
        }
    }

    private struct WindowSnapshot: Decodable {
        let usedPercent: Double?
        let resetAt: Double?
        let limitWindowSeconds: Int?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
}
