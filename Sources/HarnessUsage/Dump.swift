import Foundation
import HarnessUsageCore

// `--dump`: build the engine, run one tick, print the result. Manual verification for the non-pure
// layer (monitors/engine). `--mock` means here exactly what it means for the app — fixtures instead of
// real agents and a throwaway defaults suite — so the dump can be run without touching a real login.
@MainActor
func runDump() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let isMock = CommandLine.arguments.contains("--mock")
    let integrationStore = IntegrationStore(home: home)

    // Built generically off the descriptors (mirrors AppDelegate). Only supported integrations are
    // initialized; suspended cases keep their code and stored settings but get no monitor.
    // Non-mock runs wrap each monitor with the shared subscription store, like the app.
    let accounts: SubscriptionAccountStore? = isMock ? nil : SubscriptionAccountStore(home: home)
    let monitors: [Integration: any IntegrationMonitor]
    if isMock {
        let mockDir = AppDelegate.mockDataDir()
        monitors = Dictionary(
            uniqueKeysWithValues:
                Integration.supportedCases.map { ($0, MockMonitor(integration: $0, mockDir: mockDir) as any IntegrationMonitor) })
    } else {
        monitors = Dictionary(
            uniqueKeysWithValues: Integration.supportedCases.map {
                let detected = $0.descriptor.makeMonitor(home: home)
                return ($0, accounts?.makeMonitor(for: $0, detectedMonitor: detected) ?? detected)
            })
    }

    let engine = Engine(
        monitors: monitors,
        usage: UsageStore(),
        settings: SettingsStore(defaults: isMock ? AppDelegate.mockDefaults() : .standard),
        integrations: isMock ? nil : integrationStore,
        accounts: accounts)

    await engine.tick()

    // Mock passes `integrations: nil`, so nothing is probed on disk — every integration is faked in,
    // the same fallback the app's own render path takes.
    let detected = isMock ? Set(Integration.supportedCases) : integrationStore.detected
    print("=== Harness Monitor --dump ===")
    print("detected: \(detected.map(\.rawValue).sorted().joined(separator: ", "))")
    func fallback(_ s: UsageSnapshot?) -> String {
        guard let i = s?.todayInput, let o = s?.todayOutput else { return "fallback=—" }
        return "fallback[in=\(i) out=\(o) total=\(i + o)]"
    }
    func note(_ s: UsageSnapshot?) -> String { "note=\(s?.note ?? "—")" }
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
    func account(_ s: UsageSnapshot?) -> String {
        guard let a = s?.account else { return "account=—" }
        return "account[\(a.email ?? "—") plan=\(a.plan ?? "—") at=\(a.location)]"
    }
    func freshness(_ s: UsageSnapshot?) -> String {
        guard let s else { return "freshness=—" }
        let active = s.activeAccountSource.map(\.rawValue) ?? "—"
        let sources = s.accountSources.map { "\($0.kind.rawValue):\($0.reference)\($0.isAvailable ? "" : "!")" }.joined(separator: ",")
        return "freshness=\(s.freshness.rawValue) active=\(active) sources=[\(sources)]"
    }
    for integration in Integration.supportedCases {
        // All published logins (account keys carry the subscription id as their profile), with the
        // default first for a stable order. Account-only providers have no default reading.
        let published = engine.usage.keys(for: integration)
        let ordered = published.contains(UsageKey(integration)) ? published : [UsageKey(integration)] + published
        for key in ordered {
            let snap = engine.usage[key]
            print(
                "\(key.rawValue) usage: \(account(snap)) source=\(snap?.source.rawValue ?? "none") \(rows(snap)) \(tokens(snap)) \(cost(snap)) \(fallback(snap)) \(age(snap)) \(freshness(snap)) \(note(snap))")
        }
    }
}

private func pct(_ v: Double?) -> String {
    guard let v else { return "—" }
    return "\(UsageFormat.percent(v))%"
}
