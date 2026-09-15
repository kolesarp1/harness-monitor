import Foundation

// Pure mapping from Cursor's dashboard payload to a UsageSnapshot. No IO — the client hands it the
// bytes, so it stays covered by the test suite (the CodexMonitor/CodexRollout split).
//
// Cursor's plan has NO 5-hour and NO weekly window: the payload carries a monthly billing cycle
// (`billingCycleStart`/`billingCycleEnd`) and nothing else time-bounded. That is why `UsageSnapshot`
// grew a `month` slot rather than this mapping borrowing the `week` one.
public enum CursorUsageLogic {
    // What a 200 body actually said. "Decoded, nothing to meter" — usage disabled, no `planUsage`, or a
    // billing cycle that has already ended — is a different answer from "this is not the dashboard
    // payload at all", and collapsing them made a perfectly good response read as a network failure.
    public enum Reading: Equatable, Sendable {
        case usage(UsageSnapshot)
        case nothingToReport
        case undecodable
    }

    public static func reading(from data: Data, now: Date) -> Reading {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .undecodable }
        // The RPC nests under `usage`; tolerate a flat body too, since the shape is undocumented.
        let usage = (root["usage"] as? [String: Any]) ?? root
        if let enabled = usage["enabled"] as? Bool, !enabled { return .nothingToReport }
        guard let pct = percentUsed(usage) else { return .nothingToReport }
        guard
            let month = UsageMath.window(
                id: "cycle", title: "Monthly", percent: pct, period: 30 * 86_400,
                resetsAt: cycleEnd(usage), kind: .account, now: now
            )
        else { return .nothingToReport }
        return .usage(
            UsageSnapshot(
                windows: [month], localTokensToday: nil, localTokensWeek: nil,
                source: .cursorDashboard, lastUpdated: now))
    }

    // The precomputed percentage when present; otherwise derive it from the spend against the limit.
    // `totalSpend` is the amount used; `limit - remaining` is the same figure the long way round, for
    // payloads that carry only the remainder.
    static func percentUsed(_ usage: [String: Any]) -> Double? {
        guard let plan = usage["planUsage"] as? [String: Any] else { return nil }
        if let pct = number(plan["totalPercentUsed"]) { return pct }
        guard let limit = number(plan["limit"]), limit > 0 else { return nil }
        let spend = number(plan["totalSpend"]) ?? number(plan["remaining"]).map { limit - $0 }
        guard let spend else { return nil }
        return spend / limit * 100
    }

    // The cycle bounds are epoch MILLISECONDS. Read as seconds the reset lands in 1970, the window is
    // treated as already reset, and Cursor silently shows nothing forever.
    static func cycleEnd(_ usage: [String: Any]) -> Date? {
        guard let ms = number(usage["billingCycleEnd"]), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
}
