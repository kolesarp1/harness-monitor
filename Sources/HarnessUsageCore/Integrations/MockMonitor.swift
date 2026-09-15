import Foundation

// A monitor that reads fixture JSONs from a `MockData/` directory instead of real agent files.
// Used with the `--mock` CLI flag for screenshots, development, and UI testing without running
// any real agents. Each integration's fixtures live at `MockData/<name>/fixtures.json` and contain
// a `{ "usage": {...} }` payload. The monitor returns it verbatim every tick (no throttling — mock
// data is instant). If a fixture file is missing, that integration reports no usage.
public actor MockMonitor: IntegrationMonitor {
    private let fixturesURL: URL

    // Fixtures are per HARNESS, not per account: `--mock` exists to exercise the UI, and every
    // account of one harness can render from the same shape without four fixture files to keep in step.
    public init(integration: Integration, mockDir: URL) {
        self.fixturesURL = mockDir.appendingPathComponent("\(integration.harness.rawValue)/fixtures.json")
    }

    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fixturesURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let u = json["usage"] as? [String: Any]
        else { return nil }
        return Self.parseUsage(u, now: Date(), source: fixturesURL)
    }

    // Parse the fixture's usage object into a UsageSnapshot. Times are RELATIVE so the fixtures do not
    // age in the repository: `resetsAt` is non-negative seconds from load time, `lastUpdated` is seconds
    // ago. Both still accept an ISO-8601 string for a fixture that wants a fixed instant.
    private static func parseUsage(_ o: [String: Any], now: Date, source fixture: URL) -> UsageSnapshot? {
        let iso = ISO8601DateFormatter()
        func date(_ any: Any?, secondsAhead: Bool) -> Date? {
            if let offset = (any as? NSNumber)?.doubleValue, offset >= 0 {
                return now.addingTimeInterval(secondsAhead ? offset : -offset)
            }
            if let string = any as? String { return iso.date(from: string) }
            return nil
        }
        let windows =
            (o["windows"] as? [[String: Any]])?.compactMap { value -> UsageWindow? in
                guard let id = value["id"] as? String, !id.isEmpty,
                    let title = value["title"] as? String, !title.isEmpty,
                    let utilization = value["utilization"] as? NSNumber,
                    let kindValue = value["kind"] as? String,
                    let kind = UsageWindow.Kind(rawValue: kindValue)
                else {
                    // Loud, because silence is how a fixture drifted from `UsageWindow.Kind`'s spelling
                    // and three rows simply stopped appearing in every mock run.
                    FileHandle.standardError.write(
                        Data("HarnessUsage: \(fixture.path) — unparsed window row \(value)\n".utf8))
                    return nil
                }
                return UsageWindow(
                    id: id, title: title, utilization: utilization.doubleValue,
                    period: (value["period"] as? NSNumber)?.doubleValue,
                    resetsAt: date(value["resetsAt"], secondsAhead: true), kind: kind)
            } ?? []
        let sourceStr = o["source"] as? String ?? "localEstimate"
        let source = UsageSource(rawValue: sourceStr) ?? .localEstimate
        let lastUpdated = date(o["lastUpdated"], secondsAhead: false) ?? now
        return UsageSnapshot(
            windows: windows, localTokensToday: (o["localTokensToday"] as? NSNumber)?.intValue,
            localTokensWeek: (o["localTokensWeek"] as? NSNumber)?.intValue,
            source: source, lastUpdated: lastUpdated,
            todayInput: (o["todayInput"] as? NSNumber)?.intValue,
            todayOutput: (o["todayOutput"] as? NSNumber)?.intValue,
            costTodayUSD: (o["costTodayUSD"] as? NSNumber)?.doubleValue,
            estimatedCostUSD: (o["estimatedCostUSD"] as? NSNumber)?.doubleValue,
            note: o["note"] as? String)
    }
}
