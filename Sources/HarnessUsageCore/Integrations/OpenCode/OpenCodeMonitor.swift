import Foundation
import SQLite3

// The opencode integration: token usage read PASSIVELY from ~/.local/share/opencode/opencode.db — no
// auth and no network (same posture as Codex). One scan reads the `session` table via the system
// SQLite C API. opencode runs the DB in WAL mode; the `session` table checkpoints often enough that the
// system SQLite reads it fine.
//
// Internal 2s throttle: the Engine calls `reload` every 400ms but the DB read runs at most every 2s.
public actor OpenCodeMonitor: IntegrationMonitor {
    private let home: URL
    private let now: @Sendable () -> Date
    private var lastScan: Date = .distantPast
    private var cached: UsageSnapshot?

    private static let scanInterval: TimeInterval = 2

    public init(home: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.now = now
    }

    private var dbPath: String {
        home.appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    // The DB directory, not the file: SQLite writes land in the -wal/-shm siblings.
    public nonisolated var watchPaths: [URL] {
        [home.appendingPathComponent(".local/share/opencode")]
    }

    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        if now().timeIntervalSince(lastScan) < Self.scanInterval, let cached {
            return cached
        }
        let result = scan()
        cached = result
        lastScan = now()
        return result
    }

    public func invalidateThrottles() {
        lastScan = .distantPast
    }

    // What the database read produced. "Opened, zero rows" is opencode installed and idle, which is
    // correctly silent; "could not open" is a fault the user can act on, and returning [] for both left
    // a detected-but-unreadable opencode with no row and no explanation anywhere in the app.
    public enum ReadResult: Sendable {
        case rows([OpenCodeLogic.Row])
        case unreadable(String)
    }

    func scan() -> UsageSnapshot? {
        let nowDate = now()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        // "This week" is the calendar week, the same boundary Claude's estimator uses — a rolling 168
        // hours here meant one card printed two different weeks depending on which row you read.
        let sinceMS = Int64(UsageMath.mostRecentMonday(onOrBefore: nowDate, calendar: cal).timeIntervalSince1970 * 1000)

        switch Self.readRows(dbPath: dbPath, sinceMS: sinceMS) {
        case .rows(let rows):
            guard !rows.isEmpty else { return nil }
            return OpenCodeLogic.usage(rows: rows, now: nowDate, calendar: cal)
        case .unreadable(let reason):
            return UsageSnapshot(
                windows: [], localTokensToday: nil, localTokensWeek: nil,
                source: .opencodeLocal, lastUpdated: nowDate, note: reason)
        }
    }

    // Read `session` rows updated since `sinceMS` (epoch ms), read-only. A failed open or prepare names
    // itself rather than degrading to "no sessions"; nothing here throws or crashes.
    // `public static` so the test suite can exercise it against a fixture DB.
    public static func readRows(dbPath: String, sinceMS: Int64) -> ReadResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            return .unreadable("Could not open opencode.db — \(reason)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
            SELECT tokens_input, tokens_output, tokens_reasoning, time_updated, cost
            FROM session WHERE time_archived IS NULL AND time_updated >= ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .unreadable("Could not read opencode.db — \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sinceMS)

        var out: [OpenCodeLogic.Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(
                OpenCodeLogic.Row(
                    tokensInput: Int(sqlite3_column_int64(stmt, 0)),
                    tokensOutput: Int(sqlite3_column_int64(stmt, 1)),
                    tokensReasoning: Int(sqlite3_column_int64(stmt, 2)),
                    cost: sqlite3_column_double(stmt, 4),
                    timeUpdatedMS: sqlite3_column_int64(stmt, 3)))
        }
        return .rows(out)
    }
}
