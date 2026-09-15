import Foundation
import Testing

@testable import HarnessUsageCore

// Defect class: tier boundaries off by one, or a trailing ".0" leaking into the label.
@Test func tokenCountsAbbreviateAtEachTier() {
    #expect(UsageFormat.tokens(0) == "0")
    #expect(UsageFormat.tokens(999) == "999")  // last raw value
    #expect(UsageFormat.tokens(1_000) == "1k")  // ".0" trimmed, not "1.0k"
    #expect(UsageFormat.tokens(1_234) == "1.2k")
    #expect(UsageFormat.tokens(9_950) == "10k")  // rounds ACROSS the tier — never "10.0k"
    #expect(UsageFormat.tokens(100_400) == "100k")
    #expect(UsageFormat.tokens(1_400_000) == "1.4M")
    #expect(UsageFormat.tokens(12_000_000) == "12M")
}

// The two seams the tiers meet at, from both sides.
@Test func tokenTierBoundariesAreExact() {
    #expect(UsageFormat.tokens(9_999) == "10k")
    #expect(UsageFormat.tokens(10_000) == "10k")
    #expect(UsageFormat.tokens(999_499) == "999k")
    // Rounds up past the "k" ceiling: hands off to "M" rather than printing a fourth digit ("1000k").
    #expect(UsageFormat.tokens(999_999) == "1M")
    #expect(UsageFormat.tokens(1_000_000) == "1M")
}

// Defect: the stamp drifting with whoever's Mac renders it — a locale that writes "08/06", a 12-hour
// clock, or a non-Gregorian calendar all change what the same instant reads as. The format is fixed,
// only the zone moves, so a literal instant has exactly one expected string per zone. Same-day resets
// print the bare clock time; other days add day + short month; never a weekday.
@Test func resetStampIsFixedFormatAndFollowsOnlyTheTimeZone() throws {
    let instant = try #require(UsageParser.parseResetDate("2026-08-06T14:22:00Z"))
    let now = try #require(UsageParser.parseResetDate("2026-08-06T10:00:00Z"))  // the same day everywhere
    let warsaw = try #require(TimeZone(identifier: "Europe/Warsaw"))  // UTC+2 that day
    let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))  // UTC+5:30 — a half-hour offset

    // Same calendar day as `now`: the time alone carries everything.
    #expect(UsageFormat.resetStamp(instant, now: now, timeZone: warsaw) == "16:22")
    #expect(UsageFormat.resetStamp(instant, now: now, timeZone: .gmt) == "14:22")
    #expect(UsageFormat.resetStamp(instant, now: now, timeZone: kolkata) == "19:52")
    // The hour is unpadded and 24-hour: an early-morning reset reads "4:22", never "04:22 AM".
    let earlyMorning = try #require(UsageParser.parseResetDate("2026-08-06T04:22:00Z"))
    #expect(UsageFormat.resetStamp(earlyMorning, now: now, timeZone: .gmt) == "4:22")

    // A different calendar day gains day + short month (lowercase, no weekday), still with the time.
    // The same instant can be both: 23:40Z is still Aug 6 in London (time alone) but already Aug 7 in
    // Warsaw (day + month) — the day boundary follows the render zone.
    let lateNight = try #require(UsageParser.parseResetDate("2026-08-06T23:40:00Z"))
    #expect(UsageFormat.resetStamp(lateNight, now: now, timeZone: warsaw) == "7 aug 1:40")
    #expect(UsageFormat.resetStamp(lateNight, now: now, timeZone: .gmt) == "23:40")
}

@Test func countdownStaysUnchanged() {
    #expect(UsageFormat.countdown(13_200) == "3h 40m")
    #expect(UsageFormat.countdown(2_400) == "40m")
    #expect(UsageFormat.countdown(-5) == "0m")
    // Past a day the second unit degrades to hours: minutes are noise at that distance.
    #expect(UsageFormat.countdown(90_000) == "1d 1h")
    #expect(UsageFormat.countdown(86_400 * 7 - 60) == "6d 23h")
}

@Test func aPercentKeepsATenthOnlyWhereRoundingWouldLie() {
    // The body of the range is whole numbers, rounded.
    #expect(UsageFormat.percent(0) == "0")
    #expect(UsageFormat.percent(5.4) == "5")
    #expect(UsageFormat.percent(5.5) == "6")
    #expect(UsageFormat.percent(99) == "99")

    // Under one percent a limit has been touched, and "0" says it has not.
    #expect(UsageFormat.percent(0.4) == "0.4")
    #expect(UsageFormat.percent(0.04) == "<0.1")

    // Over ninety-nine it is not yet spent, and "100" says it is.
    #expect(UsageFormat.percent(99.6) == "99.6")
    #expect(UsageFormat.percent(99.96) == ">99.9")

    // Spent, and past it: whole numbers again, so a ring at its limit reads "100%".
    #expect(UsageFormat.percent(100) == "100")
    #expect(UsageFormat.percent(105.2) == "105")
}
