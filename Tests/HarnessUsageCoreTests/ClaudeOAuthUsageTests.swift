import Foundation
import Testing

@testable import HarnessUsageCore

// The status → Outcome mapping is the one part of the fetch a pure parser test cannot reach, so this
// stubs the transport. One test owns the stub, so a single locked box is all the sharing it needs.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 200
    var code: Int {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
private let stubStatus = StatusBox()

private final class StatusStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: stubStatus.code, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// The `limits` array as this account's endpoint really returns it (captured live 2026-08-20): the
// account's own session and weekly caps restated unscoped, plus the model-scoped "Fable" cap — and
// note that the live payload marks the account session limit `is_active: true` and the Fable cap
// `is_active: false`, so that flag means "currently binding", not "exists".
//
// Defects: the unscoped entries leaking in as rows that duplicate Session and Weekly; gating on
// `is_active` and thereby dropping the one row worth adding; an already-reset promotional cap
// lingering; the percent or the reset date being read off the wrong key.
@Test func onlyTheModelScopedLimitsBecomeExtraRows() throws {
    let json = """
        {"five_hour": {"utilization": 43.0, "resets_at": "2026-08-20T14:19:59.679998+00:00"},
         "seven_day": {"utilization": 31.0, "resets_at": "2026-08-26T15:59:59.680017+00:00"},
         "limits": [
           {"kind": "session", "group": "session", "percent": 43,
            "resets_at": "2026-08-20T14:19:59.679998+00:00", "scope": null, "is_active": true},
           {"kind": "weekly_all", "group": "weekly", "percent": 31,
            "resets_at": "2026-08-26T15:59:59.680017+00:00", "scope": null, "is_active": false},
           {"kind": "weekly_scoped", "group": "weekly", "percent": 33,
            "resets_at": "2026-08-26T15:59:59.680214+00:00",
            "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false},
           {"kind": "weekly_scoped", "group": "weekly", "percent": 77,
            "resets_at": "2026-08-19T00:00:00+00:00",
            "scope": {"model": {"display_name": "Ember"}}, "is_active": true}
         ]}
        """
    let now = try #require(UsageParser.parseResetDate("2026-08-20T12:00:00Z"))

    let snap = try #require(ClaudeOAuthUsage.parse(Data(json.utf8), now: now))

    #expect(snap.windows.first { $0.id == "5h" }?.utilization == 43)
    #expect(snap.windows.first { $0.id == "7d" }?.utilization == 31)
    #expect(snap.windows.filter { !$0.kind.isAccount }.map(\.title) == ["Fable"])
    #expect(snap.windows.first { $0.id == "model:Fable" }?.utilization == 33)
    #expect(snap.windows.first { $0.id == "model:Fable" }?.resetsAt == UsageParser.parseResetDate("2026-08-26T15:59:59.680214+00:00"))
    // And the whole point of the array: the model cap is a row, in order, after the account windows.
    #expect(snap.windows.map(\.title) == ["Session", "Weekly", "Fable"])
}

// Defect: a 403 filed as `.failed` — that is the documented server-side block on third-party use of a
// consumer OAuth token, and `.failed` is retried every 300s for the rest of the run. `.unauthorized`
// is what makes the provider re-resolve once and then latch.
@Test func aServerSideBlockReadsAsUnauthorizedJustLikeAnExpiredToken() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StatusStub.self]
    let session = URLSession(configuration: config)
    let token = ClaudeCredentials.Token(accessToken: "tok", expiresAt: nil)
    let now = Date(timeIntervalSince1970: 1_755_600_000)

    for code in [401, 403] {
        stubStatus.code = code
        let outcome = await ClaudeOAuthUsage.fetch(token: token, session: session, now: now)
        guard case .unauthorized(let status) = outcome, status == code else {
            Issue.record("HTTP \(code) mapped to \(outcome), expected .unauthorized")
            continue
        }
    }

    // And the boundary holds: a server error is still a retryable failure, not a latch.
    stubStatus.code = 500
    let failure = await ClaudeOAuthUsage.fetch(token: token, session: session, now: now)
    guard case .failed = failure else {
        Issue.record("HTTP 500 mapped to \(failure), expected .failed")
        return
    }
}
