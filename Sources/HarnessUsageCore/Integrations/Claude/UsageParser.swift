import Foundation

public enum UsageParser {
    // Sendable value-type parser (safe for off-main actor calls in Phase 2). Fractional first; the
    // API has omitted fractional seconds before, so fall back to plain internet-date-time.
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
    public static func parseResetDate(_ s: String) -> Date? {
        (try? isoFractional.parse(s)) ?? (try? isoPlain.parse(s))
    }
}
