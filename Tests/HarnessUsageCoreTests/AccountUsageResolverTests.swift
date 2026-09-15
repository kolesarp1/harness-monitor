import Foundation
import Testing

@testable import HarnessUsageCore

private func account(_ id: String, email: String = "same@example.com") -> UsageAccount {
    UsageAccount(id: id, email: email, plan: nil, location: "Harness Monitor", suggestedName: id)
}

private func accountReading(
    _ id: String, utilization: Double, source: UsageSource, tokens: Int? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        windows: [UsageWindow(id: "5h", title: "Session", utilization: utilization, kind: .account)],
        localTokensToday: tokens, localTokensWeek: nil, source: source,
        lastUpdated: Date(timeIntervalSince1970: utilization), account: account(id))
}

@Suite struct AccountUsageResolverTests {
    // Defect: merging by email and collapsing two organizations owned by the same person.
    @Test func sameEmailDifferentProviderIdentityStaysSeparate() {
        let records = ["person/org-a", "person/org-b"].map { id in
            AccountUsageRecord(
                integration: .claude, account: account(id), canonicalKey: id,
                hasOwnedCredential: true, ownedAvailable: true,
                ownedSnapshot: accountReading(id, utilization: id.hasSuffix("a") ? 20 : 80, source: .claudeOAuth),
                ownedStatus: nil, detected: [], lastReading: nil)
        }
        let resolved = AccountUsageResolver.resolve(integration: .claude, records: records, unidentifiedDetected: [:])
        #expect(resolved.count == 2)
        #expect(resolved["person/org-a"]?.windows.first?.utilization == 20)
        #expect(resolved["person/org-b"]?.windows.first?.utilization == 80)
    }

    // Defect: choosing the newer detected timestamp over healthy owned credentials, or summing the
    // same local estimate twice while deduplicating the two sources.
    @Test func healthyOwnedWinsWholeReadingAndTakesOneMatchingLocalEstimate() {
        let owned = accountReading("acct", utilization: 61, source: .codexUsageAPI)
        let detected = accountReading("acct", utilization: 9, source: .codexLocal, tokens: 1_200)
        let record = AccountUsageRecord(
            integration: .codex, account: account("acct"), canonicalKey: "acct",
            hasOwnedCredential: true, ownedAvailable: true, ownedSnapshot: owned,
            ownedStatus: nil, detected: [("~/.codex", detected)], lastReading: nil)
        let result = AccountUsageResolver.resolve(integration: .codex, records: [record], unidentifiedDetected: [:])
        let snapshot = result["acct"]
        #expect(snapshot?.windows.first?.utilization == 61)
        #expect(snapshot?.localTokensToday == 1_200)
        #expect(snapshot?.activeAccountSource == .owned)
        #expect(snapshot?.accountSources.map(\.kind) == [.owned, .detected])
    }

    // Defect: leaving an unusable owned credential in priority position instead of falling back only
    // to the same provider identity, then failing to mark the fallback explicitly.
    @Test func rejectedOwnedUsesMatchingDetectedAndNeverAnotherAccount() {
        let other = accountReading("other", utilization: 99, source: .codexLocal)
        let matching = accountReading("acct", utilization: 32, source: .codexLocal)
        let record = AccountUsageRecord(
            integration: .codex, account: account("acct"), canonicalKey: "acct",
            hasOwnedCredential: true, ownedAvailable: false, ownedSnapshot: nil,
            ownedStatus: "Reconnect", detected: [("~/.codex", matching)],
            lastReading: accountReading("acct", utilization: 70, source: .codexUsageAPI))
        let result = AccountUsageResolver.resolve(
            integration: .codex, records: [record], unidentifiedDetected: ["other": other])
        #expect(result["acct"]?.windows.first?.utilization == 32)
        #expect(result["acct"]?.freshness == .fallback)
        #expect(result["other"]?.windows.first?.utilization == 99)
    }

    // Defect: restamping retained percentages as current, or fabricating zero after a passed reset.
    @Test func unavailableSourcesPublishRetainedDisconnectedReadingWithoutChangingReset() {
        let reset = Date(timeIntervalSince1970: 50)
        var retained = accountReading("acct", utilization: 73, source: .claudeOAuth)
        retained.windows = [UsageWindow(id: "5h", title: "Session", utilization: 73, resetsAt: reset, kind: .account)]
        let record = AccountUsageRecord(
            integration: .claude, account: account("acct"), canonicalKey: "acct",
            hasOwnedCredential: true, ownedAvailable: false, ownedSnapshot: nil,
            ownedStatus: "Reconnect", detected: [], lastReading: retained)
        let result = AccountUsageResolver.resolve(integration: .claude, records: [record], unidentifiedDetected: [:])
        #expect(result["acct"]?.freshness == .disconnected)
        #expect(result["acct"]?.activeAccountSource == .retained)
        #expect(result["acct"]?.windows.first?.utilization == 73)
        #expect(result["acct"]?.windows.first?.resetsAt == reset)
    }
}
