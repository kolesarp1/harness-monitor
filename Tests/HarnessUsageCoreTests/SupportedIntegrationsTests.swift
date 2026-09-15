import Foundation
import Testing

@testable import HarnessUsageCore

// T1: Cursor and opencode are suspended, not deleted. Their enum cases, descriptors, parsers and
// stored settings remain, but nothing initializes, detects or enumerates them for the UI.
@Suite("SupportedIntegrations")
struct SupportedIntegrationsTests {
    // Defect: a re-enabled (or dropped) case silently changing which harnesses the app reads.
    @Test func supportedCasesAreExactlyClaudeAndCodex() {
        #expect(Integration.supportedCases == [.claude, .codex])
    }

    // Defect: "hiding" a provider by deleting its case, which would break the registry invariant and
    // orphan stored settings. Suspension keeps the full universe intact.
    @Test func allCasesStillCarriesEveryIntegrationWithADescriptor() {
        #expect(Set(Integration.allCases) == [.claude, .codex, .cursor, .opencode])
        for integration in Integration.allCases {
            #expect(!integration.descriptor.displayName.isEmpty)
            #expect(!integration.descriptor.homeRelativePath.isEmpty)
        }
    }

    // Defect: hiding a sidebar item while the engine still reads its credential database. Even with
    // all four marker directories present, detection reports only the supported pair.
    @MainActor @Test func detectionSkipsSuspendedIntegrations() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hu-supported-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for integration in Integration.allCases {
            try! FileManager.default.createDirectory(
                at: home.appendingPathComponent(integration.descriptor.homeRelativePath),
                withIntermediateDirectories: true)
        }

        let store = IntegrationStore(home: home)
        store.refresh()
        #expect(store.detected == [.claude, .codex])
    }

    // Defect: suspension wiping or ignoring previously stored Cursor/opencode preferences. The store
    // serializes over `allCases`, so a suspended provider's entry round-trips byte-identical.
    @MainActor @Test func suspendedProviderSettingsRoundTripUnchanged() {
        let suite = "SupportedIntegrations-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var s = store.settings
        let cursor = ProviderConfig(
            visible: false, scope: .window("cycle"), showExtraCaps: false, showTokenEstimate: false)
        let opencode = ProviderConfig(
            visible: true, scope: .mostUrgent, showExtraCaps: true, showTokenEstimate: false)
        s.providers[.cursor] = cursor
        s.providers[.opencode] = opencode
        store.update(s)

        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.providers[.cursor] == cursor)
        #expect(reloaded.providers[.opencode] == opencode)
        #expect(reloaded == s)
    }

    // Defect: the card's provider picker offering a suspended harness that has snapshot data (e.g.
    // from a stale cache entry) but no monitor, ring or settings pane.
    @Test func providerSelectionExcludesSuspendedIntegrations() {
        func snapshot() -> UsageSnapshot {
            UsageSnapshot(
                windows: [
                    UsageWindow(
                        id: "cycle", title: "Cycle", utilization: 90, period: 30 * 86_400,
                        resetsAt: nil, kind: .account)
                ],
                localTokensToday: nil, localTokensWeek: nil, source: .cursorDashboard,
                lastUpdated: .distantPast)
        }
        let usage: [Integration: UsageSnapshot] = [
            .cursor: snapshot(),
            .opencode: snapshot(),
        ]
        #expect(UsageSelection.availableProviders(usage: usage, settings: .defaults).isEmpty)
        #expect(!UsageSelection.offersTokens(usage: usage))
        #expect(
            UsageSelection.chosenProvider(
                UsageSelection.availableProviders(usage: usage, settings: .defaults),
                usage: usage, settings: .defaults) == nil)
    }

    // The supported pair still enumerates normally through the same selection paths.
    @Test func supportedProvidersRemainSelectable() {
        let snapshot = UsageSnapshot(
            windows: [
                UsageWindow(
                    id: "5h", title: "Session", utilization: 40, period: 5 * 3_600,
                    resetsAt: nil, kind: .account)
            ],
            localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth,
            lastUpdated: .distantPast)
        let usage: [Integration: UsageSnapshot] = [.claude: snapshot, .codex: snapshot]
        #expect(Set(UsageSelection.availableProviders(usage: usage, settings: .defaults)) == [.claude, .codex])
        #expect(UsageSelection.offersTokens(usage: usage))
    }
}
