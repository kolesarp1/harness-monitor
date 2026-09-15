import Foundation

public enum UsageMath {
    public static func window(
        id: String, title: String, percent: Double, period: TimeInterval?, resetsAt: Date?,
        kind: UsageWindow.Kind, now: Date
    ) -> UsageWindow? {
        // The elapsed-reset rule is this function's whole job; the 0...100 clamp belongs to
        // `UsageWindow.init`, where it holds for every window however it was built.
        if let resetsAt, now >= resetsAt { return nil }
        return UsageWindow(
            id: id, title: title, utilization: percent, period: period, resetsAt: resetsAt, kind: kind)
    }

    public static func shouldFetch(
        force: Bool, lastFetch: Date, now: Date, minRefresh: TimeInterval
    ) -> Bool {
        if force { return true }
        return now.timeIntervalSince(lastFetch) >= minRefresh
    }

    // The most recent Monday 00:00 local — today when today is Monday. "This week" means the same thing
    // for every provider that reports it, so the boundary is defined once here rather than by whichever
    // reader happened to need it. weekday: 1=Sun … 7=Sat.
    public static func mostRecentMonday(onOrBefore now: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: start)
        let daysSinceMonday = (weekday + 5) % 7  // Mon->0, Tue->1 … Sun->6
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: start) ?? start
    }
}
