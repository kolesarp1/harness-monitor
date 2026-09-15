import Foundation

// The Claude integration: one `ClaudeUsageProvider` per profile — `~/.claude`, and each `~/.claude-<name>`
// folder signed in to an account (see `ClaudeProfile`) — each with the real meters from the OAuth
// endpoint and the local token estimate underneath, refreshed on its own internal 15s floor.
public actor ClaudeMonitor: IntegrationMonitor {
    private let home: URL
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date
    private let runSecurity: (@Sendable (String) async -> ClaudeCredentials.KeychainRead)?
    private var providers: [String?: ClaudeUsageProvider] = [:]

    // Projects holds the transcripts each profile's token estimate streams. The OAuth endpoint is
    // time-driven, so only transcript writes need to wake this monitor immediately. Taken from the
    // profiles present at launch, because the Engine sets its file watcher up once: a folder signed in to
    // later is still read, on the 60s heartbeat instead of on its next transcript write.
    public nonisolated let watchPaths: [URL]

    public init(
        home: URL, cacheDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        runSecurity: (@Sendable (String) async -> ClaudeCredentials.KeychainRead)? = nil
    ) {
        self.home = home
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.runSecurity = runSecurity
        self.watchPaths = ClaudeProfile.discover(home: home).map(\.projectsDirectory)
    }

    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        let defaultLogin: String? = nil
        return await reloadProfiles(wantUsageEstimate: wantUsageEstimate)[defaultLogin]
    }

    // Discovery runs on every reload — a directory listing and one small state file per extra folder — so
    // a folder signed in to since the last reload starts reading now, and one that is gone or signed out
    // takes its provider with it. A provider that survives keeps its floors, its retained reading and its
    // cached token.
    public func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot] {
        await reloadProfiles(
            wantUsageEstimate: wantUsageEstimate, includeDetected: true,
            policy: UsageReloadPolicy(interval: .fiveMinutes))
    }

    public func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        guard includeDetected else { return [:] }
        var current: [String?: ClaudeUsageProvider] = [:]
        for profile in ClaudeProfile.discover(home: home) {
            current[profile.name] = providers[profile.name] ?? makeProvider(profile)
        }
        providers = current
        return await withTaskGroup(of: (String?, UsageSnapshot).self) { group in
            for (name, provider) in current {
                group.addTask {
                    (
                        name,
                        await provider.refresh(
                            force: policy.bypassAppCadence, wantEstimate: wantUsageEstimate,
                            usageInterval: policy.interval.seconds,
                            bypassUsageCadence: policy.bypassAppCadence)
                    )
                }
            }
            var readings: [String?: UsageSnapshot] = [:]
            for await (name, snapshot) in group { readings[name] = snapshot }
            return readings
        }
    }

    public func invalidateThrottles() async {
        for provider in providers.values { await provider.invalidateThrottles() }
    }

    public func applyAccountBackoffs(_ holds: [String: Date]) async {
        for provider in providers.values { await provider.applyAccountBackoffs(holds) }
    }

    public func accountBackoffs() async -> [String: Date] {
        var result: [String: Date] = [:]
        for provider in providers.values {
            if let (id, hold) = await provider.accountBackoff() { result[id] = max(result[id] ?? .distantPast, hold) }
        }
        return result
    }

    // The default profile keeps the file names it has always had, so an existing cache and parse index are
    // picked up instead of rebuilt.
    private func makeProvider(_ profile: ClaudeProfile) -> ClaudeUsageProvider {
        let file = profile.name.map { "usage-cache-\($0).json" } ?? "usage-cache.json"
        return ClaudeUsageProvider(
            cacheURL: cacheDirectory.appendingPathComponent(file), home: home, configDir: nil, profile: profile,
            now: now, runSecurity: runSecurity)
    }
}
