import Foundation
import Testing

@testable import HarnessUsageCore

private actor EngineMonitorStub: IntegrationMonitor {
    let snapshot: UsageSnapshot?
    private(set) var reloads = 0
    private(set) var invalidations = 0
    private(set) var policies: [UsageReloadPolicy] = []

    init(snapshot: UsageSnapshot?) { self.snapshot = snapshot }

    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        reloads += 1
        return snapshot
    }

    func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        reloads += 1
        policies.append(policy)
        guard includeDetected, let snapshot else { return [:] }
        let defaultLogin: String? = nil
        return [defaultLogin: snapshot]
    }

    func invalidateThrottles() { invalidations += 1 }
}

private actor EngineOneShotGate {
    private var shouldPause = true
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseAfterResolve() async {
        guard shouldPause else { return }
        shouldPause = false
        started = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters = []
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor EngineDetectedProfilesMonitor: IntegrationMonitor {
    let readings: [String?: UsageSnapshot]

    init(readings: [String?: UsageSnapshot]) { self.readings = readings }

    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? { nil }
    func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        includeDetected ? readings : [:]
    }
}

private actor PostResolveBlockingMonitor: IntegrationMonitor {
    let wrapped: any IntegrationMonitor
    let gate: EngineOneShotGate
    private(set) var reloads = 0

    init(wrapped: any IntegrationMonitor, gate: EngineOneShotGate) {
        self.wrapped = wrapped
        self.gate = gate
    }

    nonisolated var watchPaths: [URL] { wrapped.watchPaths }
    nonisolated var pollInterval: TimeInterval? { wrapped.pollInterval }

    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        await wrapped.reload(wantUsageEstimate: wantUsageEstimate)
    }

    func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        reloads += 1
        let resolved = await wrapped.reloadProfiles(
            wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
            policy: policy)
        await gate.pauseAfterResolve()
        return resolved
    }

    func reloadForEngine(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> IntegrationReloadResult {
        reloads += 1
        let resolved = await wrapped.reloadForEngine(
            wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
            policy: policy)
        await gate.pauseAfterResolve()
        return resolved
    }

    func disposition(for result: IntegrationReloadResult) async -> IntegrationReloadDisposition {
        await wrapped.disposition(for: result)
    }

    func invalidateThrottles() async { await wrapped.invalidateThrottles() }
    func applyAccountBackoffs(_ holds: [String: Date]) async {
        await wrapped.applyAccountBackoffs(holds)
    }
    func accountBackoffs() async -> [String: Date] { await wrapped.accountBackoffs() }
}

private actor CountingIntegrationMonitor: IntegrationMonitor {
    let wrapped: any IntegrationMonitor
    private(set) var reloads = 0

    init(wrapped: any IntegrationMonitor) { self.wrapped = wrapped }

    nonisolated var watchPaths: [URL] { wrapped.watchPaths }
    nonisolated var pollInterval: TimeInterval? { wrapped.pollInterval }

    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        await wrapped.reload(wantUsageEstimate: wantUsageEstimate)
    }

    func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        reloads += 1
        return await wrapped.reloadProfiles(
            wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
            policy: policy)
    }

    func reloadForEngine(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> IntegrationReloadResult {
        reloads += 1
        return await wrapped.reloadForEngine(
            wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
            policy: policy)
    }

    func disposition(for result: IntegrationReloadResult) async -> IntegrationReloadDisposition {
        await wrapped.disposition(for: result)
    }

    func invalidateThrottles() async { await wrapped.invalidateThrottles() }
    func applyAccountBackoffs(_ holds: [String: Date]) async {
        await wrapped.applyAccountBackoffs(holds)
    }
    func accountBackoffs() async -> [String: Date] { await wrapped.accountBackoffs() }
}

private final class EngineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
}

private func engineAccountReading(
    integration: Integration, id: String, location: String? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        windows: [UsageWindow(id: "5h", title: "Session", utilization: 44, kind: .account)],
        localTokensToday: nil, localTokensWeek: nil,
        source: integration == .claude ? .claudeOAuth : .codexUsageAPI,
        lastUpdated: Date(timeIntervalSince1970: 10),
        account: UsageAccount(
            id: id, email: "same@example.com", plan: nil,
            location: location ?? "~/.\(integration.rawValue)", suggestedName: id))
}

// Defect: a real account monitor resolving a disconnected retained account, then another process
// removing it before Engine consumes the result, allowing the stale key into UsageStore.
@MainActor
@Test(arguments: [Integration.claude, .codex])
func engineRejectsAccountResultInvalidatedAfterResolve(_ integration: Integration) async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hu-engine-account-race-\(integration.rawValue)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "EngineAccountRace-\(integration.rawValue)-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let accounts = SubscriptionAccountStore(home: home, providers: [:])
    let removed = engineAccountReading(integration: integration, id: "account-a")
    let survivor = engineAccountReading(integration: integration, id: "account-b")
    _ = await accounts.resolve(
        integration: integration, detected: ["old-folder": removed, nil: survivor])
    _ = await accounts.resolve(integration: integration, detected: [nil: survivor])

    let detected = EngineDetectedProfilesMonitor(readings: [nil: survivor])
    let gate = EngineOneShotGate()
    let wrapped = PostResolveBlockingMonitor(
        wrapped: accounts.makeMonitor(for: integration, detectedMonitor: detected), gate: gate)
    let usage = UsageStore()
    let engine = Engine(
        monitors: [integration: wrapped], usage: usage,
        settings: SettingsStore(defaults: defaults), accounts: accounts)

    let tick = Task { await engine.tick() }
    await gate.waitUntilStarted()
    let remover = SubscriptionAccountStore(home: home, providers: [:])
    try await remover.removeConnection(for: integration, accountID: "account-a")
    await gate.release()
    await tick.value

    #expect(usage[UsageKey(integration, profile: "account-a")] == nil)
    #expect(usage[UsageKey(integration, profile: "account-b")] != nil)

    // Rejection does not stamp the stale attempt as current; it arranges a fresh pass immediately.
    await engine.tick()
    #expect(await wrapped.reloads == 2)
    #expect(usage[UsageKey(integration, profile: "account-a")] == nil)
    #expect(usage[UsageKey(integration, profile: "account-b")] != nil)
}

// Defect: a persistent generation-file read failure blanking retained rows and requeuing the account
// monitor immediately forever instead of recording one failed attempt at the normal cadence.
@MainActor
@Test(arguments: [Integration.claude, .codex])
func generationValidationFailureRetainsRowsAndRespectsCadence(
    _ integration: Integration
) async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hu-engine-generation-failure-\(integration.rawValue)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "EngineGenerationFailure-\(integration.rawValue)-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = EngineClock(Date(timeIntervalSince1970: 1_000))

    let accounts = SubscriptionAccountStore(home: home, providers: [:])
    let remembered = engineAccountReading(integration: integration, id: "remembered")
    let deleted = engineAccountReading(integration: integration, id: "deleted")
    _ = await accounts.resolve(
        integration: integration, detected: [nil: remembered, "old-folder": deleted])
    _ = await accounts.resolve(integration: integration, detected: [:])
    // A second process deletes one identity while this store still has it in memory. Error recovery
    // must reload account records independently from the corrupt generation marker and not revive it.
    let remover = SubscriptionAccountStore(home: home, providers: [:])
    try await remover.removeConnection(for: integration, accountID: "deleted")
    let generationFile = home.appendingPathComponent(
        ".harness-usage/accounts/.detection-generations")
    try Data("not-json".utf8).write(to: generationFile)

    let detected = EngineDetectedProfilesMonitor(readings: [nil: remembered])
    let accountMonitor = CountingIntegrationMonitor(
        wrapped: accounts.makeMonitor(for: integration, detectedMonitor: detected))
    let other: Integration = integration == .claude ? .codex : .claude
    let otherSnapshot = UsageSnapshot(
        windows: [], localTokensToday: 7, localTokensWeek: nil,
        source: other == .claude ? .claudeOAuth : .codexLocal,
        lastUpdated: clock.now)
    let usage = UsageStore()
    let engine = Engine(
        monitors: [integration: accountMonitor, other: EngineMonitorStub(snapshot: otherSnapshot)],
        usage: usage, settings: SettingsStore(defaults: defaults), accounts: accounts,
        now: { clock.now })

    await engine.tick()
    let key = UsageKey(integration, profile: "remembered")
    let deletedKey = UsageKey(integration, profile: "deleted")
    #expect(await accountMonitor.reloads == 1)
    #expect(usage[key]?.freshness == .disconnected)
    #expect(usage[deletedKey] == nil)
    #expect(usage[key]?.note == SubscriptionAccountError.persistenceFailed.localizedDescription)
    #expect(usage[UsageKey(other)] == otherSnapshot)

    for _ in 0..<3 { await engine.tick() }
    #expect(await accountMonitor.reloads == 1)
    #expect(usage[key]?.note == SubscriptionAccountError.persistenceFailed.localizedDescription)
    #expect(usage[deletedKey] == nil)
    #expect(usage[UsageKey(other)] == otherSnapshot)

    try FileManager.default.removeItem(at: generationFile)
    clock.advance(UsageUpdateInterval.fiveMinutes.seconds)
    await engine.tick()
    #expect(await accountMonitor.reloads == 2)
    #expect(usage[key]?.freshness == .fresh)
    #expect(usage[key]?.note == nil)
    #expect(usage[deletedKey] == nil)
    #expect(usage[UsageKey(other)] == otherSnapshot)
}

// Defect: a dirty file event bypassing the chosen cadence or being dropped before it becomes due.
@Test func cadenceDecisionRetainsDirtyWorkUntilEachSupportedBoundary() {
    let start = Date(timeIntervalSince1970: 1_000)
    for interval in UsageUpdateInterval.allCases {
        let early = Engine.cadenceDecision(
            candidates: [], pendingDirty: [], newlyDirty: [.claude], explicitlyDue: [],
            detected: [.claude], lastReload: [.claude: start],
            now: start.addingTimeInterval(interval.seconds - 1), interval: interval.seconds,
            bypassAppCadence: false)
        #expect(early.due.isEmpty)
        #expect(early.pendingDirty == [.claude])

        let boundary = Engine.cadenceDecision(
            candidates: [], pendingDirty: early.pendingDirty, newlyDirty: [], explicitlyDue: [],
            detected: [.claude], lastReload: [.claude: start],
            now: start.addingTimeInterval(interval.seconds), interval: interval.seconds,
            bypassAppCadence: false)
        #expect(boundary.due == [.claude])
        #expect(boundary.pendingDirty.isEmpty)
    }
}

@MainActor
@Test func runtimeCadenceChangeUsesLastAttemptAndManualRefreshBypassesOnlyAppGate() async throws {
    let suite = "EngineCadence-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hu-engine-cadence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let settings = SettingsStore(defaults: defaults)
    let monitor = EngineMonitorStub(
        snapshot: UsageSnapshot(
            windows: [], localTokensToday: nil, localTokensWeek: nil,
            source: .claudeOAuth, lastUpdated: Date(timeIntervalSince1970: 1_000)))
    let clock = EngineClock(Date(timeIntervalSince1970: 1_000))
    let engine = Engine(
        monitors: [.claude: monitor], usage: UsageStore(), settings: settings,
        integrations: IntegrationStore(home: home), now: { clock.now })

    await engine.tick()
    #expect(await monitor.reloads == 1)
    clock.advance(100)
    var changed = settings.settings
    changed.updateInterval = .fifteenMinutes
    settings.update(changed)
    await engine.tick()
    #expect(await monitor.reloads == 1)

    changed.warningAt = 40
    settings.update(changed)
    await engine.tick()
    #expect(await monitor.reloads == 1)

    changed.updateInterval = .oneMinute
    settings.update(changed)
    await engine.tick()
    #expect(await monitor.reloads == 2)
    #expect(await monitor.policies.last == UsageReloadPolicy(interval: .oneMinute))

    await engine.refreshNow()
    #expect(await monitor.reloads == 3)
    #expect(await monitor.policies.last?.bypassAppCadence == true)
}

@MainActor
@Test func disablingTheLastProviderPublishesAnEmptyUsageMap() async {
    let suite = "EngineTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SettingsStore(defaults: defaults)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hu-engine-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let integrations = IntegrationStore(home: home)

    let snapshot = UsageSnapshot(
        windows: [
            UsageWindow(
                id: "5h", title: "Session", utilization: 42, period: 5 * 3_600,
                resetsAt: nil, kind: .account)
        ],
        localTokensToday: nil, localTokensWeek: nil, source: .codexLocal, lastUpdated: Date())
    let usage = UsageStore()
    let engine = Engine(
        monitors: [.codex: EngineMonitorStub(snapshot: snapshot)], usage: usage, settings: settings,
        integrations: integrations)

    await engine.tick()
    #expect(usage.byIntegration[.codex] != nil)

    integrations.detected = []
    await engine.tick()
    #expect(usage.byIntegration.isEmpty)
}

private actor ProfilesMonitorStub: IntegrationMonitor {
    let readings: [String?: UsageSnapshot]

    init(readings: [String?: UsageSnapshot]) { self.readings = readings }

    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? { nil }
    func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot] { readings }
}

// Defect: an engine that keeps one snapshot per harness, so a second account either never reaches
// the notch or overwrites the first account's meters.
@MainActor
@Test func everyProfileAMonitorReportsIsPublishedUnderItsOwnKey() async {
    let suite = "EngineTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hu-engine-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    func reading(_ utilization: Double) -> UsageSnapshot {
        UsageSnapshot(
            windows: [UsageWindow(id: "5h", title: "Session", utilization: utilization, period: 5 * 3_600, kind: .account)],
            localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth, lastUpdated: Date())
    }
    let personal = reading(72)
    let work = reading(18)
    let defaultLogin: String? = nil
    let usage = UsageStore()
    let engine = Engine(
        monitors: [.claude: ProfilesMonitorStub(readings: [defaultLogin: personal, "work": work])], usage: usage,
        settings: SettingsStore(defaults: defaults), integrations: IntegrationStore(home: home))

    await engine.tick()

    #expect(usage[UsageKey(.claude)] == personal)
    #expect(usage[UsageKey(.claude, profile: "work")] == work)
    #expect(usage.keys(for: .claude) == [UsageKey(.claude), UsageKey(.claude, profile: "work")])
    #expect(usage.byIntegration == [.claude: personal])
}

// Defect: "Update now" leaving the engine's own gates in place — the heartbeat and the poll clock
// both filter a monitor out of `due`, so the press would drop each monitor's floor and then ask for
// nothing.
@MainActor
@Test func refreshNowReloadsEveryDetectedMonitorThroughTheHeartbeatGate() async {
    let suite = "EngineTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hu-engine-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let monitor = EngineMonitorStub(
        snapshot: UsageSnapshot(
            windows: [], localTokensToday: 1, localTokensWeek: nil, source: .codexLocal,
            lastUpdated: Date()))
    let engine = Engine(
        monitors: [.codex: monitor], usage: UsageStore(), settings: SettingsStore(defaults: defaults),
        integrations: IntegrationStore(home: home))

    await engine.tick()  // the first tick is a heartbeat
    #expect(await monitor.reloads == 1)

    await engine.tick()  // inside the heartbeat, with no watched root dirty: nothing is due
    #expect(await monitor.reloads == 1)

    await engine.refreshNow()
    #expect(await monitor.invalidations == 1)
    #expect(await monitor.reloads == 2)
}
