import Foundation

// Which meter a provider's percentage reflects. `.primary` follows the provider's shortest
// account window, `.mostUrgent` follows its most-used account window, and `.window` points at a
// provider-assigned stable id. Persisted as a string so a provider can add or rename windows without
// adding a Core case.
public enum UsageScope: Hashable, Sendable, RawRepresentable {
    case primary
    case mostUrgent
    case window(String)

    private static let windowPrefix = "window:"

    public init?(rawValue: String) {
        switch rawValue {
        case "primary": self = .primary
        case "urgent": self = .mostUrgent
        default:
            let id = String(rawValue.dropFirst(Self.windowPrefix.count))
            guard rawValue.hasPrefix(Self.windowPrefix), !id.isEmpty else { return nil }
            self = .window(id)
        }
    }

    public var rawValue: String {
        switch self {
        case .primary: "primary"
        case .mostUrgent: "urgent"
        case .window(let id): Self.windowPrefix + id
        }
    }
}

// Usage window render style — the deck's selectable layouts (same data, four looks).
public enum UsageLayout: String, Sendable { case linear, simple, dotMatrix, spotlight }

// When the hover card appears: as the pointer reaches a ring, or only once a ring is clicked.
public enum CardTrigger: String, Sendable { case hover, click }

// One global cadence for Claude/Codex local and subscription usage work. Closed choices keep the
// persisted value and every source floor on the same supported policy.
public enum UsageUpdateInterval: Int, Sendable, CaseIterable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var seconds: TimeInterval { TimeInterval(rawValue) }
}

// One provider's complete configuration. Every detected provider gets a ring; `visible` toggles it.
public struct ProviderConfig: Equatable, Sendable {
    public var visible: Bool  // the provider's ring is drawn on the notch
    public var scope: UsageScope  // which meter the percentage reflects
    public var showExtraCaps: Bool
    public var showTokenEstimate: Bool

    public init(
        visible: Bool, scope: UsageScope, showExtraCaps: Bool = true, showTokenEstimate: Bool = true
    ) {
        self.visible = visible
        self.scope = scope
        self.showExtraCaps = showExtraCaps
        self.showTokenEstimate = showTokenEstimate
    }

    public static let defaults = ProviderConfig(
        visible: true, scope: .primary, showExtraCaps: true, showTokenEstimate: true)
}

// Single source of truth for all global prefs (UI-agnostic value type). The app persists/loads this
// via UserDefaults in `SettingsStore`; the enums replace the reference's stringly-typed keys.
// Launch-at-login is deliberately absent: `SMAppService` is the store of record for it, and a
// persisted copy can only ever disagree with the system (see `LoginItem`).
public struct Settings: Equatable, Sendable {
    // The hover card
    public var usageLayout: UsageLayout
    public var warningAt: Double  // severity warning threshold (utilization %)
    public var criticalAt: Double  // severity critical threshold (utilization %)
    public var cardTrigger: CardTrigger
    public var updateInterval: UsageUpdateInterval

    // The notch's size, as a multiplier on the design frame's own scale (1 = a 44pt ring).
    public var notchScale: Double

    // The order the notch draws its rings in, as far as the user has said — one entry per login, so a
    // second Claude account can be dragged on its own. Sparse, like `providers`: a ring missing from
    // the list keeps its place behind the ones that are in it, so adding an Integration case or signing
    // in to a new profile needs no migration and a ⌘-drag never has to name every ring.
    public var providerOrder: [UsageKey]

    // Per-provider settings. Sparse by design — an absent entry means `ProviderConfig.defaults`, so
    // adding an Integration case needs no migration. Read it through `provider(for:)`, never by
    // subscripting directly. Shared by every login of that harness.
    public var providers: [Integration: ProviderConfig]

    // Each account's assigned name, keyed by `UsageAccount.id`. New accounts receive their provider's
    // automatic name; Settings can replace it with a manual rename.
    public var accountNames: [String: String]

    // Integration presence is detected from the harness's home directory, never from a stored flag.

    public init(
        usageLayout: UsageLayout, warningAt: Double, criticalAt: Double,
        cardTrigger: CardTrigger = .hover, updateInterval: UsageUpdateInterval = .fiveMinutes,
        notchScale: Double = 1,
        providerOrder: [UsageKey] = [], providers: [Integration: ProviderConfig] = [:],
        accountNames: [String: String] = [:]
    ) {
        self.usageLayout = usageLayout
        self.warningAt = warningAt
        self.criticalAt = criticalAt
        self.cardTrigger = cardTrigger
        self.updateInterval = updateInterval
        self.notchScale = notchScale
        self.providerOrder = providerOrder
        self.providers = providers
        self.accountNames = accountNames
    }

    /// `keys` in the order the notch draws them: the ones the user has placed, in that order, then
    /// everything else in the order it arrived.
    ///
    /// A ring that is switched off or missing from this Mac drops out of the stored list the next time
    /// the order is written, so it comes back at the end rather than in a slot the user can no longer
    /// see — which is also what a newly detected harness or a newly signed-in profile does.
    public func inNotchOrder(_ keys: [UsageKey]) -> [UsageKey] {
        let placed = providerOrder.filter(keys.contains)
        return placed + keys.filter { !placed.contains($0) }
    }

    // One provider's configuration, defaulted. The stored dictionary is sparse — only providers the
    // user has actually customized have an entry — so every read goes through here.
    public func provider(for integration: Integration) -> ProviderConfig {
        providers[integration] ?? .defaults
    }

    // Assign every unnamed account its provider-derived name. Empty values count as unnamed, while a
    // non-empty manual rename is never replaced.
    @discardableResult public mutating func assignAutomaticAccountNames(_ accounts: [UsageAccount]) -> Bool {
        var changed = false
        for account in accounts {
            let current = accountNames[account.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current?.isEmpty != false else { continue }
            accountNames[account.id] = account.suggestedName
            changed = true
        }
        return changed
    }

    public static let defaults = Settings(
        usageLayout: .spotlight, warningAt: 50, criticalAt: 80, providers: [:])

    // The ranges the numeric fields are allowed to hold, owned here so the slider that writes a value
    // and the loader that reads one back cannot disagree. `SettingsStore.load` clamps to them: a
    // defaults domain hand-edited or written by a future schema is the only way an out-of-range value
    // arrives, and `notchScale: 0` would drive every notch measurement to zero.
    // 0.7 is where the percent label under a ring drops to about 10pt, the smallest that still reads at
    // a glance; 1.1 is as large as four rings plus the card's slack fit under a 13-inch display.
    public static let notchScaleRange: ClosedRange<Double> = 0.7...1.1
    /// The grid the Size slider snaps to: five points of the percentage it shows, and both ends of
    /// the range sit on it, so the slider can still reach 70% and 110%.
    public static let notchScaleStep: Double = 0.05
    public static let thresholdRange: ClosedRange<Double> = 0...100
}
