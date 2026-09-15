import Foundation
import SQLite3

// Reads Cursor's stored access token out of its VS Code-style key/value store. Read-only and silent:
// a Mac without Cursor installed (no file), a locked database, a missing table, or an empty value all
// return nil with no logging — that is the common case on a machine that only runs other agents.
//
// Only the SQLite source is implemented. openusage additionally falls back to the Keychain for a
// free-tier edge case; that branch would raise a system prompt this integration's toggle does not
// cover, so it is deliberately left out.
public enum CursorCredentials {
    static let accessTokenKey = "cursorAuth/accessToken"

    public static func dbPath(home: URL) -> String {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    }

    public static func accessToken(home: URL) -> String? {
        value(forKey: accessTokenKey, dbPath: dbPath(home: home))
    }

    // Mirrors OpenCodeMonitor.readRows: read-only open, a short busy timeout, and defer-finalize.
    // The key is BOUND, not interpolated, and the bind uses the transient destructor
    // (`unsafeBitCast(-1, ...)` == SQLITE_TRANSIENT) so SQLite copies the string — without it the
    // bound buffer is read after free.
    static func value(forKey key: String, dbPath: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { return nil }
        let token = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
