import Foundation
import SQLite3
import Testing

@testable import HarnessUsageCore

private func entry(_ key: String) -> LocalUsageEstimator.Entry {
    LocalUsageEstimator.Entry(
        key: key, ts: nil, input: 1, output: 2, cacheWrite: 3, cacheRead: 4, model: "sonnet")
}

private func state(_ keys: [String], size: UInt64) -> LocalUsageEstimator.FileState {
    LocalUsageEstimator.FileState(offset: size, size: size, entries: keys.map(entry))
}

private func temporaryIndex() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("usage-index-\(UUID().uuidString)/usage-index.sqlite").path
}

@Test func appendingEntriesDoesNotDuplicateThePersistedPrefix() {
    let path = temporaryIndex()
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    let file = "/projects/session.jsonl"

    UsageIndex.apply(at: path, parsed: [(file, state(["a", "b", "c"], size: 3))], removed: [])
    UsageIndex.apply(at: path, parsed: [(file, state(["a", "b", "c", "d", "e"], size: 5))], removed: [])

    let loaded = UsageIndex.load(at: path)
    #expect(loaded[file]?.entries.map(\.key) == ["a", "b", "c", "d", "e"])
}

@Test func aShrinkingRewriteReplacesTheOldFile() {
    let path = temporaryIndex()
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    let file = "/projects/session.jsonl"

    UsageIndex.apply(at: path, parsed: [(file, state(["a", "b", "c"], size: 30))], removed: [])
    UsageIndex.apply(at: path, parsed: [(file, state(["new-a", "new-b"], size: 2))], removed: [])

    #expect(UsageIndex.load(at: path)[file]?.entries.map(\.key) == ["new-a", "new-b"])
}

@Test func aSequenceGapForcesAFullRebuild() {
    let path = temporaryIndex()
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    let file = "/projects/session.jsonl"

    UsageIndex.apply(at: path, parsed: [(file, state(["a", "b", "c"], size: 3))], removed: [])
    var db: OpaquePointer?
    #expect(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "UPDATE entries SET seq = 9 WHERE file = '/projects/session.jsonl' AND seq = 1", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    db = nil

    UsageIndex.apply(at: path, parsed: [(file, state(["a", "b", "c", "d"], size: 4))], removed: [])
    #expect(UsageIndex.load(at: path)[file]?.entries.map(\.key) == ["a", "b", "c", "d"])
}
