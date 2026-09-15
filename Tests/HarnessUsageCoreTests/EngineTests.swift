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

private final class EngineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
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
