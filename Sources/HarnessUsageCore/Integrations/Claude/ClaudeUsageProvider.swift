import Foundation

// Claude's usage comes from two tiers. The OAuth usage endpoint is polled on a 300s floor, and the
// local token estimate adds today's token and cost data. The last successful OAuth snapshot is retained
// while the endpoint is quiet, and the local estimate is the fallback when no OAuth reading is available.
// Everything is cached so the widget is never blank.
public actor ClaudeUsageProvider {
    private let cacheURL: URL
    private let home: URL
    private let configDir: URL?
    private let now: @Sendable () -> Date
    private let minRefresh: TimeInterval
    private let runSecurity: (@Sendable (String) async -> ClaudeCredentials.KeychainRead)?
    // The OAuth call, injectable so tests drive every outcome without a network or a URLProtocol stub.
    private let fetchUsage: @Sendable (ClaudeCredentials.Token, Date) async -> ClaudeOAuthUsage.Outcome

    public private(set) var snapshot: UsageSnapshot?
    private var lastFetch: Date = .distantPast
    private var inFlight: Task<UsageSnapshot, Never>?
    // Per-transcript incremental parse state: appended-only files are re-read from their last
    // offset, so a refresh costs the new bytes, not a full re-parse of the week's transcripts.
    // Backed by the on-disk UsageIndex (loaded lazily on first fetch, delta-written per refresh)
    // so the full-week scan runs once per install, not once per launch.
    private var transcriptCache: LocalUsageEstimator.Cache = [:]
    private var indexLoaded = false
    private var lastEstimate: LocalUsageEstimator.Estimate?
    private var lastEstimateDay: Date?
    // Whether the last actual fetch computed the local token estimate. A change (the user toggling
    // "show token estimate") forces the next fetch past the refresh floor so it takes effect at once.
    private var lastFetchedWantEstimate = true
    // The 300s cadence lives here, not on the monitor: ClaudeMonitor has watchPaths, so any transcript
    // write marks it due and a monitor-level pollInterval could never gate this call. Stamped on EVERY
    // attempt (success, failure, rate-limit) so a failing endpoint is not retried every tick.
    private var lastOAuthAttempt: Date = .distantPast
    private var oauthHoldUntil: Date = .distantPast  // 429 backoff, held apart from our own floor
    private var oauthForbidden = false  // a 403 is permanent for this process run
    private var rejectedToken: ClaudeCredentials.Token?
    private var lastKeychainResolve: Date = .distantPast
    private static let keychainFloor: TimeInterval = 1_800
    // The last SUCCESSFUL OAuth reading, retained across refreshes. It stays visible while the
    // endpoint is inside its 300s floor instead of disappearing on the intervening local refreshes.
    private var lastOAuthSnapshot: UsageSnapshot?
    // Nothing about credential resolution latches. Env and file are re-read every 300s; the Keychain is
    // read on its own 30-minute floor, which is what keeps a Deny from re-prompting — one `security`
    // spawn per half hour, and none at all while a token is cached.
    private var cachedToken: ClaudeCredentials.Token?
    // The last real OAuth windows, re-emitted when a fetch yields none. Without this a single failed
    // fetch writes a window-less snapshot over the cache and the meters vanish. The origin travels with
    // them so the carried snapshot reports where its numbers actually came from.
    private var lastRealWindows: (windows: [UsageWindow], at: Date, source: UsageSource)?
    // Set when the OAuth tier is asked for but cannot deliver, so the UI can say why instead of
    // silently showing nothing.
    public private(set) var note: String?
    private static let oauthFloor: TimeInterval = 300

    private func indexPath() -> String {
        cacheURL.deletingLastPathComponent().appendingPathComponent("usage-index.sqlite").path
    }

    public init(
        cacheURL: URL, home: URL, configDir: URL?,
        now: @escaping @Sendable () -> Date = { Date() }, minRefresh: TimeInterval = 15,
        runSecurity: (@Sendable (String) async -> ClaudeCredentials.KeychainRead)? = nil,
        urlSession: URLSession? = nil,
        fetchUsage: (@Sendable (ClaudeCredentials.Token, Date) async -> ClaudeOAuthUsage.Outcome)? = nil
    ) {
        self.cacheURL = cacheURL
        self.home = home
        self.configDir = configDir
        self.now = now
        self.minRefresh = minRefresh
        self.runSecurity = runSecurity
        let session = urlSession ?? UsageEndpoint.makeSession(requestTimeout: 15)
        self.fetchUsage = fetchUsage ?? { token, at in await ClaudeOAuthUsage.fetch(token: token, session: session, now: at) }
        let loaded = ClaudeUsageProvider.loadCache(cacheURL)
        self.snapshot = loaded
        if let loaded {
            let windows = loaded.windows.compactMap { window in
                UsageMath.window(
                    id: window.id, title: window.title, percent: window.utilization,
                    period: window.period, resetsAt: window.resetsAt, kind: window.kind, now: now())
            }
            if !windows.isEmpty {
                self.lastRealWindows = (windows, loaded.lastUpdated, loaded.source)
            }
        }
    }

    private func claudeDir() -> URL { configDir ?? home.appendingPathComponent(".claude") }
    private func projectsDir() -> URL { claudeDir().appendingPathComponent("projects") }
    // Floored unless forced; coalesces concurrent callers onto one in-flight fetch. `wantEstimate`
    // (the user's "show token estimate" setting) gates the expensive transcript scan; a change in it
    // bypasses both the floor and the coalescing so the toggle takes effect on the next Claude
    // *reload* rather than waiting out the 15s floor. That reload is heartbeat-bounded (≤60s when
    // Claude is idle, immediate on the next transcript event while it's active), since a settings
    // change marks no watched root dirty — the strip's visibility itself is instant (UI-gated).
    //
    // Assumes a single serialized caller (the engine tick awaits each reload before the next; one
    // Claude monitor). It is NOT safe for concurrent callers with differing `wantEstimate` — the
    // coalescing could hand one a stale-mode snapshot; don't add a second caller without keying
    // `inFlight` by mode.
    public func refresh(force: Bool, wantEstimate: Bool) async -> UsageSnapshot {
        let changed = wantEstimate != lastFetchedWantEstimate
        if let cached = snapshot, !changed,
            !UsageMath.shouldFetch(force: force, lastFetch: lastFetch, now: now(), minRefresh: minRefresh)
        {
            return cached
        }
        if !changed, let task = inFlight { return await task.value }
        let task = Task { await self.performFetch(wantEstimate: wantEstimate) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    // Both of this provider's own floors: the 15s local one and the OAuth endpoint's 300s. The 403
    // latch and the Keychain's own retry floor stand — one is permanent for the run, the other is what
    // stops a refused credential turning into a password prompt every time this is pressed.
    public func invalidateThrottles() {
        lastFetch = .distantPast
        lastOAuthAttempt = .distantPast
    }

    private func performFetch(wantEstimate: Bool) async -> UsageSnapshot {
        lastFetchedWantEstimate = wantEstimate

        // The OAuth endpoint, attempted on every refresh but self-gated to a 300s floor. It updates
        // `lastOAuthSnapshot` on success; reading the retained snapshot inside the floor keeps its
        // meters visible while the local refresh continues.
        await refreshOAuthIfDue()
        let live = lastOAuthSnapshot
        if let live { lastRealWindows = (live.windows, live.lastUpdated, live.source) }

        // Estimate disabled: skip the transcript scan entirely — the app's most expensive per-refresh
        // step. With no OAuth reading there is nothing to show, so a fresh empty snapshot lets the
        // widget render its "estimate disabled"/empty state.
        guard wantEstimate else {
            transcriptCache = [:]
            lastEstimate = nil
            lastEstimateDay = nil
            indexLoaded = false
            return complete(live ?? carryingLastReal(), persist: true)
        }

        if !indexLoaded {
            transcriptCache = UsageIndex.load(at: indexPath())
            indexLoaded = true
        }
        // One `now()` for the whole fetch: the scan's day and the stored `lastEstimateDay` must agree,
        // else a midnight straddle between two reads could make the next no-op skip return stale totals.
        let n = now()
        let scan = LocalUsageEstimator.scan(
            projectsDir: projectsDir(), now: n, cache: transcriptCache,
            previous: lastEstimate, previousDay: lastEstimateDay)
        transcriptCache = scan.cache
        lastEstimate = scan.estimate
        lastEstimateDay = Calendar.current.startOfDay(for: n)
        UsageIndex.apply(
            at: indexPath(),
            parsed: scan.parsedPaths.compactMap { p in scan.cache[p].map { (p, $0) } },
            removed: scan.removedPaths)
        let est = scan.estimate
        if var live2 = live {
            live2.localTokensToday = est.today
            live2.localTokensWeek = est.week
            live2.todayInput = est.todayInput
            live2.todayOutput = est.todayOutput
            live2.estimatedCostUSD = est.todayCostUSD
            return complete(live2, persist: true)
        }
        var fallback = carryingLastReal()
        fallback.localTokensToday = est.today
        fallback.localTokensWeek = est.week
        fallback.todayInput = est.todayInput
        fallback.todayOutput = est.todayOutput
        fallback.estimatedCostUSD = est.todayCostUSD
        return complete(fallback, persist: true)
    }

    // The no-real-reading snapshot, carrying the last real windows forward so a transient failure
    // doesn't blank the meters. The previous snapshot's `lastUpdated` stays fixed while this tier is
    // silent: it is part of `UsageSnapshot`'s equality, which is what gates the store write in
    // `Engine.tick`, so restamping it would republish an unchanged reading on every refresh — and it is
    // the timestamp `--dump` prints.
    private func carryingLastReal() -> UsageSnapshot {
        guard let last = lastRealWindows, !last.windows.isEmpty else {
            return UsageSnapshot(
                windows: [], localTokensToday: nil, localTokensWeek: nil,
                source: .localEstimate, lastUpdated: now())
        }
        return UsageSnapshot(
            windows: last.windows, localTokensToday: nil, localTokensWeek: nil,
            source: last.source, lastUpdated: snapshot?.lastUpdated ?? now())
    }

    // One OAuth attempt, behind the 300s floor and the 401 latch. Updates `lastOAuthSnapshot` on
    // success and leaves it untouched on every other path, so a transient failure keeps the last real
    // reading on screen with its true (now visibly older) timestamp.
    private func refreshOAuthIfDue() async {
        guard !oauthForbidden else { return }
        guard now() >= oauthHoldUntil else { return }
        guard now().timeIntervalSince(lastOAuthAttempt) >= Self.oauthFloor else { return }
        lastOAuthAttempt = now()
        guard let token = await resolveToken() else { return }
        switch await fetchUsage(token, now()) {
        case .ok(let snapshot):
            note = nil
            rejectedToken = nil
            cachedToken = token
            lastOAuthSnapshot = snapshot
        case .unauthorized(let status):
            await handleUnauthorized(previous: token, status: status)
        case .rateLimited(let retryAfter):
            // Hold off until whichever is later: the server's own hint, or the standard floor. Kept
            // apart from `lastOAuthAttempt` because the two answer to different people —
            // `invalidateThrottles` waives ours and leaves this one standing.
            if let retryAfter { oauthHoldUntil = max(oauthHoldUntil, retryAfter) }
            note = "Claude usage endpoint is rate-limiting; retrying later"
        case .failed:
            note = "Could not reach the Claude usage endpoint"
        }
    }

    // Resolve env/file every due cycle after a rejection. A Keychain read is allowed only on its
    // separate floor, so a refused token cannot turn into an ACL prompt every five minutes.
    private func resolveToken(forceKeychain: Bool = false) async -> ClaudeCredentials.Token? {
        if rejectedToken == nil, let cachedToken { return cachedToken }
        let resolution: ClaudeCredentials.Resolution
        var keychainDeferred = false
        if let runSecurity {
            let canReadKeychain = forceKeychain || now().timeIntervalSince(lastKeychainResolve) >= Self.keychainFloor
            if canReadKeychain {
                lastKeychainResolve = now()
                resolution = await ClaudeCredentials.resolve(
                    home: home, configDir: configDir, runSecurity: runSecurity)
            } else {
                keychainDeferred = true
                resolution = await ClaudeCredentials.resolve(
                    home: home, configDir: configDir,
                    runSecurity: { _ in .failed("Claude Keychain lookup deferred until its 30-minute retry floor") })
            }
        } else {
            resolution = await ClaudeCredentials.resolve(home: home, configDir: configDir)
        }
        switch resolution {
        case .found(let token):
            if let rejectedToken, rejectedToken != token {
                self.rejectedToken = nil
            }
            if self.rejectedToken == nil { cachedToken = token }
            return token
        case .absent:
            // NOT latched. The user logs the CLI in on their own schedule, and a latch here meant an app
            // launched before `claude login` never read a meter again for the whole run. Asking again
            // costs one `security` spawn per keychain floor — and no ACL dialog, because a missing item
            // is answered without one.
            note = "No Claude login token found on this Mac"
            return nil
        case .unavailable(let reason):
            // The deferred-read stub is our own throttle reporting in, not a fact about the account:
            // publishing it would replace a real explanation ("login token expired or rejected") with a
            // description of our retry floor.
            if !keychainDeferred { note = reason }
            return nil
        }
    }

    // A 401 usually means the CLI rotated its token and our cached copy is simply behind — latching
    // OAuth off for the run on the first one would kill the primary source over a routine rotation.
    // So: re-resolve exactly once. A DIFFERENT token is adopted and retried on the next due fetch; the
    // SAME token means the login itself is rejected, and only then does the latch engage.
    // The retained snapshot is dropped only where the latch engages: a rotation is a routine event and
    // the reading it produced minutes ago is still the truth about the account, so clearing it up front
    // would blank the merge's OAuth side for a full 300s over nothing.
    private func handleUnauthorized(previous: ClaudeCredentials.Token, status: Int) async {
        cachedToken = nil
        guard status == 401 else {
            oauthForbidden = true
            rejectedToken = nil
            lastOAuthSnapshot = nil
            note = "Claude usage access was refused by the server"
            return
        }
        let wasAlreadyRejected = rejectedToken != nil
        rejectedToken = previous
        guard let refreshed = await resolveToken(forceKeychain: !wasAlreadyRejected) else { return }
        guard refreshed != previous else {
            cachedToken = nil
            lastOAuthSnapshot = nil
            note = "Claude login token expired or rejected"
            return
        }
        rejectedToken = nil
        cachedToken = refreshed
        note = "Claude login token was rotated; retrying"
    }

    @discardableResult
    private func complete(_ snap: UsageSnapshot, persist: Bool) -> UsageSnapshot {
        var snap = snap
        snap.note = note
        if persist { ClaudeUsageProvider.saveCache(snap, to: cacheURL) }
        snapshot = snap
        lastFetch = now()  // stamped on COMPLETION so the refresh floor measures from when work ended
        return snap
    }
}

extension ClaudeUsageProvider {
    private struct CachedWindow: Codable {
        var id: String
        var title: String
        var utilization: Double
        var period: TimeInterval?
        var resetsAt: Date?
        var kind: String
    }
    private struct CachedSnapshot: Codable {
        var version: Int
        var windows: [CachedWindow]
        var localTokensToday: Int?
        var localTokensWeek: Int?
        var source: String
        var lastUpdated: Date
        var todayInput: Int?
        var todayOutput: Int?
        var estimatedCostUSD: Double?
    }

    private static let cacheVersion = 7  // 7: model names are carried by UsageWindow.Kind

    public static func saveCache(_ snap: UsageSnapshot, to url: URL) {
        let dto = CachedSnapshot(
            version: cacheVersion,
            windows: snap.windows.map {
                CachedWindow(
                    id: $0.id, title: $0.title, utilization: $0.utilization, period: $0.period,
                    resetsAt: $0.resetsAt, kind: $0.kind.rawValue)
            },
            localTokensToday: snap.localTokensToday, localTokensWeek: snap.localTokensWeek,
            source: snap.source.rawValue, lastUpdated: snap.lastUpdated,
            todayInput: snap.todayInput, todayOutput: snap.todayOutput,
            estimatedCostUSD: snap.estimatedCostUSD)
        guard let data = try? JSONEncoder().encode(dto) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    public static func loadCache(_ url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
            let dto = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
            dto.version == cacheVersion  // stale/incompatible cache -> discard, re-fetch
        else { return nil }
        let windows = dto.windows.compactMap { cached -> UsageWindow? in
            guard let kind = UsageWindow.Kind(rawValue: cached.kind) else { return nil }
            return UsageWindow(
                id: cached.id, title: cached.title, utilization: cached.utilization, period: cached.period,
                resetsAt: cached.resetsAt, kind: kind)
        }
        return UsageSnapshot(
            windows: windows, localTokensToday: dto.localTokensToday, localTokensWeek: dto.localTokensWeek,
            source: UsageSource(rawValue: dto.source) ?? .localEstimate,  // unknown/newer -> safe default
            lastUpdated: dto.lastUpdated,
            todayInput: dto.todayInput, todayOutput: dto.todayOutput,
            estimatedCostUSD: dto.estimatedCostUSD)
    }
}
