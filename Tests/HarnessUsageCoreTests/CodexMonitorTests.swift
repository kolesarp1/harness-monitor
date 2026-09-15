import Foundation
import Testing

@testable import HarnessUsageCore

// Serves one canned `wham/usage` body to whatever asks. Only this file's session config lists it, so
// it cannot intercept any other test's traffic.
private final class CodexUsageStub: URLProtocol {
    static let body = Data(
        """
        {"account_id": "acct-1", "plan_type": "pro",
         "rate_limit": {"primary_window": {"used_percent": 41.5, "reset_at": 1755610800, "limit_window_seconds": 10800},
                        "secondary_window": {"used_percent": 22, "reset_at": 1756204800, "limit_window_seconds": 604800}}}
        """.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

// A JWT whose payload carries only `exp`; the signature is never checked, only the middle segment is
// read. Written unpadded, exactly as a real token is.
private func window(_ snapshot: UsageSnapshot, id: String) -> UsageWindow? {
    snapshot.windows.first { $0.id == id }
}

private func accountWindow(id: String, title: String, utilization: Double, resetsAt: Date?) -> UsageWindow {
    UsageWindow(
        id: id, title: title, utilization: utilization,
        period: id == "5h" ? 5 * 3_600 : 7 * 86_400, resetsAt: resetsAt, kind: .account)
}

private func jwt(expiring at: Date) -> String {
    let payload = Data("{\"exp\":\(Int(at.timeIntervalSince1970))}".utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

// Defect: the parse cache growing without bound as date dirs roll off the 7-day scan window — every
// rollout the app has ever seen kept in memory for the life of the process.
@Test func evictDropsEntriesOutsideTheScannedDirectories() {
    let root = URL(fileURLWithPath: "/tmp/codex-sessions")
    let kept = root.appendingPathComponent("2025/08/19/kept.jsonl")
    let stale = root.appendingPathComponent("2025/07/01/stale.jsonl")
    let cache = [kept: 1, stale: 2]

    let result = CodexMonitor.evict(cache, scannedDirs: [root.appendingPathComponent("2025/08/19").path])
    #expect(Set(result.keys) == Set([kept]))
}

@Test func aSecondScanUsesTheFileCache() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-cache-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_755_600_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = calendar.dateComponents([.year, .month, .day], from: now)
    let day = String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
    let sessions = home.appendingPathComponent(".codex/sessions/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = sessions.appendingPathComponent("rollout-cache.jsonl")
    let valid = Data(
        """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":60,"resets_at":1755603600,"window_minutes":300}}}}
        """.utf8)
    try valid.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

    let monitor = CodexMonitor(home: home, now: { now }, environment: [:])
    let first = try #require(await monitor.scan())
    #expect(window(first, id: "5h")?.utilization == 60)

    try Data("not json".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    let second = try #require(await monitor.scan())
    #expect(window(second, id: "5h")?.utilization == 60)
}

@Test func liveMetersReplaceRolloutWindowsWholesale() throws {
    let at = Date(timeIntervalSince1970: 1_755_600_000)
    let reset = at.addingTimeInterval(3_600)
    let rollout = UsageSnapshot(
        windows: [
            accountWindow(id: "5h", title: "Session", utilization: 62, resetsAt: reset),
            accountWindow(id: "7d", title: "Weekly", utilization: 44, resetsAt: reset),
        ], localTokensToday: 123, localTokensWeek: nil, source: .codexLocal, lastUpdated: at)
    let live = UsageSnapshot(
        windows: [accountWindow(id: "7d", title: "Weekly", utilization: 55, resetsAt: reset)],
        localTokensToday: nil, localTokensWeek: nil, source: .codexUsageAPI, lastUpdated: at)

    let merged = try #require(CodexMonitor.merged(rollout: rollout, live: live, liveNote: nil, now: at))
    #expect(window(merged, id: "5h") == nil)
    #expect(window(merged, id: "7d")?.utilization == 55)
    #expect(merged.localTokensToday == 123)
}

// Through `reload`, which is the path the app takes: `merged` used to overwrite the rollout's note
// with the live tier's unconditionally, so the one explanation for an empty Codex row — its rate-limit
// window expired — never reached a consumer.
@Test func expiredRolloutWindowKeepsTokensAndExplainsTheDrop() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-stale-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_755_600_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = calendar.dateComponents([.year, .month, .day], from: now)
    let day = String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
    let sessions = home.appendingPathComponent(".codex/sessions/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let rollout = Data(
        """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":60,"resets_at":1755599940,"window_minutes":300},"secondary":null},"info":{"total_token_usage":{"total_tokens":123}}}}
        """.utf8)
    let file = sessions.appendingPathComponent("rollout-stale.jsonl")
    try rollout.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    let monitor = CodexMonitor(home: home, now: { now }, environment: [:])
    let snapshot = try #require(await monitor.reload(wantUsageEstimate: false))
    #expect(window(snapshot, id: "5h") == nil)
    #expect(snapshot.localTokensToday == 123)
    #expect(snapshot.note == "Codex rate-limit window expired — using local session data")
}

// Defect: `JSONSerialization` decodes JSON `null` as `NSNull`, which is non-nil — so a `limit_id`
// block with both slots null read as "we saw rate limits and they are all gone", and `scan` then
// overwrote a still-valid Pro meter from an older file with nothing.
@Test func aRateLimitBlockOfNullsIsNotAnExpiredWindow() {
    let line =
        """
        {"type":"event_msg","payload":{"type":"token_count","limit_id":"premium","rate_limits":{"primary":null,"secondary":null}}}
        """
    let objects = CodexRollout.parseObjects(fromTail: [line])
    let limits = CodexRollout.rateLimits(fromParsed: objects, now: Date(timeIntervalSince1970: 1_755_600_000))

    #expect(limits.primary == nil)
    #expect(limits.secondary == nil)
    #expect(!limits.expired)
}

// Defect: the file cache is keyed on mtime and stores a window materialised at PARSE time, so expiry
// was decided once and never revisited. An idle Codex then re-published a window that reset hours ago,
// because nothing wrote a rollout to invalidate the entry.
@Test func aCachedWindowStopsBeingPublishedOnceItsResetPasses() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-expiry-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_755_600_000)
    let clock = Clock(start)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = calendar.dateComponents([.year, .month, .day], from: start)
    let day = String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
    let sessions = home.appendingPathComponent(".codex/sessions/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let resetsAt = Int(start.timeIntervalSince1970) + 60
    let file = sessions.appendingPathComponent("rollout-expiring.jsonl")
    try Data(
        """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":60,"resets_at":\(resetsAt),"window_minutes":300}},"info":{"total_token_usage":{"total_tokens":123}}}}
        """.utf8
    ).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: file.path)

    let monitor = CodexMonitor(home: home, now: { clock.now }, environment: [:])
    #expect(window(try #require(await monitor.scan()), id: "5h")?.utilization == 60)

    clock.advance(30)  // still inside the window, and the file has not changed
    #expect(window(try #require(await monitor.scan()), id: "5h")?.utilization == 60)

    clock.advance(90)  // past the reset — the cache still holds the same parse
    let expired = try #require(await monitor.scan())
    #expect(expired.windows.isEmpty)
    #expect(expired.localTokensToday == 123)
    #expect(expired.note == "Codex rate-limit window expired — using local session data")
}

// Defect: only a non-empty parse was cached, so every pi session log holding no codex messages — the
// ordinary case — was reopened and re-read on every 2s scan for the life of the process.
@Test func anUnchangedPiSessionLogIsNeverReadTwice() async throws {
    let start = Date(timeIntervalSince1970: 1_755_600_000)
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-pi-cache-\(UUID().uuidString)")
    let piDir = home.appendingPathComponent(".pi/agent/sessions/proj", isDirectory: true)
    try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // One log with nothing this monitor wants, one with a codex message — both must stay read-once.
    try Data(
        """
        {"type":"message","timestamp":"\(formatter.string(from: start))","message":{"role":"assistant","provider":"openrouter","model":"stealth/ox-alpha","usage":{"input":5,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":10}}}
        """.utf8
    ).write(to: piDir.appendingPathComponent("other.jsonl"))
    try Data(
        """
        {"type":"message","timestamp":"\(formatter.string(from: start))","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","usage":{"input":1000,"output":300,"cacheRead":2000,"cacheWrite":400,"reasoning":100,"totalTokens":3800}}}
        """.utf8
    ).write(to: piDir.appendingPathComponent("codex.jsonl"))

    let monitor = CodexMonitor(home: home, now: { start }, environment: [:])
    #expect(await monitor.scan()?.localTokensToday == 3800)
    #expect(await monitor.piFileReads == 2)

    #expect(await monitor.scan()?.localTokensToday == 3800)
    #expect(await monitor.piFileReads == 2)  // nothing changed on disk: no file is opened again
}

// Defect: `reload` discarded `wantUsageEstimate`, so turning the token strip off still paid for the
// full walk of pi's session logs — the only thing that lane feeds.
@Test func theTokenStripSettingGatesThePiLane() async throws {
    let start = Date(timeIntervalSince1970: 1_755_600_000)
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-pi-gate-\(UUID().uuidString)")
    let piDir = home.appendingPathComponent(".pi/agent/sessions/proj", isDirectory: true)
    try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try Data(
        """
        {"type":"message","timestamp":"\(formatter.string(from: start))","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","usage":{"input":1000,"output":300,"cacheRead":2000,"cacheWrite":400,"reasoning":100,"totalTokens":3800}}}
        """.utf8
    ).write(to: piDir.appendingPathComponent("codex.jsonl"))

    let off = CodexMonitor(home: home, now: { start }, environment: [:])
    #expect(await off.reload(wantUsageEstimate: false)?.localTokensToday == nil)
    #expect(await off.piFileReads == 0)

    let on = CodexMonitor(home: home, now: { start }, environment: [:])
    #expect(await on.reload(wantUsageEstimate: true)?.localTokensToday == 3800)
    #expect(await on.piFileReads == 1)
}

// Defect: signing out of Codex mid-run leaves the last live percentages on screen under a "No Codex
// login found" note — meters from an account the app can no longer read, presented as current. The
// expired-token branch already cleared them; the absent-auth branch did not.
@Test func signingOutClearsTheLiveMetersItCanNoLongerRefresh() async throws {
    let start = Date(timeIntervalSince1970: 1_755_600_000)
    let clock = Clock(start)
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-\(UUID().uuidString)")
    let codexDir = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let authURL = codexDir.appendingPathComponent("auth.json")
    let token = jwt(expiring: start.addingTimeInterval(86_400))
    try Data("{\"tokens\":{\"access_token\":\"\(token)\",\"account_id\":\"acct-1\"}}".utf8).write(to: authURL)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CodexUsageStub.self]
    let monitor = CodexMonitor(
        home: home, now: { clock.now }, environment: [:], urlSession: URLSession(configuration: config))

    let live = try #require(await monitor.reload(wantUsageEstimate: false))
    #expect(window(live, id: "5h")?.utilization == 41.5)
    #expect(window(live, id: "7d")?.utilization == 22)
    #expect(live.note == nil)

    // The user runs `codex logout`: auth.json is gone by the next due fetch.
    try FileManager.default.removeItem(at: authURL)
    clock.advance(400)  // past both the 2s scan throttle and the 300s live floor

    let signedOut = try #require(await monitor.reload(wantUsageEstimate: false))
    #expect(signedOut.note == "No Codex login found under ~/.codex")
    #expect(signedOut.windows.isEmpty)
}

// Defect: Codex usage driven through the pi harness (`openai-codex` provider) never writes rollout
// files, so the "today tokens" lane stayed empty no matter how much was spent. The monitor must sum
// those messages from pi's own session logs — today's local day only, codex-provider entries only —
// and merge them under the rollout lane's conventions (input includes cached reads, reasoning folds
// into output).
@Test func piSessionLogsFillTheTokenLaneWhenRolloutsAreAbsent() async throws {
    let start = Date(timeIntervalSince1970: 1_755_600_000)
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-pi-\(UUID().uuidString)")
    let piDir = home.appendingPathComponent(".pi/agent/sessions/proj", isDirectory: true)
    try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // Today's codex message: 1000 fresh input, 400 cache-written input, 2000 cache reads,
    // 300 output + 100 reasoning → input lane 1400+2000, output lane 400.
    let codexToday = Data(
        """
        {"type":"message","timestamp":"\(iso(start))","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","usage":{"input":1000,"output":300,"cacheRead":2000,"cacheWrite":400,"reasoning":100,"totalTokens":3800}}}
        """.utf8)
    // A different provider today: must not count. s2 also carries a codex message yesterday: must
    // not count either (the lane is today-only).
    let otherProvider = Data(
        """
        {"type":"message","timestamp":"\(iso(start))","message":{"role":"assistant","provider":"openrouter","model":"stealth/ox-alpha","usage":{"input":999999,"output":999999,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":1999998}}}
        """.utf8)
    var s1 = codexToday
    s1.append(Data("\n".utf8))
    s1.append(codexYesterday(iso))
    try s1.write(to: piDir.appendingPathComponent("s1.jsonl"))
    try otherProvider.write(to: piDir.appendingPathComponent("s2.jsonl"))

    let monitor = CodexMonitor(home: home, now: { start }, environment: [:])
    let snapshot = try #require(await monitor.scan())
    #expect(snapshot.windows.isEmpty)  // no auth, no rollouts → no meters, but tokens still flow
    #expect(snapshot.localTokensToday == 3800)
    #expect(snapshot.todayInput == 1400 + 2000)
    #expect(snapshot.todayOutput == 400)

    let expectedCost = ModelPricing.codexCost(input: 1400 + 2000, cached: 2000, output: 400)
    #expect(abs((snapshot.estimatedCostUSD ?? 0) - expectedCost) < 0.0001)
}

@Test func pastDaysAreNotReadFromPiSessionLogs() async throws {
    let start = Date(timeIntervalSince1970: 1_755_600_000)
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-pi-old-\(UUID().uuidString)")
    let piDir = home.appendingPathComponent(".pi/agent/sessions/proj", isDirectory: true)
    try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let file = piDir.appendingPathComponent("old.jsonl")
    let message = Data(
        """
        {"type":"message","timestamp":"\(formatter.string(from: start))","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","usage":{"input":1000,"output":300,"cacheRead":2000,"cacheWrite":400,"reasoning":100,"totalTokens":3800}}}
        """.utf8)
    try message.write(to: file)
    try FileManager.default.setAttributes(
        [.modificationDate: start.addingTimeInterval(-2 * 86_400)], ofItemAtPath: file.path)

    let monitor = CodexMonitor(home: home, now: { start }, environment: [:])
    let snapshot = await monitor.scan()
    #expect(snapshot?.localTokensToday == nil)
    #expect(snapshot?.todayInput == nil)
    #expect(snapshot?.todayOutput == nil)
}

private func codexYesterday(_ iso: (Date) -> String) -> Data {
    let yesterday = Date(timeIntervalSince1970: 1_755_600_000 - 86_400)
    return Data(
        """
        {"type":"message","timestamp":"\(iso(yesterday))","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","usage":{"input":77777,"output":77777,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":155554}}}
        """.utf8)
}
