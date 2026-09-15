import Foundation
import Observation

// Observable, UserDefaults-backed settings. The static load/persist are the (pure-ish) testable seam.
@MainActor @Observable public final class SettingsStore {
    public private(set) var settings: Settings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onUpdate: (() -> Void)?

    // The account list is what `load`/`persist` sweep and write keys for. A parameter rather than a
    // global, and defaulted to the ONE-PER-HARNESS set rather than `Accounts.all`, so neither a test
    // nor a preview silently reads the user's own `accounts.json`. The app passes its real list.
    @ObservationIgnored private let accounts: [Integration]

    public init(defaults: UserDefaults = .standard, accounts: [Integration] = AccountsFile.defaultKeys) {
        self.defaults = defaults
        self.accounts = accounts
        self.settings = SettingsStore.load(from: defaults, accounts: accounts)
    }

    public func update(_ new: Settings) {
        settings = new
        SettingsStore.persist(new, to: defaults, accounts: accounts)
        onUpdate?()
    }

    // Per-provider keys, flat and sparse: `provider.<integration>.<field>`. A provider with no key
    // at all is absent from the dictionary and reads as `ProviderConfig.defaults`, so a new Integration
    // case needs no migration. The old `menuBar.*` and global display keys are swept on load, below.
    private nonisolated static func providerKey(_ i: Integration, _ field: String) -> String { "provider.\(i.rawValue).\(field)" }

    // Keys earlier shapes of the app left behind — the per-provider refactor's `menuBar.*`, and the
    // menu bar itself (icon style and tint, the number's tint, the Theme and Herdr toggles, the notch
    // switch). Removed on load rather than migrated: this is a single-user app, the reset already
    // happened on the one install, and reading them back would be a migration with nobody to migrate.
    // Removal is idempotent and costs one pass at launch.
    // Swept over the HARNESSES rather than the accounts: every one of these keys predates accounts,
    // so they only ever exist under a bare harness name. A key for an account that no longer exists
    // is left alone on purpose — removing an account from `accounts.json` to try a different config
    // directory should not throw away how its ring was set up.
    private nonisolated static let legacyKeys: [String] =
        Harness.allCases.flatMap { harness -> [String] in
            let i = Integration(harness: harness)
            return ["visible", "iconKind", "iconColor", "scope", "numberColor"].map { "menuBar.\(i.rawValue).\($0)" }
                + ["\(i.rawValue)Enabled", "provider.\(i.rawValue).showModelLimits"]
                + ["iconKind", "iconColor", "numberColor"].map { providerKey(i, $0) }
        } + ["showTokenEstimate", "showModelLimits", "compact", "widget.showUsage", "didFirstRunPrompt"]
        + ["appearance", "herdrActivity", "notchEnabled"]

    private nonisolated static func pruneLegacy(_ d: UserDefaults) {
        for key in legacyKeys where d.object(forKey: key) != nil { d.removeObject(forKey: key) }
    }

    public nonisolated static func load(from d: UserDefaults, accounts: [Integration] = AccountsFile.defaultKeys) -> Settings {
        let def = Settings.defaults
        func bool(_ k: String, _ fb: Bool) -> Bool { d.object(forKey: k) != nil ? d.bool(forKey: k) : fb }
        func dbl(_ k: String, _ fb: Double) -> Double { d.object(forKey: k) != nil ? d.double(forKey: k) : fb }
        // Clamped on the way in, where the value first enters the app: an out-of-range `notchScale`
        // reaches `Design.px` as a multiplier on every notch measurement, and `notchScale: 0` collapses
        // the whole surface. The ranges are the ones the sliders write.
        func clamped(_ k: String, _ fb: Double, _ range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, dbl(k, fb)))
        }
        func str(_ k: String) -> String { d.string(forKey: k) ?? "" }

        pruneLegacy(d)

        // An entry exists only when at least one of its keys is present. Each field falls back
        // INDIVIDUALLY, so one corrupt value can never reset its siblings.
        var providers: [Integration: ProviderConfig] = [:]
        for i in accounts {
            let visibleKey = providerKey(i, "visible")
            let scopeKey = providerKey(i, "scope")
            let extraCapsKey = providerKey(i, "showExtraCaps")
            let tokenEstimateKey = providerKey(i, "showTokenEstimate")
            let present = [visibleKey, scopeKey, extraCapsKey, tokenEstimateKey]
                .contains { d.object(forKey: $0) != nil }
            guard present else { continue }
            providers[i] = ProviderConfig(
                visible: bool(visibleKey, ProviderConfig.defaults.visible),
                scope: UsageScope(rawValue: str(scopeKey)) ?? ProviderConfig.defaults.scope,
                showExtraCaps: bool(extraCapsKey, ProviderConfig.defaults.showExtraCaps),
                showTokenEstimate: bool(tokenEstimateKey, ProviderConfig.defaults.showTokenEstimate))
        }

        // Deduped on the way in. The list is only ever written from a drag, but a hand-edited domain
        // could name a provider twice, and a repeat would put two rings on the notch for one harness
        // — two views under one identity, which is not a state SwiftUI has an answer for.
        var seen = Set<Integration>()
        let order = (d.array(forKey: "providerOrder") as? [String] ?? [])
            .compactMap(Integration.init(rawValue:))
            .filter { seen.insert($0).inserted }

        return Settings(
            usageLayout: UsageLayout(rawValue: str("usageLayout")) ?? def.usageLayout,
            warningAt: clamped("warningAt", def.warningAt, Settings.thresholdRange),
            criticalAt: clamped("criticalAt", def.criticalAt, Settings.thresholdRange),
            cardTrigger: CardTrigger(rawValue: str("cardTrigger")) ?? def.cardTrigger,
            notchScale: clamped("notchScale", def.notchScale, Settings.notchScaleRange),
            providerOrder: order,
            providers: providers)
    }

    public nonisolated static func persist(_ s: Settings, to d: UserDefaults, accounts: [Integration] = AccountsFile.defaultKeys) {
        d.set(s.usageLayout.rawValue, forKey: "usageLayout")
        d.set(s.warningAt, forKey: "warningAt")
        d.set(s.criticalAt, forKey: "criticalAt")
        d.set(s.cardTrigger.rawValue, forKey: "cardTrigger")
        d.set(s.notchScale, forKey: "notchScale")
        d.set(s.providerOrder.map(\.rawValue), forKey: "providerOrder")
        // Sparse write: an absent entry clears every one of its keys, so a round-trip through the
        // store reproduces the dictionary exactly instead of densifying it with defaults.
        for i in accounts {
            if let cfg = s.providers[i] {
                d.set(cfg.visible, forKey: providerKey(i, "visible"))
                d.set(cfg.scope.rawValue, forKey: providerKey(i, "scope"))
                d.set(cfg.showExtraCaps, forKey: providerKey(i, "showExtraCaps"))
                d.set(cfg.showTokenEstimate, forKey: providerKey(i, "showTokenEstimate"))
            } else {
                for field in ["visible", "scope", "showExtraCaps", "showTokenEstimate"] {
                    d.removeObject(forKey: providerKey(i, field))
                }
            }
        }
    }
}
