import Foundation
import Testing

@testable import HarnessUsageCore

// A movable clock plus counting stubs for the two side-effecting seams (Keychain read, OAuth fetch).
// `final class` + a lock: the provider is an actor and calls these from its own isolation.
private final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _securityCalls = 0
    private var _fetchCalls = 0
    private var _fetchTokens: [String] = []
    private var _keychainBlob: Data?
    private var _outcomes: [ClaudeOAuthUsage.Outcome]

    let home: URL

    init(now: Date, keychainBlob: Data?, outcomes: [ClaudeOAuthUsage.Outcome]) {
        self._now = now
        self._keychainBlob = keychainBlob
        self._outcomes = outcomes
        self.home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hu-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".harness-usage/claude"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
    var securityCalls: Int { lock.withLock { _securityCalls } }
    var fetchCalls: Int { lock.withLock { _fetchCalls } }
    var fetchTokens: [String] { lock.withLock { _fetchTokens } }
    func setKeychainBlob(_ d: Data?) { lock.withLock { _keychainBlob = d } }
    func setOutcomes(_ o: [ClaudeOAuthUsage.Outcome]) { lock.withLock { _outcomes = o } }

    var runSecurity: @Sendable (String) async -> ClaudeCredentials.KeychainRead {
        { [self] _ in
            lock.withLock {
                _securityCalls += 1
                return _keychainBlob.map(ClaudeCredentials.KeychainRead.found) ?? .absent
            }
        }
    }

    // Outcomes are consumed in order; the last one repeats for every further call.
    var fetchUsage: @Sendable (ClaudeCredentials.Token, Date) async -> ClaudeOAuthUsage.Outcome {
        { [self] token, _ in
            lock.withLock {
                _fetchCalls += 1
                _fetchTokens.append(token.accessToken)
                return _outcomes.count > 1 ? _outcomes.removeFirst() : (_outcomes.first ?? .failed)
            }
        }
    }

    func provider() -> ClaudeUsageProvider {
        ClaudeUsageProvider(
            cacheURL: home.appendingPathComponent(".harness-usage/claude/usage-cache.json"),
            home: home, configDir: home.appendingPathComponent(".claude"),
            now: { [self] in now }, runSecurity: runSecurity, fetchUsage: fetchUsage)
    }
}

private func keychainBlob(token: String) -> Data {
    Data(#"{"claudeAiOauth": {"accessToken": "\#(token)", "expiresAt": 99999999999999}}"#.utf8)
}

private func oauthWindow(_ id: String, _ title: String, _ utilization: Double, resetsAt: Date) -> UsageWindow {
    UsageWindow(
        id: id, title: title, utilization: utilization,
        period: id == "5h" ? 5 * 3_600 : 7 * 86_400, resetsAt: resetsAt, kind: .account)
}

private func oauthSnapshot(session: Double?, week: Double?, at: Date, resetsAt: Date) -> UsageSnapshot {
    var windows: [UsageWindow] = []
    if let session { windows.append(oauthWindow("5h", "Session", session, resetsAt: resetsAt)) }
    if let week { windows.append(oauthWindow("7d", "Weekly", week, resetsAt: resetsAt)) }
    return UsageSnapshot(
        windows: windows, localTokensToday: nil, localTokensWeek: nil,
        source: .claudeOAuth, lastUpdated: at)
}

private func window(_ snapshot: UsageSnapshot, id: String) -> UsageWindow? {
    snapshot.windows.first { $0.id == id }
}

private let t0 = Date(timeIntervalSince1970: 1_755_600_000)
private let farReset = t0.addingTimeInterval(100_000)

// ── OAuth and actor level ─────────────────────────────────────────────────────

@Test func seededCacheSurvivesAnOfflineRefreshButExpiredWindowsDoNot() async throws {
    let h = Harness(now: t0, keychainBlob: keychainBlob(token: "tok-a"), outcomes: [.failed])
    let cache = h.home.appendingPathComponent(".harness-usage/claude/usage-cache.json")
    ClaudeUsageProvider.saveCache(
        oauthSnapshot(session: 45, week: 30, at: t0, resetsAt: farReset), to: cache)

    let retained = await h.provider().refresh(force: false, wantEstimate: true)
    #expect(window(retained, id: "5h")?.utilization == 45)
    #expect(window(retained, id: "7d")?.utilization == 30)
    #expect(ClaudeUsageProvider.loadCache(cache).flatMap { window($0, id: "5h")?.utilization } == 45)

    let expired = Harness(now: t0, keychainBlob: keychainBlob(token: "tok-a"), outcomes: [.failed])
    let expiredCache = expired.home.appendingPathComponent(".harness-usage/claude/usage-cache.json")
    ClaudeUsageProvider.saveCache(
        oauthSnapshot(session: 45, week: 30, at: t0, resetsAt: t0.addingTimeInterval(-1)), to: expiredCache)

    let expiredResult = await expired.provider().refresh(force: false, wantEstimate: true)
    #expect(expiredResult.windows.isEmpty)
}

// Defect: merging the per-tick fetch result instead of the retained snapshot — inside the 300s floor
// the fetch returns nothing, so the meters would be dropped on every refresh.
@Test func retainedOAuthSnapshotDoesNotFlapInsideTheFloor() async throws {
    let h = Harness(
        now: t0, keychainBlob: keychainBlob(token: "tok-a"),
        outcomes: [.ok(oauthSnapshot(session: 42, week: 17, at: t0, resetsAt: farReset))])
    let provider = h.provider()

    let first = await provider.refresh(force: true, wantEstimate: false)
    #expect(first.source == .claudeOAuth)
    #expect(window(first, id: "5h")?.utilization == 42)

    // 120s later: past the 15s refresh floor, well inside the 300s OAuth floor.
    h.advance(120)
    let second = await provider.refresh(force: true, wantEstimate: false)
    #expect(h.fetchCalls == 1)  // no second network call
    #expect(second.source == .claudeOAuth)
    #expect(window(second, id: "5h")?.utilization == 42)  // same meters, no flap to the stale capture
}

// Defect: a per-poll `security` spawn returning — a denied Keychain dialog would re-prompt forever.
@Test func credentialsResolveOnceAcrossRepeatedPolls() async throws {
    let h = Harness(
        now: t0, keychainBlob: keychainBlob(token: "tok-a"),
        outcomes: [.ok(oauthSnapshot(session: 42, week: 17, at: t0, resetsAt: farReset))])
    let provider = h.provider()

    _ = await provider.refresh(force: true, wantEstimate: false)
    h.advance(400)  // past both floors, so the OAuth call really does fire again
    _ = await provider.refresh(force: true, wantEstimate: false)

    #expect(h.fetchCalls == 2)
    #expect(h.securityCalls == 1)
}

// Two defects, one contract. Asking on every poll re-spawns `security` forever; latching the answer
// off means an app launched before `claude login` never reads a meter again for the whole run. The
// keychain floor is what separates them: one spawn per half hour, and the login is picked up when it
// appears.
@Test func anAbsentLoginIsRetriedOnTheKeychainFloorRatherThanLatchedOff() async throws {
    let h = Harness(now: t0, keychainBlob: nil, outcomes: [.failed])
    let provider = h.provider()

    let first = await provider.refresh(force: true, wantEstimate: false)
    #expect(first.note == "No Claude login token found on this Mac")
    h.advance(400)  // past the OAuth floor, inside the 1800s keychain floor
    _ = await provider.refresh(force: true, wantEstimate: false)

    #expect(h.securityCalls == 1)  // not asked again inside the floor
    #expect(h.fetchCalls == 0)  // and never fetched without a token

    // The user runs `claude login`. Once the keychain floor elapses the provider finds the token and
    // the OAuth tier comes up on its own.
    h.setKeychainBlob(keychainBlob(token: "tok-a"))
    h.setOutcomes([.ok(oauthSnapshot(session: 42, week: 17, at: t0, resetsAt: farReset))])
    h.advance(1_800)
    let recovered = await provider.refresh(force: true, wantEstimate: false)

    #expect(h.securityCalls == 2)
    #expect(h.fetchCalls == 1)
    #expect(window(recovered, id: "5h")?.utilization == 42)
}

// Defect: a transient 401 during a routine CLI token rotation permanently killing the primary source.
@Test func a401WithARotatedTokenReArmsInsteadOfLatching() async throws {
    let h = Harness(
        now: t0, keychainBlob: keychainBlob(token: "tok-old"),
        outcomes: [
            .ok(oauthSnapshot(session: 20, week: 8, at: t0, resetsAt: farReset)),
            .unauthorized(status: 401),
            .ok(oauthSnapshot(session: 33, week: 12, at: t0.addingTimeInterval(800), resetsAt: farReset)),
        ])
    let provider = h.provider()

    // A good poll first, so the provider is holding "tok-old".
    let first = await provider.refresh(force: true, wantEstimate: false)
    #expect(window(first, id: "5h")?.utilization == 20)

    // The CLI rotates its token; our cached copy is now stale, so the next poll 401s.
    h.setKeychainBlob(keychainBlob(token: "tok-new"))
    h.advance(400)
    let rejected = await provider.refresh(force: true, wantEstimate: false)
    #expect(rejected.note == "Claude login token was rotated; retrying")
    // Defect: clearing the retained OAuth reading before deciding — a routine rotation would blank the
    // OAuth side of the merge for a full 300s even though the reading is still true.
    #expect(window(rejected, id: "5h")?.utilization == 20)

    // Not latched: the next due poll goes out with the adopted token and succeeds.
    h.advance(400)
    let recovered = await provider.refresh(force: true, wantEstimate: false)
    #expect(h.fetchCalls == 3)
    #expect(window(recovered, id: "5h")?.utilization == 33)
}

// Defect: latching on a rotation but NOT on a genuinely rejected login — the endpoint would be hit
// every 300s forever with a token the server has already refused.
@Test func aRejectedTokenRearmsWhenTheCredentialFileRotates() async throws {
    let h = Harness(
        now: t0, keychainBlob: nil,
        outcomes: [
            .unauthorized(status: 401),
            .ok(oauthSnapshot(session: 33, week: 12, at: t0.addingTimeInterval(800), resetsAt: farReset)),
        ])
    let claudeHome = h.home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
    let credentials = claudeHome.appendingPathComponent(".credentials.json")
    try keychainBlob(token: "tok-old").write(to: credentials)
    let provider = h.provider()

    _ = await provider.refresh(force: true, wantEstimate: false)
    try keychainBlob(token: "tok-new").write(to: credentials)
    h.advance(400)
    let recovered = await provider.refresh(force: true, wantEstimate: false)

    #expect(h.fetchCalls == 2)
    #expect(h.fetchTokens == ["tok-old", "tok-new"])
    #expect(window(recovered, id: "5h")?.utilization == 33)
}

@Test func a401WithTheSameTokenLatchesOAuthOffForTheRun() async throws {
    let h = Harness(now: t0, keychainBlob: keychainBlob(token: "tok-a"), outcomes: [.unauthorized(status: 401)])
    let provider = h.provider()

    let first = await provider.refresh(force: true, wantEstimate: false)
    #expect(first.note == "Claude login token expired or rejected")
    h.advance(400)  // past the OAuth floor, inside the keychain floor, so the next resolve is deferred
    let second = await provider.refresh(force: true, wantEstimate: false)

    #expect(h.fetchCalls == 1)  // latched after the re-resolve returned the same token
    // Defect: the deferred-read stub's own message reaching the user as the note, so a rejected login
    // was reported as "Keychain lookup deferred until its 30-minute retry floor" — our retry policy
    // described where the account's actual problem belongs.
    #expect(second.note == "Claude login token expired or rejected")
}

@Test func a403PermanentlyDisablesOAuth() async {
    let h = Harness(
        now: t0, keychainBlob: keychainBlob(token: "tok-a"),
        outcomes: [.unauthorized(status: 403), .ok(oauthSnapshot(session: 33, week: 12, at: t0, resetsAt: farReset))])
    let provider = h.provider()

    let first = await provider.refresh(force: true, wantEstimate: false)
    #expect(first.note == "Claude usage access was refused by the server")
    h.advance(400)
    let second = await provider.refresh(force: true, wantEstimate: false)
    #expect(h.fetchCalls == 1)
    #expect(second.note == "Claude usage access was refused by the server")
}

// Defect: "Update now" dropping only the 15s local floor — the OAuth endpoint is what carries the
// real meters, so a press inside its 300s floor would spin the rings over the same numbers.
@Test func invalidatingThrottlesFetchesInsideTheOAuthFloor() async throws {
    let h = Harness(
        now: t0, keychainBlob: keychainBlob(token: "tok-a"),
        outcomes: [.ok(oauthSnapshot(session: 42, week: 17, at: t0, resetsAt: farReset))])
    let provider = h.provider()

    _ = await provider.refresh(force: false, wantEstimate: false)
    #expect(h.fetchCalls == 1)

    h.advance(120)  // past the 15s refresh floor, well inside the 300s OAuth floor
    _ = await provider.refresh(force: false, wantEstimate: false)
    #expect(h.fetchCalls == 1)

    await provider.invalidateThrottles()
    _ = await provider.refresh(force: false, wantEstimate: false)
    #expect(h.fetchCalls == 2)
}

// Defect: waiving the server's Retry-After along with our own floor — a 429 backoff is not ours to
// drop, and a menu item that can be pressed repeatedly is exactly what would hammer through it.
@Test func invalidatingThrottlesLeavesTheRateLimitBackoffStanding() async throws {
    let h = Harness(
        now: t0, keychainBlob: keychainBlob(token: "tok-a"),
        outcomes: [.rateLimited(retryAfter: t0.addingTimeInterval(600))])
    let provider = h.provider()

    _ = await provider.refresh(force: false, wantEstimate: false)
    #expect(h.fetchCalls == 1)

    h.advance(120)
    await provider.invalidateThrottles()
    _ = await provider.refresh(force: false, wantEstimate: false)
    #expect(h.fetchCalls == 1)  // the hold outlives the press

    h.advance(500)  // past the server's own hint
    _ = await provider.refresh(force: false, wantEstimate: false)
    #expect(h.fetchCalls == 2)
}
