import Foundation
import Testing

@testable import HarnessUsageCore

// An isolated UserDefaults suite per test — the store writes real keys, and tests run in parallel.
@MainActor
private func freshDefaults() -> UserDefaults {
    let suite = "HarnessUsageTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite) ?? .standard
    d.removePersistentDomain(forName: suite)
    return d
}

@MainActor
@Test func loadsDefaultsWhenEmpty() {
    #expect(SettingsStore(defaults: freshDefaults()).settings == .defaults)
    // Sparse by construction: no provider has an entry until one is customized.
    #expect(SettingsStore(defaults: freshDefaults()).settings.providers.isEmpty)
}

// The per-provider display toggles round-trip, including the off state (a plain `d.bool` read would
// collapse an intentionally-off flag into the default-on value without the presence check).
@MainActor
@Test func displayTogglesRoundTrip() {
    let d = freshDefaults()
    let store = SettingsStore(defaults: d)
    var s = store.settings
    var claude = s.provider(for: .claude)
    claude.showTokenEstimate = false
    s.providers[.claude] = claude
    var codex = s.provider(for: .codex)
    codex.showExtraCaps = false
    s.providers[.codex] = codex
    store.update(s)

    let reloaded = SettingsStore(defaults: d).settings
    #expect(!reloaded.provider(for: .claude).showTokenEstimate)
    #expect(reloaded.provider(for: .claude).showExtraCaps)
    #expect(!reloaded.provider(for: .codex).showExtraCaps)
    #expect(reloaded.provider(for: .codex).showTokenEstimate)
}

// Defect this guards: key-name drift between persist and load, or a dense write that adds default
// entries for providers the user never touched (breaking round-trip equality).
@MainActor
@Test func providerKeysRoundTrip() {
    let d = freshDefaults()
    let store = SettingsStore(defaults: d)
    var s = store.settings
    let codex = ProviderConfig(
        visible: true, scope: .window("7d"), showExtraCaps: false, showTokenEstimate: true)
    let opencode = ProviderConfig(
        visible: false, scope: .window("model:Spark:7d"), showExtraCaps: true, showTokenEstimate: false)
    s.providers[.codex] = codex
    s.providers[.opencode] = opencode
    store.update(s)

    let reloaded = SettingsStore(defaults: d).settings
    #expect(reloaded.providers.count == 2)
    #expect(reloaded.providers[.codex] == codex)
    #expect(reloaded.providers[.opencode] == opencode)
    #expect(reloaded.provider(for: .cursor) == .defaults)  // absent reads as defaults
    #expect((d.object(forKey: "provider.codex.showExtraCaps") as? Bool) == false)
    #expect((d.object(forKey: "provider.opencode.scope") as? String) == "window:model:Spark:7d")
    #expect((d.object(forKey: "provider.opencode.showTokenEstimate") as? Bool) == false)
    #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("menuBar.") }.isEmpty)
    #expect(reloaded == s)
}

// Defect this guards: removing a customization leaves its keys behind, so the next load resurrects it.
@MainActor
@Test func removingAnEntryClearsItsPersistedKeys() {
    let d = freshDefaults()
    let store = SettingsStore(defaults: d)
    var s = store.settings
    s.providers[.cursor] = ProviderConfig(
        visible: false, scope: .window("7d"), showExtraCaps: false, showTokenEstimate: false)
    store.update(s)
    #expect(SettingsStore(defaults: d).settings.providers[.cursor] != nil)

    s.providers[.cursor] = nil
    store.update(s)
    #expect(SettingsStore(defaults: d).settings.providers.isEmpty)
    for field in ["visible", "scope", "showExtraCaps", "showTokenEstimate"] {
        #expect(d.object(forKey: "provider.cursor.\(field)") == nil)
    }
}

// Defect this guards: one bad field resetting the whole struct, so a hand-edited or corrupt value
// silently discards the user's other choices.
@MainActor
@Test func oneCorruptFieldFallsBackAloneWhileSiblingsSurvive() {
    let d = freshDefaults()
    let store = SettingsStore(defaults: d)
    var s = store.settings
    s.providers[.claude] = ProviderConfig(
        visible: false, scope: .mostUrgent, showExtraCaps: false, showTokenEstimate: false)
    store.update(s)

    d.set("purple", forKey: "provider.claude.scope")

    let reloaded = SettingsStore(defaults: d).settings
    let cfg = reloaded.provider(for: .claude)
    #expect(cfg.scope == .primary)  // the only field that falls back
    #expect(cfg.visible == false)
    #expect(cfg.showExtraCaps == false)
    #expect(cfg.showTokenEstimate == false)
}

// The entry must materialise from any one of its keys, including the newest toggle.
@MainActor
@Test func aLoneTokenEstimateKeyCreatesTheEntry() {
    let d = freshDefaults()
    d.set(false, forKey: "provider.cursor.showTokenEstimate")
    let loaded = SettingsStore(defaults: d).settings
    #expect(
        loaded.providers[.cursor]
            == ProviderConfig(visible: true, scope: .primary, showExtraCaps: true, showTokenEstimate: false))
}

// Defect this guards: an entry created from a partial key set losing the fields that ARE present.
@MainActor
@Test func aSingleKeyCreatesAnEntryWithPerFieldDefaults() {
    let d = freshDefaults()
    d.set("window:7d", forKey: "provider.codex.scope")

    let loaded = SettingsStore(defaults: d).settings
    #expect(loaded.providers[.codex] == ProviderConfig(visible: true, scope: .window("7d")))
    #expect(loaded.providers.count == 1)
}

// A key the loader does not read materialises nothing. Defect: a presence check widened to "any
// `menuBar.<i>.*` key" would create a provider entry out of a stray value the user cannot see or change.
@MainActor
@Test func theSupersededIconKeyIsIgnoredEntirely() {
    let d = freshDefaults()
    d.set("matrixBrand", forKey: "menuBar.claude.icon")

    let loaded = SettingsStore(defaults: d).settings
    #expect(loaded.providers.isEmpty)
    #expect(loaded.provider(for: .claude) == .defaults)
}

// The menu bar's keys are legacy too now, per-provider ones included. Defect this guards: a stale
// `provider.<i>.iconKind` left in the domain materialising a provider entry the user never asked for —
// so the sweep has to reach them, not just the fields the loader stopped reading.
@MainActor
@Test func legacyKeysAreRemovedOnLoad() {
    let d = freshDefaults()
    d.set("week", forKey: "menuBar.claude.scope")
    d.set(true, forKey: "claudeEnabled")
    d.set(false, forKey: "showTokenEstimate")
    let oldExtraKey = "provider.claude." + ["show", "ModelLimits"].joined()
    d.set(false, forKey: oldExtraKey)
    let menuBarKeys =
        ["appearance", "herdrActivity", "notchEnabled"]
        + ["iconKind", "iconColor", "numberColor"].map { "provider.claude.\($0)" }
    d.set("dark", forKey: "appearance")
    d.set(true, forKey: "herdrActivity")
    d.set(false, forKey: "notchEnabled")
    d.set("matrix", forKey: "provider.claude.iconKind")
    d.set("brand", forKey: "provider.claude.iconColor")
    d.set("usage", forKey: "provider.claude.numberColor")

    let loaded = SettingsStore(defaults: d).settings
    #expect(d.object(forKey: "menuBar.claude.scope") == nil)
    #expect(d.object(forKey: "claudeEnabled") == nil)
    #expect(d.object(forKey: "showTokenEstimate") == nil)
    #expect(d.object(forKey: oldExtraKey) == nil)
    for key in menuBarKeys { #expect(d.object(forKey: key) == nil) }
    #expect(loaded == .defaults)
    #expect(loaded.providers.isEmpty)  // a dead icon key must not conjure an entry
}

// Defect: UI cadence persisting a display label or arbitrary seconds that the source floors cannot
// interpret consistently after relaunch.
@MainActor
@Test func updateIntervalRoundTripsOnlySupportedValues() {
    for interval in UsageUpdateInterval.allCases {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        var settings = store.settings
        settings.updateInterval = interval
        store.update(settings)
        #expect(SettingsStore(defaults: defaults).settings.updateInterval == interval)
        #expect(defaults.integer(forKey: "updateIntervalSeconds") == interval.rawValue)
    }
    let invalid = freshDefaults()
    invalid.set(42, forKey: "updateIntervalSeconds")
    #expect(SettingsStore(defaults: invalid).settings.updateInterval == .fiveMinutes)
}

// The two notch globals round-trip, including a non-default trigger and a fractional size.
@MainActor
@Test func notchSizeAndCardTriggerRoundTrip() {
    let d = freshDefaults()
    let store = SettingsStore(defaults: d)
    var s = store.settings
    s.notchScale = 0.8
    s.cardTrigger = .click
    store.update(s)
    let reloaded = SettingsStore(defaults: d).settings
    #expect(reloaded.notchScale == 0.8)
    #expect(reloaded.cardTrigger == .click)
}

// Defect: an out-of-range value loaded verbatim. `notchScale: 0` multiplies every notch measurement
// to zero, and a threshold outside 0...100 puts a severity band where no meter can reach it.
@MainActor
@Test func outOfRangeNumbersAreClampedOnLoad() {
    let d = freshDefaults()
    d.set(0, forKey: "notchScale")
    d.set(-30, forKey: "warningAt")
    d.set(420, forKey: "criticalAt")

    let loaded = SettingsStore(defaults: d).settings
    #expect(loaded.notchScale == Settings.notchScaleRange.lowerBound)
    #expect(loaded.warningAt == Settings.thresholdRange.lowerBound)
    #expect(loaded.criticalAt == Settings.thresholdRange.upperBound)

    let high = freshDefaults()
    high.set(9, forKey: "notchScale")
    #expect(SettingsStore(defaults: high).settings.notchScale == Settings.notchScaleRange.upperBound)
}

// The ring order survives a relaunch, a profile's own ring included, and a hand-edited domain can neither
// make one ring draw twice nor name a profile with no name.
@MainActor
@Test func theRingOrderRoundTripsAndCannotRepeatARing() {
    let d = freshDefaults()
    let store = SettingsStore(defaults: d)
    var s = store.settings
    let order = [UsageKey(.cursor), UsageKey(.claude, profile: "work"), UsageKey(.claude)]
    s.providerOrder = order
    store.update(s)
    #expect(SettingsStore(defaults: d).settings.providerOrder == order)
    #expect((d.array(forKey: "providerOrder") as? [String]) == ["cursor", "claude:work", "claude"])

    d.set(["cursor", "claude", "cursor", "nonesuch", "claude:"], forKey: "providerOrder")
    #expect(SettingsStore(defaults: d).settings.providerOrder == [UsageKey(.cursor), UsageKey(.claude)])
}

// A dragged order leads; anything it does not name keeps its place behind it, in the order it came.
@MainActor
@Test func theNotchOrderPlacesWhatWasDraggedAndAppendsTheRest() {
    let claude = UsageKey(.claude)
    let codex = UsageKey(.codex)
    let cursor = UsageKey(.cursor)
    let opencode = UsageKey(.opencode)
    var s = Settings.defaults
    s.providerOrder = [cursor, claude]
    #expect(s.inNotchOrder([claude, codex, cursor, opencode]) == [cursor, claude, codex, opencode])
    // A ring that is off or absent is not conjured back into the stack by the stored order.
    #expect(s.inNotchOrder([codex, claude]) == [claude, codex])
    // No order stored: the list is handed back exactly as it arrived.
    #expect(Settings.defaults.inNotchOrder([codex, claude]) == [codex, claude])
}

// Defect this guards: assigned account names lost on relaunch.
@MainActor
@Test func accountNamesRoundTripIncludingAnEmptyStoredValue() {
    let d = freshDefaults()
    let store = SettingsStore(defaults: d)
    var s = store.settings
    s.accountNames = ["acct-a/org-a": "Work", "acct-b/org-b": ""]
    store.update(s)
    #expect(SettingsStore(defaults: d).settings.accountNames == ["acct-a/org-a": "Work", "acct-b/org-b": ""])
}

// Defect: folder aliases winning over the subscription profile or email prefix, so an account named
// `alex.k` appears as "Work" merely because it lives under `.codex-work`.
@Test func automaticAccountNamesPreferTheSubscriptionThenEmailPrefix() {
    #expect(
        UsageAccount.automaticName(
            reportedName: "  alex.k  ", email: "other@example.com", fallback: "work")
            == "alex.k")
    #expect(
        UsageAccount.automaticName(reportedName: nil, email: "alex.k@example.com", fallback: "work")
            == "alex.k")
    #expect(UsageAccount.automaticName(reportedName: nil, email: nil, fallback: "work") == "work")
}

// Defect: a new account remaining unnamed, or a later refresh overwriting a manual rename. Empty
// persisted names are incomplete assignments and receive the automatic name too.
@Test func newAccountsReceiveAutomaticNamesWithoutReplacingManualOnes() {
    func account(_ id: String, _ name: String) -> UsageAccount {
        UsageAccount(id: id, email: nil, plan: nil, location: "~/.codex", suggestedName: name)
    }
    var settings = Settings.defaults
    settings.accountNames = ["manual": "Personal", "empty": ""]

    let changed = settings.assignAutomaticAccountNames([
        account("manual", "Ignored"), account("empty", "Recovered"), account("new", "alex.k"),
    ])
    #expect(changed)
    #expect(settings.accountNames == ["manual": "Personal", "empty": "Recovered", "new": "alex.k"])
    let changedAgain = settings.assignAutomaticAccountNames([account("new", "Changed")])
    #expect(changedAgain == false)
}
