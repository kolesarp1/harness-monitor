import Foundation
import HarnessUsageCore

// The notch's view of one login: what its ring draws, and how much room its hover card needs.
//
// Everything the ring shows is resolved once, here, with the user's own settings applied — the same
// per-provider `scope` and the same severity thresholds the hover card reads, so the ring and the
// card cannot quote different numbers for one login. The card itself is `UsageSection` and reads
// the stores directly; only its measured size belongs to the notch, because the panel has to reserve
// room for it before SwiftUI has laid anything out.
struct NotchProvider: Identifiable, Equatable {
    /// Which reading the ring draws: a harness, and which of its logins.
    let key: UsageKey
    /// 0...1 for the ring's sweep. Nil when the provider has reported nothing yet, which draws an
    /// empty track and a dash rather than an authoritative-looking 0%.
    let ringFraction: Double?
    /// The severity band the arc is coloured by, from the user's own Warning/Critical thresholds.
    let ringLevel: UsageLevel
    /// The limit is spent (100% or past it) and the ring is waiting for its reset, which dims the glyph.
    let isSpent: Bool
    /// No current source works: the ring draws the last reading's arc in grey on a dashed track
    /// (concept E), and the card shows the reading's age with reset-passed windows as "Reset".
    let isStale: Bool
    /// What the cell prints under the ring.
    let headlineText: String
    /// The letter on the ring's chip. Set only while its harness reports more than one login: with one,
    /// the glyph already says whose ring it is.
    let accountLetter: String?
    /// The hover card's measured size, shadow ring included.
    let cardSize: CGSize

    var integration: Integration { key.integration }
    var id: String { key.rawValue }

    // Every visible login: each reading the engine publishes, plus the default login when a CLI
    // folder is present (the empty track while its first reading is on its way). An account-only
    // provider — a remembered subscription with no marker directory — shows only its account rings:
    // no phantom default ring for a folder that is not there.
    //
    // Visibility is the provider's own Enabled switch in both cases; detection (filesystem) and
    // account availability (remembered subscriptions) are the two gates.
    @MainActor
    static func all(
        usage: UsageStore, settings: SettingsStore, detected: Set<Integration>,
        accountAvailable: Set<Integration> = [],
        measureCard: @MainActor (UsageKey, UsageStore, SettingsStore) -> CGSize = {
            CGSize(
                width: NotchCardMetrics.totalWidth,
                height: NotchCardMetrics.height(for: $0, usage: $1, settings: $2))
        }
    ) -> [NotchProvider] {
        let s = settings.settings
        // Supported integrations only: suspended cases are never initialized or shown, though their
        // stored settings persist via `allCases`-based serialization.
        let keys = Integration.supportedCases
            .filter {
                (detected.contains($0) || accountAvailable.contains($0) || !usage.keys(for: $0).isEmpty)
                    && s.provider(for: $0).visible
            }
            .flatMap { integration -> [UsageKey] in
                let publishedReadings = usage.keys(for: integration)
                let visibleReadings = publishedReadings.filter { key in
                    !s.hideInactiveAccounts || usage[key]?.freshness != .disconnected
                }
                // Detection gets one placeholder only before this provider has published anything.
                // Hiding every disconnected reading must not turn them into a pending placeholder.
                // Recognized accounts use canonical identity keys, so adding a default beside them
                // would create a phantom duplicate ring.
                if detected.contains(integration), publishedReadings.isEmpty {
                    return [UsageKey(integration)]
                }
                return visibleReadings
            }
        return s.inNotchOrder(keys).map {
            build($0, usage: usage, settings: settings, cardSize: measureCard($0, usage, settings))
        }
    }

    @MainActor
    private static func build(
        _ key: UsageKey, usage: UsageStore, settings: SettingsStore, cardSize: CGSize
    ) -> NotchProvider {
        let s = settings.settings
        let cfg = s.provider(for: key.integration)
        let snapshot = usage[key]

        // The ring follows this provider's own scope — the same meter its hover card leads with.
        let ring = snapshot.flatMap {
            UsageSelection.resolved($0, scope: cfg.scope, includingExtras: cfg.showExtraCaps)
        }
        let stale = snapshot?.freshness == .disconnected
        let projection = ring.map { StaleWindowStyle.projection(window: $0, stale: stale) }
        let displayedRing = projection == .resetPassed ? nil : ring
        let utilization = displayedRing?.utilization ?? 0
        // A login whose account is not known yet — its first reading still on the way — letters itself
        // by its folder, so two rings are never briefly indistinguishable.
        let letter =
            usage.hasProfiles(key.integration)
            ? (snapshot?.account.map { AccountLabel.letter($0, names: s.accountNames) }
                ?? key.profile.map(AccountLabel.initial(of:)))
            : nil

        return NotchProvider(
            key: key,
            ringFraction: displayedRing.map { min(max($0.utilization / 100, 0), 1) },
            ringLevel: UsageStyle.level(utilization, warningAt: s.warningAt, criticalAt: s.criticalAt),
            isSpent: displayedRing != nil && utilization >= 100,
            isStale: stale,
            headlineText: projection == .resetPassed ? "Reset" : displayedRing.map { "\(UsageFormat.percent($0.utilization))%" } ?? "—",
            accountLetter: letter,
            cardSize: cardSize)
    }
}
