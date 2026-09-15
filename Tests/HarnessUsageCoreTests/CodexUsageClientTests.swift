import Foundation
import Testing

@testable import HarnessUsageCore

private let now = Date(timeIntervalSince1970: 1_755_600_000)
private let in3h = now.addingTimeInterval(3 * 3600)

private func window(_ snapshot: UsageSnapshot, id: String) -> UsageWindow? {
    snapshot.windows.first { $0.id == id }
}
private let in7d = now.addingTimeInterval(7 * 86_400)

// The `wham/usage` body shape. `limitWindowSeconds` is passed per slot so a test can swap the two
// windows around or omit the field entirely.
private func body(
    primary: (pct: Double, reset: Date, seconds: Int?)?,
    secondary: (pct: Double, reset: Date, seconds: Int?)?
) -> Data {
    func window(_ w: (pct: Double, reset: Date, seconds: Int?)?) -> String {
        guard let w else { return "null" }
        let seconds = w.seconds.map { ", \"limit_window_seconds\": \($0)" } ?? ""
        return "{\"used_percent\": \(w.pct), \"reset_at\": \(Int(w.reset.timeIntervalSince1970))\(seconds)}"
    }
    return Data(
        """
        {"account_id": "acct-1", "plan_type": "pro",
         "rate_limit": {"primary_window": \(window(primary)), "secondary_window": \(window(secondary))}}
        """.utf8)
}

@Test func mapsThePrimaryAndSecondaryWindowsToSessionAndWeek() throws {
    let data = body(primary: (41.5, in3h, 10_800), secondary: (22, in7d, 604_800))
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(snap.source == .codexUsageAPI)
    #expect(window(snap, id: "5h")?.utilization == 41.5)
    #expect(window(snap, id: "5h")?.resetsAt == in3h)
    #expect(window(snap, id: "7d")?.utilization == 22)
    #expect(window(snap, id: "7d")?.resetsAt == in7d)
}

// Defect: mapping by slot position when the field is present — the same defect class the rollout
// parser's `window_minutes >= 1440` fix addressed. A swapped payload must still read weekly correctly.
@Test func theWeeklyWindowIsIdentifiedByItsDurationNotItsSlot() throws {
    let data = body(primary: (22, in7d, 604_800), secondary: (41.5, in3h, 10_800))
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(window(snap, id: "7d")?.utilization == 22)
    #expect(window(snap, id: "5h")?.utilization == 41.5)
}

// Defect: a missing `limit_window_seconds` throwing the whole decode (the reference types it
// non-optional), which would discard both windows instead of degrading to positional mapping.
@Test func aMissingWindowDurationFallsBackToPositionalMapping() throws {
    let data = body(primary: (41.5, in3h, nil), secondary: (22, in7d, nil))
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(window(snap, id: "5h")?.utilization == 41.5)
    #expect(window(snap, id: "7d")?.utilization == 22)
}

// Defect: a percentage still on screen for a period that already reset (the donor's shared rule).
@Test func aWindowWhoseResetHasPassedIsDropped() throws {
    let data = body(primary: (41.5, now.addingTimeInterval(-60), 10_800), secondary: (22, in7d, 604_800))
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(window(snap, id: "5h") == nil)
    #expect(window(snap, id: "7d")?.utilization == 22)

    // Both expired -> nothing at all, so the caller keeps the rollout meters.
    let allStale = body(primary: (41.5, now.addingTimeInterval(-60), 10_800), secondary: (22, now.addingTimeInterval(-1), 604_800))
    #expect(CodexUsageClient.snapshot(fromResponseData: allStale, now: now) == nil)
}

// The `prolite` payload captured live from `wham/usage` (ids scrubbed, everything the decoder touches
// verbatim): the top-level bucket is the plan-wide WEEKLY cap — no 5h window at all (`secondary_window:
// null`) — while the model-scoped GPT-5.3-Codex-Spark entry carries a dormant 5h window and its own
// weekly one. This exact shape, with the base bucket at 14% used, is what ChatGPT renders as "86% left".
private let prolite = Data(
    """
    {"user_id": "user-x", "account_id": "acct-x", "email": "x@example.com", "plan_type": "prolite",
     "rate_limit": {"allowed": true, "limit_reached": false,
       "primary_window": {"used_percent": 14, "limit_window_seconds": 604800, "reset_after_seconds": 503763, "reset_at": 1787841744},
       "secondary_window": null},
     "code_review_rate_limit": null,
     "additional_rate_limits": [
       {"limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
        "rate_limit": {"allowed": true, "limit_reached": false,
          "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 18000, "reset_at": 1787355982},
          "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800, "reset_after_seconds": 42829, "reset_at": 1787380811}}}],
     "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
     "spend_control": {"reached": false, "individual_limit": null},
     "rate_limit_reset_credits": {"available_count": 0, "applicable_available_count": 0}}
    """.utf8)
private let proliteNow = Date(timeIntervalSince1970: 1_787_332_231)  // inside both windows

// Defect (the reported bug): letting the model-scoped windows compete for the account rows printed a
// dormant Spark 5h as Session=0% and evicted the account's real weekly meter — the number ChatGPT
// shows — off every surface. Model caps block a model, not the account, so they never take an account row.
@Test func modelScopedWindowsNeverTakeAnAccountRow() throws {
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: prolite, now: proliteNow))
    #expect(window(snap, id: "5h") == nil)  // the account has no 5h cap; Spark's dormant one must not stand in
    #expect(window(snap, id: "7d")?.utilization == 14)  // the plan-wide meter, matching ChatGPT's "86% left"
    #expect(window(snap, id: "7d")?.resetsAt == Date(timeIntervalSince1970: 1_787_841_744))
    #expect(snap.windows.filter { !$0.kind.isAccount }.map(\.title) == ["Spark 5h", "Spark Weekly"])
    #expect(snap.windows.filter { !$0.kind.isAccount }.map(\.utilization) == [0, 40])
    #expect(UsageSelection.resolved(snap, scope: .window("7d"), includingExtras: true)?.utilization == 14)
    #expect(UsageSelection.resolved(snap, scope: .mostUrgent, includingExtras: false)?.utilization == 14)
    #expect(UsageSelection.resolved(snap, scope: .mostUrgent, includingExtras: true)?.utilization == 40)
    #expect(snap.windows.map(\.title) == ["Spark 5h", "Weekly", "Spark Weekly"])
}

// Defect: an unrecognized array element throwing the array's decode — which, since the whole response
// decode is a `try?`, would blank the account's own windows too.
@Test func aMalformedAdditionalEntryLeavesItsValidSiblingAndTheBaseWindowsStanding() throws {
    let data = Data(
        """
        {"plan_type": "prolite",
         "rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 10800, "reset_at": \(Int(in3h.timeIntervalSince1970))},
                        "secondary_window": null},
         "additional_rate_limits": ["nonsense", null, 7,
           {"limit_name": 42, "rate_limit": "also nonsense"},
           {"limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {"primary_window": {"used_percent": "high"},
                           "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800, "reset_at": \(Int(in7d.timeIntervalSince1970))}}}]}
        """.utf8)
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(window(snap, id: "5h")?.utilization == 12)  // the base window survived the bad siblings
    #expect(window(snap, id: "7d") == nil)  // the surviving model's weekly window must not fill the account row
    #expect(snap.windows.filter { !$0.kind.isAccount }.map(\.title) == ["Spark Weekly"])
    #expect(snap.windows.first { $0.id == "model:GPT-5.3-Codex-Spark:7d" }?.utilization == 40)
}

// Defect: the candidate machinery reshuffling a plan whose base bucket IS the real meter.
@Test func thePlusPlanShapeKeepsItsBaseWindowMapping() throws {
    let data = body(primary: (63, in3h, 10_800), secondary: (18, in7d, 604_800))
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(window(snap, id: "5h")?.utilization == 63)
    #expect(window(snap, id: "7d")?.utilization == 18)
    #expect(snap.windows.filter { !$0.kind.isAccount }.isEmpty)
}

// Defect (the inverse shape): model windows that LOSE nothing still belong beside the account rows,
// not in them — dropping them would hide caps, folding them in would misreport the plan-wide meter.
@Test func modelScopedWindowsAlwaysLandInExtras() throws {
    let data = Data(
        """
        {"plan_type": "pro",
         "rate_limit": {"primary_window": {"used_percent": 63, "limit_window_seconds": 10800, "reset_at": \(Int(in3h.timeIntervalSince1970))},
                        "secondary_window": {"used_percent": 55, "limit_window_seconds": 604800, "reset_at": \(Int(in7d.timeIntervalSince1970))}},
         "additional_rate_limits": [
           {"metered_feature": "codex_bengalfox",
            "rate_limit": {"primary_window": {"used_percent": 5, "limit_window_seconds": 18000, "reset_at": \(Int(in3h.timeIntervalSince1970))},
                           "secondary_window": {"used_percent": 90, "limit_window_seconds": 604800, "reset_at": \(Int(in7d.timeIntervalSince1970))}}}]} 
        """.utf8)
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(window(snap, id: "5h")?.utilization == 63)  // the base 3h window owns the Session row
    #expect(window(snap, id: "7d")?.utilization == 55)  // the BASE weekly, not the model's fuller 90%
    #expect(snap.windows.filter { !$0.kind.isAccount }.map(\.title) == ["Bengalfox 5h", "Bengalfox Weekly"])
    #expect(snap.windows.filter { !$0.kind.isAccount }.map(\.utilization) == [5, 90])
    #expect(snap.windows.map(\.title) == ["Session", "Bengalfox 5h", "Weekly", "Bengalfox Weekly"])
}

@Test func namelessCodexLimitsKeepDistinctLabels() throws {
    let data = Data(
        """
        {"rate_limit": {"primary_window": {"used_percent": 50, "reset_at": \(Int(in3h.timeIntervalSince1970)), "limit_window_seconds": 10800}},
         "additional_rate_limits": [
           {"rate_limit": {"primary_window": {"used_percent": 10, "reset_at": \(Int(in3h.timeIntervalSince1970)), "limit_window_seconds": 10800}}},
           {"rate_limit": {"primary_window": {"used_percent": 20, "reset_at": \(Int(in3h.timeIntervalSince1970)), "limit_window_seconds": 10800}}}]}
        """.utf8)

    let snapshot = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(snapshot.windows.filter { !$0.kind.isAccount }.map(\.title) == ["Extra 5h", "Extra 5h 2"])
}

@Test func percentagesAreClampedAndEmptyBodiesYieldNothing() throws {
    let data = body(primary: (140, in3h, 10_800), secondary: (-5, in7d, 604_800))
    let snap = try #require(CodexUsageClient.snapshot(fromResponseData: data, now: now))
    #expect(window(snap, id: "5h")?.utilization == 100)
    #expect(window(snap, id: "7d")?.utilization == 0)

    #expect(CodexUsageClient.snapshot(fromResponseData: body(primary: nil, secondary: nil), now: now) == nil)
    #expect(CodexUsageClient.snapshot(fromResponseData: Data("{}".utf8), now: now) == nil)
    #expect(CodexUsageClient.snapshot(fromResponseData: Data("not json".utf8), now: now) == nil)
}
