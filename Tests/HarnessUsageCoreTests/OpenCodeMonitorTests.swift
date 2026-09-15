import Foundation
import SQLite3
import Testing

@testable import HarnessUsageCore

private struct FixtureError: Error { let message: String }

private func opencodeDB(home: URL) -> URL {
    home.appendingPathComponent(".local/share/opencode/opencode.db")
}

// A real `opencode.db` holding the `session` columns the reader selects.
private func writeSessionDB(home: URL, rows: [(input: Int, output: Int, reasoning: Int, cost: Double, updatedMS: Int64)]) throws {
    let url = opencodeDB(home: home)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw FixtureError(message: "could not create \(url.path)")
    }
    defer { sqlite3_close(db) }
    var sql = """
        CREATE TABLE session (
            tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
            time_updated INTEGER, cost REAL, time_archived INTEGER);
        """
    for r in rows {
        sql += "INSERT INTO session VALUES (\(r.input), \(r.output), \(r.reasoning), \(r.updatedMS), \(r.cost), NULL);"
    }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw FixtureError(message: "could not seed session")
    }
}

private let now = Date(timeIntervalSince1970: 1_755_600_000)

// Defect: `readRows` returned [] for every failure, and `scan` turned [] into nil — so a detected but
// unreadable opencode produced no row and no note anywhere in the app, indistinguishable from an
// installed opencode that has simply not been used.
@Test func anUnreadableOpenCodeDatabaseSaysSoInsteadOfGoingSilent() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let url = opencodeDB(home: home)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("this is not a database".utf8).write(to: url)

    let snapshot = try #require(await OpenCodeMonitor(home: home, now: { now }).reload(wantUsageEstimate: false))
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.note?.hasPrefix("Could not read opencode.db") == true)
}

// The other half of the same contract: an opencode that opens fine but has no sessions in the window
// stays silent, because there is nothing wrong to report.
@Test func anEmptyOpenCodeDatabaseStaysSilent() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    try writeSessionDB(home: home, rows: [])

    #expect(await OpenCodeMonitor(home: home, now: { now }).reload(wantUsageEstimate: false) == nil)
}

// Defect: opencode's "this week" was a rolling 168 hours while Claude's was calendar — the same card
// could print two different weeks. A session from before the most recent Monday must not be counted.
@Test func openCodeCountsTheWeekFromTheMostRecentMonday() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let monday = UsageMath.mostRecentMonday(onOrBefore: now, calendar: calendar)
    func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    try writeSessionDB(
        home: home,
        rows: [
            (input: 100, output: 20, reasoning: 0, cost: 0.5, updatedMS: ms(now)),
            (input: 7, output: 3, reasoning: 0, cost: 0.1, updatedMS: ms(monday.addingTimeInterval(60))),
            // Inside a rolling 168 hours but in the PREVIOUS calendar week — the row this pins out.
            (input: 999, output: 999, reasoning: 0, cost: 9, updatedMS: ms(monday.addingTimeInterval(-60))),
        ])

    let snapshot = try #require(await OpenCodeMonitor(home: home, now: { now }).reload(wantUsageEstimate: false))
    #expect(snapshot.localTokensWeek == 130)
    #expect(snapshot.localTokensToday == 120)
}
