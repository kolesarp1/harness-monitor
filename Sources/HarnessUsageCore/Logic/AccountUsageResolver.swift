import Foundation

struct AccountUsageRecord: Sendable {
    var integration: Integration
    var account: UsageAccount
    var canonicalKey: String
    var hasOwnedCredential: Bool
    var ownedAvailable: Bool
    var ownedSnapshot: UsageSnapshot?
    var ownedStatus: String?
    var detected: [(reference: String, snapshot: UsageSnapshot)]
    var rememberedDetectedSources: [UsageAccountSource] = []
    var lastReading: UsageSnapshot?
}

enum AccountUsageResolver {
    /// Resolve one provider's owned, detected, and retained readings by exact provider identity.
    /// A chosen snapshot is copied wholesale; percentages are never assembled across sources.
    static func resolve(
        integration: Integration, records: [AccountUsageRecord],
        unidentifiedDetected: [String?: UsageSnapshot]
    ) -> [String?: UsageSnapshot] {
        var output: [String?: UsageSnapshot] = unidentifiedDetected
        for record in records {
            let detected = record.detected.first { $0.snapshot.freshness != .disconnected }
            let chosen: (UsageSnapshot, UsageActiveAccountSource, UsageFreshness)?
            if record.ownedAvailable, let owned = record.ownedSnapshot {
                chosen = (withLocalEstimate(owned, detected: detected?.snapshot), .owned, .fresh)
            } else if let detected {
                chosen = (detected.snapshot, .detected, record.hasOwnedCredential ? .fallback : .fresh)
            } else if let retained = record.lastReading {
                chosen = (retained, .retained, .disconnected)
            } else {
                chosen = nil
            }

            var detectedSources = Dictionary(
                uniqueKeysWithValues: record.rememberedDetectedSources.map { ($0.reference, $0) })
            for source in record.detected {
                detectedSources[source.reference] = UsageAccountSource(
                    kind: .detected, reference: source.reference,
                    isAvailable: source.snapshot.freshness != .disconnected)
            }
            let sources =
                (record.hasOwnedCredential
                    ? [UsageAccountSource(kind: .owned, reference: "Harness Monitor", isAvailable: record.ownedAvailable)]
                    : [])
                + detectedSources.values.sorted { $0.reference < $1.reference }
            var snapshot =
                chosen?.0
                ?? UsageSnapshot(
                    windows: [], localTokensToday: nil, localTokensWeek: nil,
                    source: integration == .claude ? .claudeOAuth : .codexUsageAPI,
                    lastUpdated: record.lastReading?.lastUpdated ?? .distantPast,
                    note: record.ownedStatus, freshness: .disconnected,
                    activeAccountSource: .retained)
            snapshot.account = selectedAccount(snapshot.account, retaining: record.account)
            snapshot.freshness = chosen?.2 ?? .disconnected
            snapshot.activeAccountSource = chosen?.1 ?? .retained
            snapshot.accountSources = sources
            if snapshot.note == nil { snapshot.note = record.ownedStatus }
            output[record.canonicalKey] = snapshot
        }
        return output
    }

    private static func selectedAccount(_ selected: UsageAccount?, retaining previous: UsageAccount) -> UsageAccount {
        guard let selected else { return previous }
        return UsageAccount(
            id: previous.id,
            email: selected.email ?? previous.email,
            plan: selected.plan ?? previous.plan,
            location: selected.location.isEmpty ? previous.location : selected.location,
            suggestedName: selected.suggestedName.isEmpty ? previous.suggestedName : selected.suggestedName)
    }

    private static func withLocalEstimate(_ owned: UsageSnapshot, detected: UsageSnapshot?) -> UsageSnapshot {
        guard let detected else { return owned }
        var result = owned
        // Local estimates may accompany the matching account, but one detected source contributes once.
        if result.localTokensToday == nil { result.localTokensToday = detected.localTokensToday }
        if result.localTokensWeek == nil { result.localTokensWeek = detected.localTokensWeek }
        if result.todayInput == nil { result.todayInput = detected.todayInput }
        if result.todayOutput == nil { result.todayOutput = detected.todayOutput }
        if result.costTodayUSD == nil { result.costTodayUSD = detected.costTodayUSD }
        if result.estimatedCostUSD == nil { result.estimatedCostUSD = detected.estimatedCostUSD }
        return result
    }
}
