import Foundation
import Testing

@testable import HarnessUsageCore

private let now = Date(timeIntervalSince1970: 1_755_600_000)

@Test func clampsWindowsAndDropsElapsedResets() {
    #expect(
        UsageMath.window(
            id: "5h", title: "Session", percent: -5, period: 5 * 3_600,
            resetsAt: now.addingTimeInterval(60), kind: .account, now: now)?.utilization == 0)
    #expect(
        UsageMath.window(
            id: "7d", title: "Weekly", percent: 140, period: 7 * 86_400,
            resetsAt: now.addingTimeInterval(60), kind: .account, now: now)?.utilization == 100)
    #expect(
        UsageMath.window(
            id: "5h", title: "Session", percent: 50, period: 5 * 3_600,
            resetsAt: now, kind: .account, now: now) == nil)
}

// Defect: an out-of-range percentage reaching a meter. The clamp lives in `UsageWindow.init` now, so
// every construction path is covered — including the ones that never went through `UsageMath.window`.
@Test func theWindowTypeClampsWhoeverBuildsIt() {
    #expect(UsageWindow(id: "5h", title: "Session", utilization: -5, kind: .account).utilization == 0)
    #expect(UsageWindow(id: "5h", title: "Session", utilization: 140, kind: .account).utilization == 100)
}

// Defect: two providers meaning different things by "this week" on the same card — opencode counted a
// rolling 168 hours while Claude counted from Monday. The boundary is one function now; this pins its
// two interesting days, since `weekday` is 1=Sunday and an off-by-one lands a week early or late.
@Test func theWeekStartsOnTheMostRecentMonday() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    func monday(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = calendar.timeZone
        return UsageMath.mostRecentMonday(onOrBefore: f.date(from: iso)!, calendar: calendar)
    }

    // 2025-08-18 is a Monday, 2025-08-24 the Sunday that closes the same week.
    let weekStart = ISO8601DateFormatter().date(from: "2025-08-18T00:00:00Z")!
    #expect(monday("2025-08-18T00:00:00Z") == weekStart)  // Monday resolves to its own midnight
    #expect(monday("2025-08-18T23:59:59Z") == weekStart)
    #expect(monday("2025-08-24T12:00:00Z") == weekStart)  // Sunday still belongs to the week that began Monday
    #expect(monday("2025-08-25T00:00:01Z") == weekStart.addingTimeInterval(7 * 86_400))  // the next Monday starts a new one
}
