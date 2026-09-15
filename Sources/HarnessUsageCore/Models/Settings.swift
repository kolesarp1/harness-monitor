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

    // The notch's size, as a multiplier on the design frame's own scale (1 = a 44pt ring).
    public var notchScale: Double

    // The order the notch draws its rings in, as far as the user has said. Sparse, like `providers`:
    // a harness missing from the list keeps its place behind the ones that are in it, so adding an
    // Integration case needs no migration and a ⌘-drag never has to name every provider.
    public var providerOrder: [Integration]

    // Per-provider settings. Sparse by design — an absent entry means `ProviderConfig.defaults`, so
    // adding an Integration case needs no migration. Read it through `provider(for:)`, never by
    // subscripting directly.
    public var providers: [Integration: ProviderConfig]

    // Integration presence is detected from the harness's home directory, never from a stored flag.

    public init(
        usageLayout: UsageLayout, warningAt: Double, criticalAt: Double,
        cardTrigger: CardTrigger = .hover, notchScale: Double = 1,
        providerOrder: [Integration] = [], providers: [Integration: ProviderConfig] = [:]
    ) {
        self.usageLayout = usageLayout
        self.warningAt = warningAt
        self.criticalAt = criticalAt
        self.cardTrigger = cardTrigger
        self.notchScale = notchScale
        self.providerOrder = providerOrder
        self.providers = providers
    }

    /// `integrations` in the order the notch draws them: the ones the user has placed, in that
    /// order, then everything else in the order it arrived.
    ///
    /// A provider that is switched off or missing from this Mac drops out of the stored list the
    /// next time the order is written, so it comes back at the end rather than in a slot the user
    /// can no longer see — which is also what a newly detected harness does.
    public func inNotchOrder(_ integrations: [Integration]) -> [Integration] {
        let placed = providerOrder.filter(integrations.contains)
        return placed + integrations.filter { !placed.contains($0) }
    }

    // One provider's configuration, defaulted. The stored dictionary is sparse — only providers the
    // user has actually customized have an entry — so every read goes through here.
    public func provider(for integration: Integration) -> ProviderConfig {
        providers[integration] ?? .defaults
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
