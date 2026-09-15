import Foundation
import Testing

@testable import HarnessUsageCore

private func account(_ id: String, _ title: String, _ value: Double, period: TimeInterval) -> UsageWindow {
    UsageWindow(id: id, title: title, utilization: value, period: period, kind: .account)
}

private func model(_ id: String, _ title: String, _ value: Double, period: TimeInterval? = nil) -> UsageWindow {
    UsageWindow(id: id, title: title, utilization: value, period: period, kind: .model(title))
}

private func snap(session: Double?, week: Double?, month: Double? = nil, extras: [UsageWindow] = []) -> UsageSnapshot {
    var windows: [UsageWindow] = []
    if let session { windows.append(account("5h", "Session", session, period: 5 * 3_600)) }
    if let week { windows.append(account("7d", "Weekly", week, period: 7 * 86_400)) }
    if let month { windows.append(account("cycle", "Monthly", month, period: 30 * 86_400)) }
    windows.append(contentsOf: extras)
    return UsageSnapshot(
        windows: windows, localTokensToday: nil, localTokensWeek: nil,
        source: .claudeOAuth, lastUpdated: .distantPast)
}

private func tokenOnlySnapshot() -> UsageSnapshot {
    UsageSnapshot(
        windows: [], localTokensToday: nil, localTokensWeek: nil,
        source: .opencodeLocal, lastUpdated: .distantPast, todayInput: 10, todayOutput: 20)
}

private func resolved(
    _ snapshot: UsageSnapshot, _ scope: UsageScope, includingExtras: Bool = true
) -> UsageWindow? {
    UsageSelection.resolved(snapshot, scope: scope, includingExtras: includingExtras)
}

@Test func tokenPredicatesSeparateCapabilityFromCurrentData() {
    let usage = [Integration.claude: snap(session: nil, week: nil)]
    #expect(UsageSelection.offersTokens(usage: usage))
}

@Test func providerSelectionPrefersTheMostDrained() {
    let settings = Settings.defaults
    let usage = [
        Integration.claude: snap(session: 40, week: 30),
        Integration.codex: snap(session: 70, week: 20),
    ]
    let providers = UsageSelection.availableProviders(usage: usage, settings: settings)
    #expect(UsageSelection.chosenProvider(providers, usage: usage, settings: settings) == .codex)
}

@Test func availableProvidersRespectPerProviderTokenToggles() {
    var settings = Settings.defaults
    var claude = settings.provider(for: .claude)
    claude.showTokenEstimate = false
    settings.providers[.claude] = claude
    let usage = [
        Integration.claude: tokenOnlySnapshot(),
        Integration.codex: tokenOnlySnapshot(),
    ]

    #expect(UsageSelection.availableProviders(usage: usage, settings: settings) == [.codex])
}

@Test func urgentPicksTheHigherOfSessionAndWeek() {
    #expect(resolved(snap(session: 30, week: 70), .mostUrgent)?.utilization == 70)
    #expect(resolved(snap(session: 91, week: 12), .mostUrgent)?.utilization == 91)
}

@Test func monthStandsInForAProviderWithOnlyACycle() {
    let cycleOnly = snap(session: nil, week: nil, month: 64)
    #expect(resolved(cycleOnly, .primary)?.utilization == 64)
    #expect(resolved(cycleOnly, .window("7d"))?.utilization == 64)
    #expect(resolved(snap(session: 20, week: 10, month: 99), .mostUrgent)?.utilization == 99)
}

@Test func aStoredWindowFallsBackToThePrimaryWindowWhenItDisappears() {
    #expect(resolved(snap(session: nil, week: 88), .window("5h"))?.utilization == 88)
    #expect(resolved(snap(session: 88, week: nil), .window("7d"))?.utilization == 88)
    #expect(resolved(snap(session: nil, week: nil), .window("5h")) == nil)
}

@Test func mostUrgentFallsBackToWhicheverSingleAccountWindowExists() {
    #expect(resolved(snap(session: nil, week: 45), .mostUrgent)?.utilization == 45)
    #expect(resolved(snap(session: 45, week: nil), .mostUrgent)?.utilization == 45)
    #expect(resolved(snap(session: nil, week: nil), .mostUrgent) == nil)
}

@Test func prolitePlanOffersOnlyTheWindowsItReports() {
    let snapshot = snap(
        session: nil, week: 15,
        extras: [
            model("model:Spark:5h", "Spark 5h", 0, period: 18_000),
            model("model:Spark:7d", "Spark Weekly", 0, period: 604_800),
        ])

    let options = UsageSelection.scopeOptions(snapshot, includingExtras: true)
    #expect(options.map(\.label) == ["Spark 5h", "Weekly", "Spark Weekly", "Most urgent"])
    #expect(
        options.map(\.scope) == [.window("model:Spark:5h"), .window("7d"), .window("model:Spark:7d"), .mostUrgent])
    #expect(resolved(snapshot, .mostUrgent)?.id == "7d")
}

@Test func namedScopeResolvesToItsCapAndFallsBackWhenItIsGone() {
    let id = "model:Spark:5h"
    let snapshot = snap(
        session: nil,
        week: 15,
        extras: [model(id, "Spark 5h", 0, period: 18_000)])
    #expect(resolved(snapshot, .window(id))?.utilization == 0)

    let withoutExtras = snap(session: nil, week: 15)
    #expect(resolved(withoutExtras, .window(id))?.title == "Weekly")
}

// Defect: `availableProviders` testing the unfiltered window list while the card's content tests the
// filtered one, so a provider whose only caps Extra hides is offered a row that draws no meters.
@Test func extrasOffDropsAProviderWhoseOnlyWindowsAreModelCaps() {
    var settings = Settings.defaults
    var codex = ProviderConfig.defaults
    codex.showExtraCaps = false
    codex.showTokenEstimate = false
    settings.providers[.codex] = codex
    let usage = [
        Integration.codex: UsageSnapshot(
            windows: [model("model:Spark:5h", "Spark 5h", 0)],
            localTokensToday: nil, localTokensWeek: nil, source: .codexUsageAPI, lastUpdated: .distantPast)
    ]

    #expect(UsageSelection.availableProviders(usage: usage, settings: settings).isEmpty)

    codex.showExtraCaps = true
    settings.providers[.codex] = codex
    #expect(UsageSelection.availableProviders(usage: usage, settings: settings) == [.codex])
}

@Test func aProviderWithOnlyModelWindowsIsAvailableWhenItsEstimateIsOn() {
    let snapshot = UsageSnapshot(
        windows: [model("model:Spark:5h", "Spark 5h", 0)],
        localTokensToday: nil, localTokensWeek: nil, source: .codexUsageAPI, lastUpdated: .distantPast)
    let settings = Settings.defaults

    #expect(UsageSelection.availableProviders(usage: [.codex: snapshot], settings: settings) == [.codex])
}

@Test func mostUrgentTakesTheFullestCapWhenExtrasAreOn() {
    let snapshot = snap(session: 47, week: 69, extras: [model("model:Fable", "Fable", 84)])

    #expect(resolved(snapshot, .mostUrgent, includingExtras: true)?.id == "model:Fable")
    #expect(resolved(snapshot, .mostUrgent, includingExtras: false)?.id == "7d")
}

@Test func extrasOffHidesACapFromSelectionEntirely() {
    let snapshot = snap(session: 47, week: 69, extras: [model("model:Fable", "Fable", 84)])
    let options = UsageSelection.scopeOptions(snapshot, includingExtras: false)

    #expect(options.map(\.label) == ["Session", "Weekly", "Most urgent"])
    #expect(!options.contains { $0.label == "Fable" })
    #expect(resolved(snapshot, .window("model:Fable"), includingExtras: false)?.id == "5h")
}

@Test func primaryIgnoresTheExtraSwitch() {
    let snapshot = snap(session: 47, week: 69, extras: [model("model:Fable", "Fable", 0, period: 1_800)])

    #expect(resolved(snapshot, .primary, includingExtras: true)?.id == "5h")
    #expect(resolved(snapshot, .primary, includingExtras: false)?.id == "5h")
}
