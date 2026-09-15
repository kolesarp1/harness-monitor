import Foundation

// The Cursor integration: the monthly billing-cycle meter from Cursor's dashboard RPC, using the
// access token Cursor already stores on this Mac. The app's only purely network-backed provider —
// there is no file to watch, so it declares a `pollInterval` instead and the engine wakes it on that
// clock rather than every 400ms tick.
//
// Detection is the gate to fetch. The engine's poll clock gates the calls today, but the floor below
// is enforced HERE as well, so the guarantee "at most one request to api2.cursor.sh every 300s" is the
// monitor's own and cannot be undone by a future caller that reloads it out of band.
public actor CursorMonitor: IntegrationMonitor {
    private let home: URL
    private let now: @Sendable () -> Date
    private let urlSession: URLSession
    private var cached: UsageSnapshot?  // last good reading, so a transient failure doesn't blank the widget
    private var holdUntil: Date = .distantPast  // 429 backoff
    private var lastAttempt: Date = .distantPast  // stamped on every attempt, successes and failures alike

    private static let refreshFloor: TimeInterval = 300

    public init(
        home: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        urlSession: URLSession? = nil
    ) {
        self.home = home
        self.now = now
        self.urlSession = urlSession ?? UsageEndpoint.makeSession(requestTimeout: 10)
    }

    // No file to watch: `state.vscdb` changes on Cursor's schedule, not on usage events, and the
    // dashboard figure only moves when Cursor's server recomputes it.
    public nonisolated var pollInterval: TimeInterval? { Self.refreshFloor }

    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        guard now() >= holdUntil else { return cached }
        // Inside the floor, hand back the last reading unchanged — no request, no note churn.
        guard now().timeIntervalSince(lastAttempt) >= Self.refreshFloor else { return cached }
        // Stamped before the credential read, not just before the request: reading the token opens
        // Cursor's `state.vscdb`, so a Mac with no Cursor login would otherwise pay that SQLite open on
        // every reload forever. A failure throttles the retry the same way a success does.
        lastAttempt = now()
        guard let token = CursorCredentials.accessToken(home: home) else {
            return note("No Cursor login token found on this Mac")
        }
        switch await CursorUsageClient.fetch(token: token, session: urlSession, now: now()) {
        case .ok(let snapshot):
            cached = snapshot
            return snapshot
        case .empty:
            return note("Cursor billing cycle ended — waiting for the next cycle")
        case .unauthorized:
            return noteDroppingMeters("Cursor login token expired or rejected")
        case .rateLimited(let retryAfter):
            holdUntil = retryAfter ?? now().addingTimeInterval(Self.refreshFloor)
            return note("Cursor is rate-limiting; retrying later")
        case .failed:
            return note("Could not reach the Cursor usage endpoint")
        }
    }

    // `holdUntil` is left alone: that one is Cursor's own 429 backoff, not our floor.
    public func invalidateThrottles() {
        lastAttempt = .distantPast
    }

    nonisolated static func noteSnapshot(cached: UsageSnapshot?, reason: String, now: Date) -> UsageSnapshot? {
        guard var snapshot = cached else {
            return UsageSnapshot(
                windows: [], localTokensToday: nil, localTokensWeek: nil,
                source: .cursorDashboard, lastUpdated: now, note: reason)
        }
        snapshot.note = reason
        return snapshot
    }

    // Keep the last good meter on screen and say why it is not moving, rather than blanking the card.
    private func note(_ reason: String) -> UsageSnapshot? {
        let snapshot = Self.noteSnapshot(cached: cached, reason: reason, now: now())
        cached = snapshot
        return snapshot
    }

    // Say why AND drop the meters. The rule Codex and Claude already apply when a login is refused: a
    // percentage read minutes ago describes an account this app can no longer read, and presenting it
    // as current is worse than presenting nothing.
    private func noteDroppingMeters(_ reason: String) -> UsageSnapshot? {
        cached = nil
        return note(reason)
    }
}
