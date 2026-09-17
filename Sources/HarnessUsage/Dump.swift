import Foundation
import HarnessUsageCore

// `--dump`: build the engine, run one tick, print the result. Manual verification for the non-pure
// layer (monitors/engine). `--mock` means here exactly what it means for the app — fixtures instead of
// real agents and a throwaway defaults suite — so the dump can be run without touching a real login.
@MainActor
func runDump() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let isMock = CommandLine.arguments.contains("--mock")
    let accounts = isMock ? AccountsFile.defaults : Accounts.configured
    let keys = accounts.map(\.integration)
    let integrationStore = IntegrationStore(home: home, accounts: accounts)

    // Built generically off the descriptors, per account (mirrors AppDelegate).
    let monitors: [Integration: any IntegrationMonitor]
    if isMock {
        let mockDir = AppDelegate.mockDataDir()
        monitors = Dictionary(
            uniqueKeysWithValues:
                keys.map { ($0, MockMonitor(integration: $0, mockDir: mockDir) as any IntegrationMonitor) })
    } else {
        monitors = makeMonitors(accounts: accounts, home: home)
    }

    let engine = Engine(
        monitors: monitors,
        usage: UsageStore(),
        settings: SettingsStore(
            defaults: isMock ? AppDelegate.mockDefaults() : .standard, accounts: keys),
        integrations: isMock ? nil : integrationStore)

    await engine.tick()

    // Mock passes `integrations: nil`, so nothing is probed on disk — every integration is faked in,
    // the same fallback the app's own render path takes.
    let detected = isMock ? Set(keys) : integrationStore.detected
    print("=== Harness Usage --dump ===")
    print("accounts: \(keys.map(\.rawValue).joined(separator: ", "))")
    print("detected: \(detected.map(\.rawValue).sorted().joined(separator: ", "))")
    func fallback(_ s: UsageSnapshot?) -> String {
        guard let i = s?.todayInput, let o = s?.todayOutput else { return "fallback=—" }
        return "fallback[in=\(i) out=\(o) total=\(i + o)]"
    }
    func note(_ s: UsageSnapshot?) -> String { "note=\(s?.note ?? "—")" }
    // Which account this lane is actually holding — the one fact a label cannot be trusted for.
    func account(_ s: UsageSnapshot?) -> String { "account=\(s?.accountEmail ?? "—")" }
    func age(_ s: UsageSnapshot?) -> String {
        guard let d = s?.lastUpdated else { return "age=—" }
        return "age=\(Int(Date().timeIntervalSince(d).rounded()))s"
    }
    func rows(_ s: UsageSnapshot?) -> String {
        guard let windows = s?.windows, !windows.isEmpty else { return "rows=—" }
        return "rows=[\(windows.map { "\($0.title)=\(pct($0.utilization))" }.joined(separator: " "))]"
    }
    func tokens(_ s: UsageSnapshot?) -> String {
        "tokens[in=\(s?.todayInput.map(String.init) ?? "—") out=\(s?.todayOutput.map(String.init) ?? "—") today=\(s?.localTokensToday.map(String.init) ?? "—") week=\(s?.localTokensWeek.map(String.init) ?? "—")]"
    }
    func cost(_ s: UsageSnapshot?) -> String {
        "cost[today=\(s?.costTodayUSD.map { String(format: "$%.4f", $0) } ?? "—") estimate=\(s?.estimatedCostUSD.map { String(format: "$%.4f", $0) } ?? "—")]"
    }
    for integration in keys {
        let snap = engine.usage[integration]
        print(
            "\(integration.rawValue) usage: source=\(snap?.source.rawValue ?? "none") \(account(snap)) \(rows(snap)) \(tokens(snap)) \(cost(snap)) \(fallback(snap)) \(age(snap)) \(note(snap))")
    }
}

private func pct(_ v: Double?) -> String {
    guard let v else { return "—" }
    return "\(UsageFormat.percent(v))%"
}
