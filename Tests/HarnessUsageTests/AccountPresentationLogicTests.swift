import Foundation
import HarnessUsageCore
import Testing

@testable import HarnessUsage

private func presentationSnapshot(
    accountID: String, freshness: UsageFreshness = .fresh, reset: Date? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        windows: [UsageWindow(id: "5h", title: "Session", utilization: 64, resetsAt: reset, kind: .account)],
        localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth,
        lastUpdated: Date(timeIntervalSince1970: 100),
        account: UsageAccount(
            id: accountID, email: nil, plan: nil, location: "Harness Monitor",
            suggestedName: "Account"),
        freshness: freshness,
        activeAccountSource: freshness == .disconnected ? .retained : .owned)
}

@Suite("Account presentation logic")
@MainActor
struct AccountPresentationLogicTests {
    private func environment() -> (UsageStore, SettingsStore) {
        let suite = "presentation-\(UUID().uuidString)"
        return (UsageStore(), SettingsStore(defaults: UserDefaults(suiteName: suite)!))
    }

    @Test("detected and owned canonical identity produces one ring")
    func canonicalIdentityHasNoPhantomDefaultRing() {
        let (usage, settings) = environment()
        let key = UsageKey(.claude, profile: "person/org")
        usage.readings = [key: presentationSnapshot(accountID: "person/org")]
        let rings = NotchProvider.all(
            usage: usage, settings: settings, detected: [.claude],
            measureCard: { _, _, _ in .zero })
        #expect(rings.map(\.key) == [key])
    }

    @Test("app-only account remains visible and enabled")
    func appOnlyAccountIsAvailable() {
        let (usage, settings) = environment()
        let key = UsageKey(.claude, profile: "person/org")
        let snapshot = presentationSnapshot(accountID: "person/org")
        usage.readings = [key: snapshot]
        let rings = NotchProvider.all(
            usage: usage, settings: settings, detected: [],
            measureCard: { _, _, _ in .zero })
        #expect(rings.map(\.key) == [key])
        #expect(ProviderPaneLogic.isAvailable(detected: false, snapshots: [snapshot], accountRemembered: false))
        #expect(ProviderPaneLogic.isAvailable(detected: false, snapshots: [], accountRemembered: true))
    }

    @Test("scope offerings come from every account without aggregate utilization")
    func scopeOfferingsUseActualAccountWindows() {
        let first = presentationSnapshot(accountID: "one")
        var second = presentationSnapshot(accountID: "two")
        second.windows = [UsageWindow(id: "7d", title: "Weekly", utilization: 12, kind: .account)]
        let options = UsageSelection.scopeOptions([first, second], includingExtras: true)
        #expect(options.map(\.label) == ["Session", "Weekly", "Most urgent"])
        #expect(ProviderPaneLogic.modelCapNames([first, second]).isEmpty)
    }

    @Test("source text classifies recorded methods independent of health")
    func sourceClassification() {
        let ownedUnavailable = UsageAccountSource(
            kind: .owned, reference: "Harness Monitor", isAvailable: false)
        let localAvailable = UsageAccountSource(
            kind: .detected, reference: "~/.claude", isAvailable: true)
        let localUnavailable = UsageAccountSource(
            kind: .detected, reference: "~/.claude-work", isAvailable: false)

        #expect(AccountSourceKind.classify([ownedUnavailable]) == .login)
        #expect(AccountSourceKind.classify([localAvailable, localUnavailable]) == .local)
        #expect(AccountSourceKind.classify([ownedUnavailable, localUnavailable]) == .both)
        #expect(AccountSourceKind.classify([]) == nil)
    }

    @Test("account metadata keeps genuine paths and omits empty or repeated values")
    func accountMetadataComposition() {
        let account = UsageAccount(
            id: "person/org", email: "person@example.com", plan: "Default_claude_max_5x",
            location: "Harness Monitor", suggestedName: "Person")
        let sources = [
            UsageAccountSource(kind: .owned, reference: "Harness Monitor", isAvailable: false),
            UsageAccountSource(kind: .detected, reference: "~/.claude", isAvailable: true),
            UsageAccountSource(kind: .detected, reference: "~/.claude-work", isAvailable: false),
        ]

        #expect(
            AccountMetadata.settingsItems(account: account, title: "Person", sources: sources)
                == ["person@example.com", "~/.claude", "~/.claude-work", "both"])
        #expect(
            AccountMetadata.renameItems(account: account, integration: .claude, sources: sources)
                == ["Max 5x", "~/.claude", "~/.claude-work", "both"])
        #expect(AccountMetadata.cardItems(account: account, title: "Person") == ["person@example.com"])
        #expect(AccountMetadata.cardItems(account: account, title: "person@example.com").isEmpty)
        #expect(
            AccountMetadata.settingsItems(account: account, title: "person@example.com", sources: [sources[0]])
                == ["login"])
        #expect(
            AccountMetadata.settingsItems(account: account, title: "person@example.com", sources: [sources[1]])
                == ["~/.claude", "local"])
    }

    @Test("metadata separators occur only between nonempty items")
    func metadataSeparatorPlacement() {
        let parts = MetadataRow.parts([nil, " ", "email@example.com", nil, "~/.codex", "~/.codex"])
        #expect(parts.map(\.text) == ["email@example.com", "|", "~/.codex"])
        #expect(parts.first?.isSeparator == false)
        #expect(parts.last?.isSeparator == false)
    }

    @Test("healthy accounts stay quiet while warning, fallback, and disconnected states stay distinct")
    func accountProblemPresentation() {
        let now = Date(timeIntervalSince1970: 3_700)
        var fresh = presentationSnapshot(accountID: "fresh")
        fresh.lastUpdated = Date(timeIntervalSince1970: 100)
        #expect(AccountMetadata.problem(snapshot: fresh, now: now) == nil)

        var warning = fresh
        warning.note = "Usage request failed"
        #expect(
            AccountMetadata.problem(snapshot: warning, now: now)
                == AccountProblem(text: "Usage request failed", tone: .warning))

        var fallback = fresh
        fallback.freshness = .fallback
        fallback.note = "Could not reach the provider usage endpoint."
        #expect(
            AccountMetadata.problem(snapshot: fallback, now: now)
                == AccountProblem(
                    text: "Could not reach the provider usage endpoint · Showing local reading",
                    tone: .fallback))

        var disconnected = fresh
        disconnected.freshness = .disconnected
        disconnected.note = "Could not reach provider"
        #expect(
            AccountMetadata.problem(snapshot: disconnected, now: now)
                == AccountProblem(
                    text: "Could not reach provider · Last reading 1h ago", tone: .disconnected))

        disconnected.note = SubscriptionAccountError.reconnectRequired.localizedDescription
        #expect(
            AccountMetadata.problem(snapshot: disconnected, now: now)
                == AccountProblem(
                    text: "This connection must be reconnected · Last reading 1h ago",
                    tone: .disconnectedWarning))
    }

    @Test("account action labels describe what removal leaves behind")
    func accountActionPolicy() {
        let owned = UsageAccountSource(
            kind: .owned, reference: "Harness Monitor", isAvailable: true)
        let local = UsageAccountSource(
            kind: .detected, reference: "~/.codex", isAvailable: true)
        let unavailableLocal = UsageAccountSource(
            kind: .detected, reference: "~/.codex-work", isAvailable: false)

        #expect(
            AccountActionPolicy.removalLabel(
                hasOwnedConnection: false, sources: [local]) == nil)
        #expect(
            AccountActionPolicy.removalLabel(
                hasOwnedConnection: true, sources: [owned]) == "Remove account")
        #expect(
            AccountActionPolicy.removalLabel(
                hasOwnedConnection: true, sources: [owned, local]) == "Remove browser login")
        #expect(
            AccountActionPolicy.removalLabel(
                hasOwnedConnection: true, sources: [owned, unavailableLocal]) == "Remove browser login")

        let reconnectRequired = SubscriptionAccountError.reconnectRequired.localizedDescription
        #expect(
            AccountActionPolicy.canReconnect(
                hasOwnedConnection: true, ownedStatus: reconnectRequired))
        #expect(
            AccountActionPolicy.canReconnect(
                hasOwnedConnection: true,
                ownedStatus: "The provider is rate-limiting this account; retrying later.") == false)
        #expect(
            AccountActionPolicy.canReconnect(
                hasOwnedConnection: false, ownedStatus: reconnectRequired) == false)
    }

    @Test("passed-reset stale ring suppresses old percentage")
    func passedResetStaleRingShowsReset() {
        let (usage, settings) = environment()
        let key = UsageKey(.claude, profile: "person/org")
        usage.readings = [
            key: presentationSnapshot(
                accountID: "person/org", freshness: .disconnected,
                reset: Date(timeIntervalSince1970: 50))
        ]
        let rings = NotchProvider.all(
            usage: usage, settings: settings, detected: [],
            measureCard: { _, _, _ in .zero })
        #expect(rings.first?.headlineText == "Reset")
        #expect(rings.first?.ringFraction == nil)
        #expect(rings.first?.isSpent == false)
    }
}
