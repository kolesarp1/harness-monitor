import Foundation

// Pure presentation helpers for usage meters: deterministic strings, no view types.
public enum UsageFormat {
    // The moment a window resets, as the user reads it: on the same day just the clock time
    // ("12:30"); any other day day + short month + time ("21 aug 12:30") — never a weekday. The field
    // shapes are fixed rather than localised (this string sits inside an English sentence, and a
    // region that renders the same date as "08/06" makes the two numbers ambiguous); only the time
    // zone follows the user. Pass `now` (and optionally one) to make the output independent of where
    // and when the test runs.
    public static func resetStamp(_ d: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let sameDay = cal.isDate(d, inSameDayAs: now)
        func stamp(_ format: Date.VerbatimFormatStyle) -> String {
            format.format(d).lowercased()  // "Aug" → "aug": the stamp carries no other letters
        }
        if sameDay {
            return stamp(
                Date.VerbatimFormatStyle(
                    format: "\(hour: .defaultDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                    locale: Locale(identifier: "en_US_POSIX"),
                    timeZone: timeZone,
                    calendar: Calendar(identifier: .gregorian)))
        }
        return stamp(
            Date.VerbatimFormatStyle(
                format: "\(day: .defaultDigits) \(month: .abbreviated) \(hour: .defaultDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: timeZone,
                calendar: Calendar(identifier: .gregorian)))
    }

    // "3h 40m" / "40m" / "2d 1h" — a countdown to a reset at any distance. Negative (already-past)
    // inputs clamp to "0m". Past a day the minutes stop carrying information, so the second unit is hours.
    public static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 86_400 {
            let d = s / 86_400
            return "\(d)d \((s % 86_400) / 3_600)h"
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // Token counts, abbreviated: "999", "1.2k", "100k", "1.4M". Big raw numbers are unreadable at a
    // glance and are the widget's least precise figure anyway (an estimate), so precision below the
    // shown digits buys nothing. One decimal only in the first decade of each unit, where it carries
    // real information; above that the integer is already three significant digits.
    //
    // Rounding is applied BEFORE the tier is picked, so a value that rounds up across a boundary
    // (9_950 → 10.0k) prints in the tier it lands in ("10k"), never as "10.0k".
    public static func tokens(_ n: Int) -> String {
        let magnitude = abs(n)
        if magnitude < 1_000 { return "\(n)" }
        if magnitude < 1_000_000 { return scaled(n, by: 1_000, unit: "k", nextUnit: 1_000_000) }
        return scaled(n, by: 1_000_000, unit: "M", nextUnit: nil)
    }

    // A utilization percentage, as the user reads it — the number only, because the card's hero
    // draws its "%" in its own smaller type.
    //
    // Whole numbers everywhere except the two ends, where rounding reports the opposite of the
    // truth: 0.4% used reads as an untouched limit and 99.6% as a spent one. Inside a point of
    // either end the figure keeps a tenth, and a reading too small to show even as a tenth says that
    // rather than claiming a number ("<0.1", ">99.9").
    public static func percent(_ value: Double) -> String {
        guard value > 0 else { return "0" }
        // Only *inside* the two ends: 100 and above is a spent limit and prints as the whole number
        // it is, the same as every reading between 1 and 99.
        let fractional = value < 1 || (value > 99 && value < 100)
        guard fractional else { return "\(Int(value.rounded()))" }
        let tenths = (value * 10).rounded() / 10
        if tenths < 0.1 { return "<0.1" }
        if tenths > 99.9 { return ">99.9" }
        // Fixed locale: the decimal separator is no more the system's to choose than "%" is.
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tenths)
    }

    // One decimal below 10 units, integer above. `nextUnit` lets a value that rounds up past the
    // scale's ceiling (999_999 → 1000k) hand off to the larger unit instead of printing a fourth digit.
    private static func scaled(_ n: Int, by divisor: Double, unit: String, nextUnit: Double?) -> String {
        let value = Double(n) / divisor
        if let nextUnit, (value * 10).rounded() / 10 >= 1_000 { return tokens(Int(nextUnit)) }
        if abs(value) < 10 {
            let rounded = (value * 10).rounded() / 10
            // A tenth that rounds to a whole number drops the ".0"; one that reaches 10 is an integer
            // in this tier anyway.
            if rounded == rounded.rounded() { return "\(Int(rounded))\(unit)" }
            return String(format: "%.1f%@", rounded, unit)
        }
        return "\(Int(value.rounded()))\(unit)"
    }
}
