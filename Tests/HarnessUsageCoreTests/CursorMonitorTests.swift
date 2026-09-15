import Foundation
import SQLite3
import Testing

@testable import HarnessUsageCore

private let now = Date(timeIntervalSince1970: 1_755_600_000)

private func endedCycleBody() -> Data {
    Data(
        """
        {"planUsage": {"totalPercentUsed": 42},
         "billingCycleEnd": \(Int(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000))}
        """.utf8)
}

// Serves one canned dashboard body. Only this file's session config lists it, so it cannot intercept
// another test's traffic. `status`/`body` are set before the monitor is built and read after.
private final class CursorStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureError: Error { let message: String }

// The one `ItemTable` row `CursorCredentials` reads, in a real `state.vscdb` at the path it probes.
private func writeCursorToken(_ token: String, home: URL) throws {
    let path = CursorCredentials.dbPath(home: home)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw FixtureError(message: "could not create \(path)")
    }
    defer { sqlite3_close(db) }
    let sql = """
        CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable VALUES ('\(CursorCredentials.accessTokenKey)', '\(token)');
        """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw FixtureError(message: "could not seed ItemTable")
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Test func expiredCursorBillingCycleProducesNoSnapshot() {
    #expect(CursorUsageLogic.reading(from: endedCycleBody(), now: now) == .nothingToReport)
}

// Serialized: both tests configure the one URLProtocol stub, and Swift Testing runs tests in parallel.
@Suite(.serialized) struct CursorDashboardResponses {
    private func monitor(home: URL, now: @escaping @Sendable () -> Date) -> CursorMonitor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorStub.self]
        return CursorMonitor(home: home, now: now, urlSession: URLSession(configuration: config))
    }

    // Defect: a 200 that parsed but had nothing to meter (usage disabled, no `planUsage`, or a cycle
    // that has ended) was filed as `.failed`, so the Settings row blamed the network for a working
    // endpoint and the cycle-ended branch below it could never be reached.
    @Test func anEndedBillingCycleReadsAsTheCycleNoteNotANetworkFailure() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCursorToken("tok-a", home: home)
        CursorStub.status = 200
        CursorStub.body = endedCycleBody()

        let snapshot = try #require(await monitor(home: home, now: { now }).reload(wantUsageEstimate: false))
        #expect(snapshot.note == "Cursor billing cycle ended — waiting for the next cycle")
        #expect(snapshot.windows.isEmpty)
    }

    // Defect: `.unauthorized` kept the cached meter on screen, so a login Cursor has already refused
    // went on quoting a percentage from an account this app can no longer read. Codex and Claude drop.
    @Test func aRefusedCursorLoginDropsTheMetersItCanNoLongerRefresh() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCursorToken("tok-a", home: home)
        let clock = Clock(now)
        CursorStub.status = 200
        CursorStub.body = Data(
            """
            {"planUsage": {"totalPercentUsed": 42},
             "billingCycleEnd": \(Int(now.addingTimeInterval(86_400).timeIntervalSince1970 * 1000))}
            """.utf8)
        let monitor = monitor(home: home, now: { clock.now })

        let good = try #require(await monitor.reload(wantUsageEstimate: false))
        #expect(good.windows.first { $0.id == "cycle" }?.utilization == 42)

        CursorStub.status = 401
        clock.advance(400)
        let refused = try #require(await monitor.reload(wantUsageEstimate: false))
        #expect(refused.note == "Cursor login token expired or rejected")
        #expect(refused.windows.isEmpty)
    }
}

@Test func noteSnapshotCarriesTheReasonWithOrWithoutCachedUsage() throws {
    let cached = UsageSnapshot(
        windows: [
            UsageWindow(
                id: "cycle", title: "Monthly", utilization: 42, period: 30 * 86_400,
                resetsAt: now.addingTimeInterval(60), kind: .account)
        ],
        localTokensToday: nil, localTokensWeek: nil, source: .cursorDashboard, lastUpdated: now)
    let held = try #require(CursorMonitor.noteSnapshot(cached: cached, reason: "retry later", now: now))
    #expect(held.windows.first { $0.id == "cycle" }?.utilization == 42)
    #expect(held.note == "retry later")

    let first = try #require(CursorMonitor.noteSnapshot(cached: nil, reason: "retry later", now: now))
    #expect(first.note == "retry later")
}

@Test func cursorHoldoffReturnsTheStoredReason() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let monitor = CursorMonitor(home: home, now: { now })

    let first = try #require(await monitor.reload(wantUsageEstimate: false))
    let second = try #require(await monitor.reload(wantUsageEstimate: false))
    #expect(first.note == "No Cursor login token found on this Mac")
    #expect(second.note == first.note)
}
