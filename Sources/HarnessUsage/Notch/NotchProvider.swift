import Foundation
import HarnessUsageCore

// The notch's view of one provider: what its ring draws, and how much room its hover card needs.
//
// Everything the ring shows is resolved once, here, with the user's own settings applied — the same
// per-provider `scope` and the same severity thresholds the hover card reads, so the ring and the
// card cannot quote different numbers for one harness. The card itself is `UsageSection` and reads
// the stores directly; only its measured size belongs to the notch, because the panel has to reserve
// room for it before SwiftUI has laid anything out.
struct NotchProvider: Identifiable, Equatable {
    let integration: Integration
    /// 0...1 for the ring's sweep. Nil when the provider has reported nothing yet, which draws an
    /// empty track and a dash rather than an authoritative-looking 0%.
    let ringFraction: Double?
    /// The severity band the arc is coloured by, from the user's own Warning/Critical thresholds.
    let ringLevel: UsageLevel
    /// The limit is spent (100% or past it) and the ring is waiting for its reset, which dims the glyph.
    let isSpent: Bool
    /// What the cell prints under the ring.
    let headlineText: String
    /// The hover card's measured size, shadow ring included.
    let cardSize: CGSize

    var id: String { integration.rawValue }

    // Every detected, visible account, in the order the rest of the app lists them.
    //
    // Detection is the gate here exactly as it is for the Settings panes: an account that is not on
    // this Mac has no cell. `visible` is that account's own Enabled switch.
    @MainActor
    static func all(
        _ accounts: [Integration], usage: UsageStore, settings: SettingsStore,
        detected: Set<Integration>
    ) -> [NotchProvider] {
        settings.settings
            .inNotchOrder(
                accounts.filter {
                    detected.contains($0) && settings.settings.provider(for: $0).visible
                }
            )
            .map { build($0, usage: usage, settings: settings, accounts: accounts) }
    }

    @MainActor
    private static func build(
        _ integration: Integration, usage: UsageStore, settings: SettingsStore,
        accounts: [Integration]
    ) -> NotchProvider {
        let s = settings.settings
        let cfg = s.provider(for: integration)

        // The ring follows this provider's own scope — the same meter its hover card leads with.
        let ring = usage[integration].flatMap {
            UsageSelection.resolved($0, scope: cfg.scope, includingExtras: cfg.showExtraCaps)
        }
        let utilization = ring?.utilization ?? 0

        return NotchProvider(
            integration: integration,
            ringFraction: ring.map { min(max($0.utilization / 100, 0), 1) },
            ringLevel: UsageStyle.level(utilization, warningAt: s.warningAt, criticalAt: s.criticalAt),
            isSpent: utilization >= 100,
            headlineText: ring.map { "\(UsageFormat.percent($0.utilization))%" } ?? "—",
            cardSize: CGSize(
                width: NotchCardMetrics.totalWidth,
                height: NotchCardMetrics.height(
                    for: integration, usage: usage, settings: settings, accounts: accounts)))
    }
}
