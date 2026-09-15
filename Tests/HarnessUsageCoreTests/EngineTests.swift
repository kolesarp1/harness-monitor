import Foundation
import Testing

@testable import HarnessUsageCore

private actor EngineMonitorStub: IntegrationMonitor {
    let snapshot: UsageSnapshot?
    private(set) var reloads = 0
    private(set) var invalidations = 0

    init(snapshot: UsageSnapshot?) { self.snapshot = snapshot }

    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        reloads += 1
        return snapshot
    }

    func invalidateThrottles() { invalidations += 1 }
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
