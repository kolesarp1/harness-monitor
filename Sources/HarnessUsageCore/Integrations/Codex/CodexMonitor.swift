import Foundation

// The Codex integration, in two tiers. The LIVE tier reads Codex's own 5h/weekly meters from the
// ChatGPT backend using the access token the CLI already stores in `auth.json` (read-only, never
// refreshed — see `CodexAuth`), on its own 300s floor. Underneath sits the passive rollout tier:
// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (or `$CODEX_HOME/sessions` — see `codexRoot`), which
// prefers Codex's own rate limits from the freshest RATE-LIMIT-BEARING rollout and drops an elapsed
// window when the cached file is read, so a reset meter cannot stay on screen forever. A null-limit
// session beside a Pro one doesn't wipe the last rate-limit-bearing reading. It falls back to today's
// cumulative token count when those are null (API-key / no-plan setups). The rollout tier always runs:
// it supplies today's token counts, cost and model even when the live meters replace its percentages.
//
// Pattern adapted from the anthrocite reference (`CodexLive.swift`). Internal 2s throttle: the Engine
// calls `reload` every 400ms but the file scan runs at most every 2s; cached results in between.
// Scans 7 days back (covering the weekly window); only today's files contribute to the "tokens today"
// fallback sum.
public actor CodexMonitor: IntegrationMonitor {
    private let sessionsDir: URL  // `<codexRoot>/sessions`, resolved once at init (honors CODEX_HOME)
    private let codexRoot: URL  // this account's config root — where its `auth.json` lives
    private let piSessionsDir: URL  // `<home>/.pi/agent/sessions` — harness-driven Codex model usage
    private let home: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date
    private let urlSession: URLSession
    private var lastScan: Date = .distantPast
    private var cached: UsageSnapshot?
    private var fileCache: [URL: (mtime: Date, info: FileInfo)] = [:]  // skip re-read+re-parse on unchanged files
    private var piCache: [URL: (mtime: Date, days: [String: PiDaySums])] = [:]  // same, for pi session logs
    // Pi session files actually opened. The cache's guarantee — an unchanged file is never read twice —
    // leaves no trace in the snapshot it produces, so this is what a test can assert on.
    private(set) var piFileReads = 0
    // Live-tier state. `lastFetch` is stamped on every attempt (success or failure) so a dead endpoint
    // is not retried on every 2s scan; `liveMeters` is the last good reading, retained so a refresh
    // inside the floor keeps showing it instead of dropping back to the rollout percentages.
    private var lastFetch: Date = .distantPast
    private var liveMeters: UsageSnapshot?
    private var liveNote: String?
    private var holdUntil: Date = .distantPast  // 429 backoff

    private static let scanInterval: TimeInterval = 2
    private static let scanDays = 7  // cover the weekly window; most date dirs won't exist
    private static let fetchFloor: TimeInterval = 300

    // `codexRoot` pins this account's config root. nil keeps the pre-accounts behaviour — $CODEX_HOME
    // when set, else `~/.codex` — which is right for the default account and wrong for any other,
    // since one CODEX_HOME cannot name two logins.
    public init(
        home: URL,
        codexRoot: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        urlSession: URLSession? = nil,
        piSessionsDir: URL? = nil
    ) {
        let root = codexRoot ?? Self.codexRoot(home: home, environment: environment)
        self.codexRoot = root
        self.sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        self.piSessionsDir =
            piSessionsDir ?? home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        self.home = home
        self.environment = environment
        self.now = now
        self.urlSession = urlSession ?? UsageEndpoint.makeSession(requestTimeout: 15)
    }

    // The Codex config root: `$CODEX_HOME` when set (first comma-separated entry, tilde-expanded),
    // else `<home>/.codex`. Read once at init so the scan stays pure/offline. Sessions live under
    // `<root>/sessions/YYYY/MM/DD/`.
    public static func codexRoot(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment["CODEX_HOME"], let first = raw.split(separator: ",").first {
            let path = (first.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    private struct FileInfo {
        var primary: UsageWindow?
        var secondary: UsageWindow?
        var expiredRateLimits: Bool
        var totalTokens: Int?
        var input: Int?  // cumulative input (incl. cached) for the fallback card / cost
        var output: Int?
        var estCostUSD: Double?  // approximate cumulative USD for this session (token split × price table)
    }

    public nonisolated var watchPaths: [URL] { [sessionsDir, piSessionsDir] }

    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        if now().timeIntervalSince(lastScan) < Self.scanInterval, let cached {
            return cached
        }
        await refreshLiveIfDue()
        let result = Self.merged(
            rollout: scan(wantUsageEstimate: wantUsageEstimate), live: liveMeters, liveNote: liveNote,
            now: cached?.lastUpdated ?? now())
        cached = result
        lastScan = now()
        return result
    }

    // Both floors, the file scan's and the live tier's. `holdUntil` is left alone: that one is the
    // endpoint's own 429 backoff, not our floor.
    public func invalidateThrottles() {
        lastScan = .distantPast
        lastFetch = .distantPast
    }

    // The live meters replace the rollout-derived percentages; everything else the rollout knows
    // (today's tokens, the cost estimate, its own `lastUpdated`) stays, because the endpoint reports
    // none of it. With no live reading the rollout snapshot passes through untouched.
    nonisolated static func merged(
        rollout: UsageSnapshot?, live: UsageSnapshot?, liveNote: String?, now: Date
    ) -> UsageSnapshot? {
        guard let live else {
            guard var rollout else {
                // Nothing anywhere — still say why the live tier declined, rather than showing nothing.
                // `now` is the previous cached reading time when the monitor is silent, so a note alone
                // does not restamp the snapshot as freshly read.
                guard let liveNote else { return nil }
                return UsageSnapshot(
                    windows: [], localTokensToday: nil, localTokensWeek: nil,
                    source: .codexLocal, lastUpdated: now, note: liveNote)
            }
            rollout.note = note(rolloutNote: rollout.note, liveNote: liveNote, hasWindows: !rollout.windows.isEmpty)
            return rollout
        }
        guard var merged = rollout else {
            var live = live
            live.note = liveNote
            return live
        }
        let rolloutNote = merged.note
        // Wholesale, not field-by-field: the endpoint is the authority on the account's shape as well
        // as its numbers. A `prolite` plan answers with `secondary_window: null` and a single 7-day
        // `primary_window`, so keeping a rollout-derived 5h window here would publish a meter this
        // account does not have — under `source: .codexUsageAPI` and the live timestamp, which claims
        // the endpoint reported it.
        // The endpoint is authoritative on the complete window shape, including a missing account
        // cap and all model-scoped caps it reports.
        merged.windows = live.windows
        merged.source = .codexUsageAPI
        merged.lastUpdated = live.lastUpdated
        merged.note = note(rolloutNote: rolloutNote, liveNote: liveNote, hasWindows: !merged.windows.isEmpty)
        return merged
    }

    // Which of the two notes the user reads. With meters on screen the live note is the useful one — it
    // says why the endpoint declined while the rollout's percentages carry on. With no meters at all,
    // the rollout's own note ("rate-limit window expired") is the only account of why the row is empty,
    // so overwriting it with the live note — or with nil — leaves the emptiest state unexplained.
    nonisolated static func note(rolloutNote: String?, liveNote: String?, hasWindows: Bool) -> String? {
        if !hasWindows, let rolloutNote { return rolloutNote }
        return liveNote
    }

    // One live attempt, behind the 300s floor and the 429 holdoff. Leaves `liveMeters` untouched on
    // every failure path so a transient outage keeps the last real reading on screen.
    private func refreshLiveIfDue() async {
        guard now() >= holdUntil else { return }
        guard now().timeIntervalSince(lastFetch) >= Self.fetchFloor else { return }
        lastFetch = now()  // stamped before the call so a failure throttles the retry too

        guard let token = CodexAuth.read(root: codexRoot) else {
            // Signing out mid-run removes auth.json; keeping the last live meters would show the
            // signed-out user percentages from an account we can no longer read.
            liveMeters = nil
            liveNote = "No Codex login found under \(codexRoot.path)"
            return
        }
        guard !token.isExpired(now: now()) else {
            liveMeters = nil
            liveNote = "Codex login expired — using local session data"
            return
        }
        switch await CodexUsageClient.fetch(token: token, session: urlSession, now: now()) {
        case .ok(let snapshot):
            liveMeters = snapshot
            liveNote = nil
        case .unauthorized:
            liveMeters = nil
            liveNote = "Codex login expired — using local session data"
        case .rateLimited(let retryAfter):
            holdUntil = retryAfter ?? now().addingTimeInterval(Self.fetchFloor)
            liveNote = "Codex is rate-limiting; retrying later"
        case .failed:
            liveNote = "Could not reach the Codex usage endpoint"
        }
    }

    // Scans `scanDays` of rollout dirs (today + N days back). Each file is parsed once (cached per
    // mtime): it contributes its rate limits when it's the freshest rate-limit-bearing file, and its
    // token total to today's fallback sum (today's files only). `wantUsageEstimate` gates the pi lane,
    // whose only output is the token strip; the rollout lane always runs, because the meters come from it.
    public func scan(wantUsageEstimate: Bool = true) -> UsageSnapshot? {
        let fm = FileManager.default
        let nowDate = now()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        var newestMTime = Date.distantPast  // freshest file → usage `lastUpdated`
        var newestLimitsMTime = Date.distantPast  // freshest RATE-LIMIT-BEARING file → the meters (B5)
        var newestPrimary: UsageWindow?
        var newestSecondary: UsageWindow?
        var sawExpiredLimits = false
        var todayTokens = 0
        var sawTodayTokens = false
        var todayInput = 0
        var todayOutput = 0
        var todayCostUSD = 0.0
        var sawTodayBreakdown = false
        let todayDC = cal.dateComponents([.year, .month, .day], from: nowDate)  // "today" by mtime, not dir name

        for offset in 0..<Self.scanDays {
            let day = cal.date(byAdding: .day, value: -offset, to: nowDate) ?? nowDate  // DST-safe calendar day
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let sub = String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let dir = sessionsDir.appendingPathComponent(sub, isDirectory: true)
            guard
                let files = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles])
            else { continue }

            for rawURL in files where rawURL.pathExtension == "jsonl" {
                let url = rawURL.standardizedFileURL
                guard
                    let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                    let mtime = rv.contentModificationDate
                else { continue }

                // Skip re-read + re-parse when the file hasn't changed since last scan.
                let info: FileInfo
                if let c = fileCache[url], c.mtime == mtime {
                    info = c.info
                } else {
                    guard let parsed = parse(url, now: nowDate) else { continue }
                    info = parsed
                    fileCache[url] = (mtime, info)
                }

                if mtime > newestMTime { newestMTime = mtime }  // freshest file → usage `lastUpdated`
                // Rate limits come from the freshest rate-limit-BEARING rollout, not just the freshest
                // file — else a free-plan/API-key session (null limits) writing beside a Pro session
                // would wipe a still-valid meter (B5).
                if info.primary != nil || info.secondary != nil || info.expiredRateLimits, mtime > newestLimitsMTime {
                    newestLimitsMTime = mtime
                    newestPrimary = info.primary
                    newestSecondary = info.secondary
                    sawExpiredLimits = info.expiredRateLimits
                }
                // A session that started yesterday but is still active today (mtime today) should count
                // its tokens toward "today" — gate on the mtime's calendar day, not the date dir's name.
                let mtimeDC = cal.dateComponents([.year, .month, .day], from: mtime)
                let isToday =
                    mtimeDC.year == todayDC.year && mtimeDC.month == todayDC.month
                    && mtimeDC.day == todayDC.day
                if let t = info.totalTokens, isToday {
                    todayTokens += t
                    sawTodayTokens = true
                }
                if isToday, let input = info.input, let output = info.output {
                    todayInput += input
                    todayOutput += output
                    todayCostUSD += info.estCostUSD ?? 0
                    sawTodayBreakdown = true
                }
            }
        }

        // Drop cache entries for files that no longer exist (old date dirs rolled off the scan window).
        let scannedDirs = Set(
            (0..<Self.scanDays).compactMap { offset in
                let day = cal.date(byAdding: .day, value: -offset, to: nowDate) ?? nowDate
                let c = cal.dateComponents([.year, .month, .day], from: day)
                let sub = String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
                return sessionsDir.appendingPathComponent(sub, isDirectory: true).standardizedFileURL.path
            })
        fileCache = Self.evict(fileCache, scannedDirs: scannedDirs)

        // Harness-driven usage: the same account's meters burned through pi (`openai-codex` provider)
        // never touch the rollout logs, so their token counts come from pi's own session logs.
        let pi = wantUsageEstimate ? scanPiSessions(nowDate: nowDate, calendar: cal) : (sums: nil, newestMTime: Date.distantPast)

        var tIn = sawTodayBreakdown ? todayInput : nil
        var tOut = sawTodayBreakdown ? todayOutput : nil
        var estCost = sawTodayBreakdown ? todayCostUSD : nil
        if let p = pi.sums {
            // Rollout `input` INCLUDES its cached subset; pi reports reads separately, so they are added
            // back here to keep one convention across the merged lane.
            tIn = (tIn ?? 0) + p.input + p.cached
            tOut = (tOut ?? 0) + p.output
            estCost =
                (estCost ?? 0)
                + ModelPricing.codexCost(input: p.input + p.cached, cached: p.cached, output: p.output)
        }
        let sawAnyTokens = sawTodayTokens || pi.sums != nil
        let tokenTotal = todayTokens + (pi.sums?.total ?? 0)
        let freshestUpdate = max(newestMTime, pi.newestMTime)

        // Expiry is decided HERE, against the current clock, not at parse time. The file cache is keyed
        // on mtime, so an idle Codex re-publishes the window its last parse materialised — for as long
        // as nothing writes a rollout, which on a quiet day is hours past the reset. A dropped window
        // folds into `sawExpiredLimits` so the same note fires as when the parse itself saw it elapsed.
        func unexpired(_ window: UsageWindow?) -> UsageWindow? {
            guard let window else { return nil }
            guard let resetsAt = window.resetsAt, nowDate >= resetsAt else { return window }
            sawExpiredLimits = true
            return nil
        }
        newestPrimary = unexpired(newestPrimary)
        newestSecondary = unexpired(newestSecondary)

        if newestPrimary != nil || newestSecondary != nil {
            return UsageSnapshot(
                windows: [newestPrimary, newestSecondary].compactMap { $0 },
                localTokensToday: sawAnyTokens ? tokenTotal : nil, localTokensWeek: nil,
                // The percentages came from the rollout's rate-limit event. Pi mtime only dates the
                // token lane and must not make the meters look newer than their own reading.
                source: .codexLocal, lastUpdated: newestLimitsMTime,
                todayInput: tIn, todayOutput: tOut,
                estimatedCostUSD: estCost)
        }
        if sawExpiredLimits {
            let updated = max(
                newestLimitsMTime == .distantPast ? newestMTime : newestLimitsMTime, freshestUpdate)
            return UsageSnapshot(
                windows: [], localTokensToday: sawAnyTokens ? tokenTotal : nil, localTokensWeek: nil,
                source: .codexLocal, lastUpdated: updated,
                todayInput: tIn, todayOutput: tOut,
                estimatedCostUSD: estCost,
                note: "Codex rate-limit window expired — using local session data")
        }
        if sawAnyTokens {  // no rate limits (API-key / no-plan) — show today's token total
            return UsageSnapshot(
                windows: [], localTokensToday: tokenTotal, localTokensWeek: nil,
                source: .codexLocal,
                lastUpdated: freshestUpdate == .distantPast ? nowDate : freshestUpdate,
                todayInput: tIn, todayOutput: tOut,
                estimatedCostUSD: estCost)
        }
        return nil
    }

    // Sums today's openai-codex assistant messages across pi's session logs, with the same per-mtime
    // cache pattern as the rollout scan: an unchanged file is never re-read or re-parsed. The cache is
    // rebuilt over the full walk each scan, so deleted files drop out naturally.
    private func scanPiSessions(nowDate: Date, calendar: Calendar) -> (sums: PiDaySums?, newestMTime: Date) {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: piSessionsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return (nil, .distantPast) }

        let startOfDay = calendar.startOfDay(for: nowDate)
        let todayKey = PiSessionTokens.dayKey(for: nowDate, calendar: calendar)
        var totals = PiDaySums()
        var sawAny = false
        var newest = Date.distantPast
        var newCache: [URL: (mtime: Date, days: [String: PiDaySums])] = [:]

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard
                let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let mtime = rv.contentModificationDate,
                mtime >= startOfDay
            else { continue }
            if mtime > newest { newest = mtime }
            if let cached = piCache[url], cached.mtime == mtime {
                newCache[url] = cached
            } else {
                // The empty result is cached too. Most pi session logs hold no codex messages at all,
                // and caching only the non-empty ones re-read every one of them on every 2s scan for
                // the life of the process. The mtime key still forces a re-read of a file that changes.
                piFileReads += 1
                newCache[url] = (mtime, PiSessionTokens.parseFile(url, calendar: calendar))
            }
            if let sums = newCache[url]?.days[todayKey] {
                totals.input += sums.input
                totals.cached += sums.cached
                totals.output += sums.output
                totals.total += sums.total
                sawAny = true
            }
        }
        piCache = newCache
        return (sawAny ? totals : nil, newest)
    }

    nonisolated static func evict<T>(_ cache: [URL: T], scannedDirs: Set<String>) -> [URL: T] {
        cache.filter { scannedDirs.contains($0.key.deletingLastPathComponent().standardizedFileURL.path) }
    }

    // Tail (last 32 KB) → rate limits and token totals. Parsed once into objects so the extractors
    // don't each re-parse every line.
    private func parse(_ url: URL, now: Date) -> FileInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }

        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 32_768 ? size - 32_768 : 0)
        let objects = (try? h.readToEnd()).map { CodexRollout.parseObjects(fromTail: CodexRollout.lines(fromTail: $0)) } ?? []
        let limits = CodexRollout.rateLimits(fromParsed: objects, now: now)
        let tokens = CodexRollout.totalTokens(fromParsed: objects)
        let breakdown = CodexRollout.tokenBreakdown(fromParsed: objects)
        // O14: approximate cumulative USD for this session (reasoning folds into the output lane).
        let reasoning = CodexRollout.reasoningOutput(fromParsed: objects)
        let estCostUSD = breakdown.map {
            ModelPricing.codexCost(input: $0.input, cached: $0.cached, output: $0.output + reasoning)
        }
        return FileInfo(
            primary: limits.primary, secondary: limits.secondary, expiredRateLimits: limits.expired, totalTokens: tokens,
            input: breakdown?.input, output: breakdown?.output,
            estCostUSD: estCostUSD)
    }
}
