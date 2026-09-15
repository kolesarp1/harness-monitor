import Foundation
import SQLite3

// Persists LocalUsageEstimator's per-file parse cache (offsets + entries) across launches, so the
// full-week transcript scan happens once per install instead of once per launch — the scan was
// 4.6s / ~350MB of JSONL on a heavy week, paid on every start while the index only lived in memory.
// Storage is SQLite via the system library (same posture as the opencode monitor): ~2-3MB for a
// heavy week, atomic per-refresh delta writes, and only appended entries are inserted.
public enum UsageIndex {
    // Bump when the schema or Entry semantics change: a mismatched index is dropped wholesale and
    // rebuilt by the next scan (it is a cache of re-derivable data, never the source of truth).
    static let version: Int32 = 1

    // MARK: - Load

    public static func load(at path: String) -> LocalUsageEstimator.Cache {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        guard userVersion(db) == version else { return [:] }

        var cache: LocalUsageEstimator.Cache = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, size, offset FROM files", -1, &stmt, nil) == SQLITE_OK
        else { return [:] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0) else { continue }
            cache[String(cString: p)] = LocalUsageEstimator.FileState(
                offset: UInt64(sqlite3_column_int64(stmt, 2)),
                size: UInt64(sqlite3_column_int64(stmt, 1)),
                entries: [])
        }
        sqlite3_finalize(stmt)

        // seq preserves per-file parse order — aggregation's first-wins dedupe depends on it.
        let sql = """
            SELECT file, key, ts, input, output, cache_write, cache_read, model
            FROM entries ORDER BY file, seq
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let f = sqlite3_column_text(stmt, 0), let k = sqlite3_column_text(stmt, 1),
                let m = sqlite3_column_text(stmt, 7)
            else { continue }
            let file = String(cString: f)
            guard cache[file] != nil else { continue }  // orphaned rows from an interrupted write
            let ts: Date? =
                sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            cache[file]?.entries.append(
                LocalUsageEstimator.Entry(
                    key: String(cString: k), ts: ts,
                    input: Int(sqlite3_column_int64(stmt, 3)),
                    output: Int(sqlite3_column_int64(stmt, 4)),
                    cacheWrite: Int(sqlite3_column_int64(stmt, 5)),
                    cacheRead: Int(sqlite3_column_int64(stmt, 6)),
                    model: String(cString: m)))
        }
        return cache
    }

    // MARK: - Delta write

    // One transaction per refresh: remove deleted files and append only the entries beyond the
    // persisted prefix. A rewritten or inconsistent file falls back to a full replacement.
    public static func apply(
        at path: String,
        parsed: [(path: String, state: LocalUsageEstimator.FileState)],
        removed: [String]
    ) {
        guard !parsed.isEmpty || !removed.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        ensureSchema(db)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }

        for file in removed {
            run(db, "DELETE FROM entries WHERE file = ?1", [file])
            run(db, "DELETE FROM files WHERE path = ?1", [file])
        }

        var insert: OpaquePointer?
        let insertSQL = """
            INSERT INTO entries(file, seq, key, ts, input, output, cache_write, cache_read, model)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insert, nil) == SQLITE_OK, let insert else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(insert) }

        for (file, state) in parsed {
            let fileInfo = persistedFile(db, path: file)
            let entriesInfo = persistedEntries(db, path: file)
            let persistedCount = entriesInfo.count
            let canAppend =
                fileInfo != nil
                && entriesInfo.nextSeq == Int64(persistedCount)
                && state.entries.count >= persistedCount
                && state.size >= UInt64(fileInfo?.size ?? 0)
            let start = canAppend ? persistedCount : 0
            if !canAppend { run(db, "DELETE FROM entries WHERE file = ?1", [file]) }

            if !insertEntries(insert, file: file, entries: state.entries, from: start) {
                // A collision means the prefix proof was false. Rebuild this file once rather than
                // silently losing the row, then abort the transaction if the rebuild also fails.
                run(db, "DELETE FROM entries WHERE file = ?1", [file])
                guard insertEntries(insert, file: file, entries: state.entries, from: 0) else {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    return
                }
            }
            run(
                db, "INSERT OR REPLACE INTO files(path, size, offset) VALUES(?1, ?2, ?3)",
                [file, Int64(state.size), Int64(state.offset)])
        }

        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    // MARK: - Internals

    private static func ensureSchema(_ db: OpaquePointer?) {
        if userVersion(db) != version {
            sqlite3_exec(db, "DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS entries", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
        }
        let schema = """
            CREATE TABLE IF NOT EXISTS files(
              path TEXT PRIMARY KEY, size INTEGER NOT NULL, offset INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS entries(
              file TEXT NOT NULL, seq INTEGER NOT NULL, key TEXT NOT NULL, ts REAL,
              input INTEGER NOT NULL, output INTEGER NOT NULL,
              cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL, model TEXT NOT NULL,
              PRIMARY KEY(file, seq));
            """
        sqlite3_exec(db, schema, nil, nil, nil)
    }

    private static func userVersion(_ db: OpaquePointer?) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    private static func persistedFile(_ db: OpaquePointer?, path: String) -> (size: Int64, offset: Int64)? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT size, offset FROM files WHERE path = ?1", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
    }

    private static func persistedEntries(_ db: OpaquePointer?, path: String) -> (nextSeq: Int64, count: Int) {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT COALESCE(MAX(seq), -1) + 1, COUNT(*) FROM entries WHERE file = ?1", -1, &stmt, nil) == SQLITE_OK
        else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int64(stmt, 1)))
    }

    private static func insertEntries(
        _ stmt: OpaquePointer?, file: String, entries: [LocalUsageEstimator.Entry], from start: Int
    ) -> Bool {
        guard start <= entries.count else { return false }
        for (seq, e) in entries.enumerated().dropFirst(start) {
            sqlite3_reset(stmt)
            bindText(stmt, 1, file)
            sqlite3_bind_int64(stmt, 2, Int64(seq))
            bindText(stmt, 3, e.key)
            if let ts = e.ts {
                sqlite3_bind_double(stmt, 4, ts.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int64(stmt, 5, Int64(e.input))
            sqlite3_bind_int64(stmt, 6, Int64(e.output))
            sqlite3_bind_int64(stmt, 7, Int64(e.cacheWrite))
            sqlite3_bind_int64(stmt, 8, Int64(e.cacheRead))
            bindText(stmt, 9, e.model)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    // Tiny helper for one-shot statements with TEXT/INT64 params (enough for this schema).
    private static func run(_ db: OpaquePointer?, _ sql: String, _ params: [Any]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            switch p {
            case let s as String: bindText(stmt, Int32(i + 1), s)
            case let n as Int64: sqlite3_bind_int64(stmt, Int32(i + 1), n)
            default: assertionFailure("UsageIndex.run: unbound param type \(type(of: p)) → NULL")
            }
        }
        sqlite3_step(stmt)
    }

    // SQLITE_TRANSIENT forces SQLite to copy the string before the Swift buffer is released.
    private static func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
