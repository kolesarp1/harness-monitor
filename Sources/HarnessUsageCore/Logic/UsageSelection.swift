import Foundation

// Picks which window of a snapshot a scope refers to. Pure, so it is fully test-covered; the app
// feeds it the per-integration snapshots from `UsageStore`.
public enum UsageSelection {
    // A provider offers tokens when its descriptor reports them and detection produced a snapshot.
    // The estimate setting can clear the counts, so populated `todayInput` cannot be the capability test.
    //
    // Driven by the snapshots themselves rather than a configured list: a key is in the map only
    // because a monitor for that account reported, so the map already answers "which accounts exist".
    public static func offersTokens(usage: [Integration: UsageSnapshot]) -> Bool {
        usage.keys.contains { $0.reportsTokens }
    }

    /// `accounts` is the tracked account list, in the order the app lists them — the map alone cannot
    /// supply an order, and two rings must not swap places between renders.
    public static func availableProviders(
        _ accounts: [Integration], usage: [Integration: UsageSnapshot], settings: Settings
    ) -> [Integration] {
        accounts.filter { integration in
            let config = settings.provider(for: integration)
            let snapshot = usage[integration]
            // The same predicate the card's content uses, so a provider whose only windows are model
            // caps the Extra switch hides is not offered a row it would draw empty.
            if !(snapshot?.windows(includingExtras: config.showExtraCaps).isEmpty ?? true) { return true }
            return config.showTokenEstimate && integration.reportsTokens && snapshot != nil
        }
    }

    public static func chosenProvider(
        _ providers: [Integration], usage: [Integration: UsageSnapshot], settings: Settings
    ) -> Integration? {
        var mostDrained: (integration: Integration, utilization: Double)?
        for integration in providers {
            guard let snapshot = usage[integration],
                let window = resolved(
                    snapshot, scope: .mostUrgent,
                    includingExtras: settings.provider(for: integration).showExtraCaps)
            else { continue }
            if window.utilization > (mostDrained?.utilization ?? -1) {
                mostDrained = (integration, window.utilization)
            }
        }
        return mostDrained?.integration ?? providers.first
    }

    // `includingExtras` is that provider's Extra switch. Off, its model-scoped caps are not merely
    // hidden from the widget — they cannot be selected, they do not answer a stored id, and they stay
    // out of `.mostUrgent`. On, `.mostUrgent` compares every window: an option named "most urgent"
    // that skipped the fullest meter would be wrong by its own name. `.primary` is account-only
    // either way — it is the default, and a dormant model cap must never become one.
    public static func resolved(
        _ snap: UsageSnapshot, scope: UsageScope, includingExtras: Bool
    ) -> UsageWindow? {
        let visible = snap.windows(includingExtras: includingExtras)
        let primary = snap.primaryWindow(includingExtras: includingExtras)
        switch scope {
        case .primary:
            return primary
        case .mostUrgent:
            return visible.max { $0.utilization < $1.utilization } ?? primary
        case .window(let id):
            return visible.first { $0.id == id } ?? primary
        }
    }

    public static func scopeOptions(
        _ snap: UsageSnapshot?, includingExtras: Bool
    ) -> [(label: String, scope: UsageScope)] {
        guard let snap else { return [] }
        let visible = snap.windows(includingExtras: includingExtras)
        var options = visible.map { (label: $0.title, scope: UsageScope.window($0.id)) }
        if !visible.isEmpty {
            options.append((label: "Most urgent", scope: .mostUrgent))
        }
        return options
    }
}
