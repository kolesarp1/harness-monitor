import Foundation
import Testing

@testable import HarnessUsageCore

private func account(_ id: String, _ title: String, _ value: Double, period: TimeInterval) -> UsageWindow {
    UsageWindow(id: id, title: title, utilization: value, period: period, kind: .account)
}

private func model(_ id: String, _ title: String, _ value: Double, period: TimeInterval? = nil) -> UsageWindow {
    UsageWindow(id: id, title: title, utilization: value, period: period, kind: .model(title))
}

private func snap(
    session: Double?, week: Double?, month: Double? = nil, extras: [UsageWindow] = []
) -> UsageSnapshot {
    var windows: [UsageWindow] = []
    if let session { windows.append(account("5h", "Session", session, period: 5 * 3_600)) }
    if let week { windows.append(account("7d", "Weekly", week, period: 7 * 86_400)) }
    if let month { windows.append(account("cycle", "Monthly", month, period: 30 * 86_400)) }
    windows.append(contentsOf: extras)
    return UsageSnapshot(
        windows: windows, localTokensToday: nil, localTokensWeek: nil,
        source: .claudeOAuth, lastUpdated: .distantPast)
}

private func value(_ snapshot: UsageSnapshot, id: String) -> Double? {
    snapshot.windows.first { $0.id == id }?.utilization
}

@Test func modelKindRawValueKeepsItsName() {
    let kind = UsageWindow.Kind.model("Fable")
    #expect(kind.rawValue == "model:Fable")
    #expect(UsageWindow.Kind(rawValue: kind.rawValue) == kind)
    #expect(kind.modelName == "Fable")
    #expect(!kind.isAccount)
}

// Window order is defined once in `UsageSnapshot.init`, and every surface renders it. Defect: a
// surface re-deriving the order and drifting from the others.
@Test func rowsOrderIsSessionThenWeeklyThenMonthlyThenTheProvidersOwnLimits() {
    let fable = model("model:Fable", "Fable", 33)
    let ember = model("model:Ember", "Ember", 12)

    let full = snap(session: 43, week: 31, month: 8, extras: [fable, ember])
    #expect(full.windows.map(\.title) == ["Session", "Weekly", "Monthly", "Fable", "Ember"])
    #expect(value(full, id: "5h") == 43)
    #expect(value(full, id: "7d") == 31)
    #expect(value(full, id: "cycle") == 8)
    #expect(value(full, id: "model:Fable") == 33)
    #expect(value(full, id: "model:Ember") == 12)

    #expect(snap(session: 43, week: 31, extras: [fable]).windows.map(\.title) == ["Session", "Weekly", "Fable"])
    #expect(snap(session: nil, week: nil, month: 64).windows.map(\.title) == ["Monthly"])
    #expect(snap(session: nil, week: nil).windows.isEmpty)
}

@Test func spotlightLeadsWithTheFirstRowAndKeepsEveryOtherOne() {
    let fable = model("model:Fable", "Fable", 33)
    let full = snap(session: 44, week: 30, extras: [fable])

    let split = full.spotlightRows(showingExtras: true)
    #expect(split.hero?.title == "Session")
    #expect(split.compact.map(\.title) == ["Weekly", "Fable"])
    #expect(split.compact.count + 1 == full.windows.count)

    let cursor = snap(session: nil, week: nil, month: 64).spotlightRows(showingExtras: true)
    #expect(cursor.hero?.title == "Monthly")
    #expect(cursor.compact.isEmpty)
    #expect(snap(session: nil, week: nil).spotlightRows(showingExtras: true).hero == nil)
}

// Defect: `resolved` falling back to a `primaryWindow` computed over the unfiltered list, so a
// provider whose only cap the Extra switch hides still lights a ring — while the card it opens draws
// no meters at all.
@Test func extrasEnterTheUrgentComparisonOnlyWhenIncluded() {
    let hot = [model("model:Fable", "Fable", 99)]
    #expect(UsageSelection.resolved(snap(session: 20, week: 10, extras: hot), scope: .mostUrgent, includingExtras: false)?.utilization == 20)
    #expect(UsageSelection.resolved(snap(session: 20, week: 10, extras: hot), scope: .mostUrgent, includingExtras: true)?.utilization == 99)
    #expect(UsageSelection.resolved(snap(session: nil, week: nil, extras: hot), scope: .mostUrgent, includingExtras: false) == nil)
}

// Defect: the ring and the card disagreeing about a provider whose windows are all model caps —
// three encodings of one comparator is how they drifted, so pin every scope against the card's hero.
@Test func theRingAndTheCardAgreeWhenExtrasAreHidden() {
    let capsOnly = snap(session: nil, week: nil, extras: [model("model:Fable", "Fable", 99)])
    for scope in [UsageScope.primary, .mostUrgent, .window("model:Fable")] {
        #expect(UsageSelection.resolved(capsOnly, scope: scope, includingExtras: false) == nil)
    }
    #expect(capsOnly.spotlightRows(showingExtras: false).hero == nil)
    #expect(capsOnly.spotlightRows(showingExtras: false).compact.isEmpty)

    let mixed = snap(session: 20, week: 10, extras: [model("model:Fable", "Fable", 99)])
    #expect(UsageSelection.resolved(mixed, scope: .primary, includingExtras: false)?.id == mixed.spotlightRows(showingExtras: false).hero?.id)
    #expect(UsageSelection.resolved(mixed, scope: .primary, includingExtras: true)?.id == mixed.spotlightRows(showingExtras: true).hero?.id)
}

@Test func rowsOrderByWindowLengthAcrossAccountWindowsAndExtras() {
    let spark5h = model("model:Spark:5h", "Spark 5h", 0, period: 5 * 3_600)
    let sparkWeek = model("model:Spark:7d", "Spark Weekly", 40, period: 7 * 86_400)
    let fable = model("model:Fable", "Fable", 33)

    let codexProlite = snap(session: nil, week: 14, extras: [spark5h, sparkWeek])
    #expect(codexProlite.windows.map(\.title) == ["Spark 5h", "Weekly", "Spark Weekly"])

    let tied = snap(session: 63, week: 55, extras: [sparkWeek])
    #expect(tied.windows.map(\.title) == ["Session", "Weekly", "Spark Weekly"])

    let claude = snap(session: 44, week: 30, extras: [fable])
    #expect(claude.windows.map(\.title) == ["Session", "Weekly", "Fable"])
}

@Test func hidingModelLimitsLeavesOnlyTheAccountWindows() {
    let spark5h = model("model:Spark:5h", "Spark 5h", 0, period: 5 * 3_600)
    let s = snap(session: nil, week: 14, extras: [spark5h])

    #expect(s.windows(includingExtras: true).map(\.title) == ["Spark 5h", "Weekly"])
    #expect(s.windows(includingExtras: false).map(\.title) == ["Weekly"])

    let split = s.spotlightRows(showingExtras: false)
    #expect(split.hero?.title == "Weekly")
    #expect(split.compact.isEmpty)
}

@Test func heroIsTheShortestAccountWindowNotAModelCap() {
    let spark5h = model("model:Spark:5h", "Spark 5h", 0, period: 18_000)
    let sparkWeek = model("model:Spark:7d", "Spark Weekly", 0, period: 604_800)
    let prolite = snap(session: nil, week: 15, extras: [spark5h, sparkWeek]).spotlightRows(showingExtras: true)
    #expect(prolite.hero?.title == "Weekly")
    #expect(prolite.compact.map(\.title) == ["Spark 5h", "Spark Weekly"])

    let claude = snap(session: 17, week: 63, extras: [model("model:Fable", "Fable", 81)])
    #expect(claude.spotlightRows(showingExtras: true).hero?.title == "Session")
}

@Test func renamingACapKeepsTheStoredScope() {
    let id = "model:GPT-5.3-Codex-Spark:5h"
    let snapshot = UsageSnapshot(
        windows: [model(id, "Spark II 5h", 12, period: 18_000)],
        localTokensToday: nil, localTokensWeek: nil, source: .codexUsageAPI, lastUpdated: .distantPast)

    let resolved = UsageSelection.resolved(snapshot, scope: .window(id), includingExtras: true)
    #expect(resolved?.id == id)
    #expect(resolved?.title == "Spark II 5h")
}

@Test func aProviderWithNoAccountWindowStillLeads() {
    let snapshot = UsageSnapshot(
        windows: [model("model:Spark:5h", "Spark 5h", 0, period: 18_000)],
        localTokensToday: nil, localTokensWeek: nil, source: .codexUsageAPI, lastUpdated: .distantPast)

    #expect(snapshot.primaryWindow?.id == "model:Spark:5h")
}

@Test func hidingModelCapsCannotLeaveOneAsHero() {
    let snapshot = UsageSnapshot(
        windows: [
            model("model:Spark:5h", "Spark 5h", 99, period: 18_000),
            account("7d", "Weekly", 15, period: 7 * 86_400),
        ], localTokensToday: nil, localTokensWeek: nil, source: .codexUsageAPI, lastUpdated: .distantPast)

    #expect(snapshot.spotlightRows(showingExtras: true).hero?.id == "7d")
    #expect(snapshot.spotlightRows(showingExtras: false).hero?.id == "7d")
    #expect(snapshot.spotlightRows(showingExtras: false).compact.isEmpty)
}
