import Foundation

// Pure mapping from decoded opencode `session` rows to Harness Monitor's UsageSnapshot. No SQLite, no IO.
// The monitor injects the rows, so this stays covered by the test suite. opencode stores timestamps as
// epoch MILLISECONDS; `seconds(fromMS:)` normalizes them. opencode has no plan-level limit
// (bring-your-own-provider), so usage reports absolute token totals rather than a utilization %.
public enum OpenCodeLogic {
    public struct Row: Equatable, Sendable {
        public var tokensInput: Int
        public var tokensOutput: Int
        public var tokensReasoning: Int
        public var cost: Double  // opencode's own precomputed USD for the session
        public var timeUpdatedMS: Int64  // epoch milliseconds

        public init(
            tokensInput: Int, tokensOutput: Int, tokensReasoning: Int, cost: Double = 0,
            timeUpdatedMS: Int64
        ) {
            self.tokensInput = tokensInput
            self.tokensOutput = tokensOutput
            self.tokensReasoning = tokensReasoning
            self.cost = cost
            self.timeUpdatedMS = timeUpdatedMS
        }
    }

    public static func seconds(fromMS ms: Int64) -> Double { Double(ms) / 1000 }

    // Today's and the week's token totals, plus opencode's own precomputed USD for today. No plan
    // limit exists, so there is no utilization % — the widget renders the token/cost footer instead.
    public static func usage(rows: [Row], now: Date, calendar: Calendar) -> UsageSnapshot? {
        guard !rows.isEmpty else { return nil }
        var today = 0
        var week = 0
        var todayInput = 0
        var todayOutput = 0
        var todayCost = 0.0  // opencode's own precomputed USD — a real (not estimated) meter
        var newest = Date.distantPast
        for r in rows {
            let tok = r.tokensInput + r.tokensOutput + r.tokensReasoning
            let date = Date(timeIntervalSince1970: seconds(fromMS: r.timeUpdatedMS))
            week += tok
            if calendar.isDate(date, inSameDayAs: now) {  // relative to injected now — deterministic
                today += tok
                todayInput += r.tokensInput
                todayOutput += r.tokensOutput + r.tokensReasoning
                todayCost += r.cost
            }
            if date > newest { newest = date }
        }
        return UsageSnapshot(
            windows: [], localTokensToday: today > 0 ? today : nil, localTokensWeek: week,
            source: .opencodeLocal, lastUpdated: newest,
            todayInput: today > 0 ? todayInput : nil, todayOutput: today > 0 ? todayOutput : nil,
            costTodayUSD: todayCost > 0 ? todayCost : nil)
    }
}
