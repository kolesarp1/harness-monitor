import Foundation

// Codex can keep one login per CODEX_HOME. This monitor discovers the default home plus signed-in
// `~/.codex-<name>` homes and keeps one CodexMonitor per account so their network floors, rollout
// caches and retained meters never bleed into each other.
public actor CodexProfilesMonitor: IntegrationMonitor {
    private let home: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date
    private let urlSession: URLSession
    private let piSessionsDir: URL
    private var monitors: [String?: CodexMonitor] = [:]

    // Roots are fixed when Engine starts. A newly signed-in home is still discovered on the 60-second
    // heartbeat; existing homes include auth.json in their watched root, so account switches wake now.
    public nonisolated let watchPaths: [URL]

    public init(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        urlSession: URLSession? = nil,
        piSessionsDir: URL? = nil
    ) {
        self.home = home
        self.environment = environment
        self.now = now
        self.urlSession = urlSession ?? UsageEndpoint.makeSession(requestTimeout: 15)
        let piSessionsDir = piSessionsDir ?? home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        self.piSessionsDir = piSessionsDir
        // Pi logs do not identify the ChatGPT account that produced their tokens. Keep the parser
        // available, but do not watch or attribute that lane to any Codex profile automatically.
        self.watchPaths = CodexProfile.discover(home: home, environment: environment).map(\.directory)
    }

    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        let defaultLogin: String? = nil
        return await reloadProfiles(wantUsageEstimate: wantUsageEstimate)[defaultLogin]
    }

    public func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot] {
        await reloadProfiles(
            wantUsageEstimate: wantUsageEstimate, includeDetected: true,
            policy: UsageReloadPolicy(interval: .fiveMinutes))
    }

    public func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        guard includeDetected else { return [:] }
        var current: [String?: CodexMonitor] = [:]
        for profile in CodexProfile.discover(home: home, environment: environment) {
            current[profile.name] = monitors[profile.name] ?? makeMonitor(profile)
        }
        monitors = current

        return await withTaskGroup(of: (String?, UsageSnapshot?).self) { group in
            for (name, monitor) in current {
                group.addTask {
                    (
                        name,
                        await monitor.reload(
                            wantUsageEstimate: wantUsageEstimate,
                            usageInterval: policy.interval.seconds,
                            force: policy.bypassAppCadence,
                            bypassUsageCadence: policy.bypassAppCadence)
                    )
                }
            }
            var readings: [String?: UsageSnapshot] = [:]
            for await (name, snapshot) in group {
                if let snapshot { readings[name] = snapshot }
            }
            return readings
        }
    }

    public func invalidateThrottles() async {
        for monitor in monitors.values { await monitor.invalidateThrottles() }
    }

    public func applyAccountBackoffs(_ holds: [String: Date]) async {
        for monitor in monitors.values { await monitor.applyAccountBackoffs(holds) }
    }

    public func accountBackoffs() async -> [String: Date] {
        var result: [String: Date] = [:]
        for monitor in monitors.values {
            for (id, hold) in await monitor.accountBackoffs() { result[id] = max(result[id] ?? .distantPast, hold) }
        }
        return result
    }

    private func makeMonitor(_ profile: CodexProfile) -> CodexMonitor {
        CodexMonitor(
            home: home, now: now, environment: environment, urlSession: urlSession,
            piSessionsDir: piSessionsDir, profile: profile, includePiSessions: false)
    }
}
