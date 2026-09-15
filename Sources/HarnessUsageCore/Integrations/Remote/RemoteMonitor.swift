import Foundation

// The monitor for an account signed in on another machine.
//
// One tier only, and on purpose: the harness's own live meters, fetched by running the probe ON that
// machine. The local tiers have no remote equivalent worth the cost — a token estimate means reading
// a week of transcripts, which over ssh is minutes of IO for a number the account's own machine is
// better placed to report — so a remote ring shows percentages and reset times, which is what a
// limit tracker is for.
//
// Poll-driven at the same 300s floor the local live tiers use, with no watch paths: FSEvents cannot
// see another machine's disk, so the Engine's poll clock is the only thing that wakes this.
public actor RemoteMonitor: IntegrationMonitor {
    // The transport, as a function rather than a concrete `RemoteShell`, so a test drives every
    // failure path without an ssh binary, a network or a host that has to exist.
    private let run: @Sendable (String) async -> RemoteShell.Outcome
    private let probe: RemoteProbe
    private let alias: String
    private let now: @Sendable () -> Date
    private let floor: TimeInterval

    private var lastFetch: Date = .distantPast
    private var holdUntil: Date = .distantPast  // the endpoint's own 429 backoff, honoured remotely too
    private var cached: UsageSnapshot?
    private var note: String?

    public init(
        alias: String, probe: RemoteProbe,
        run: (@Sendable (String) async -> RemoteShell.Outcome)? = nil,
        floor: TimeInterval = 300, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let shell = RemoteShell(alias: alias)
        self.alias = alias
        self.probe = probe
        self.run = run ?? { await shell.run($0) }
        self.floor = floor
        self.now = now
    }

    // Nothing on this Mac changes when a remote account is used, so the Engine polls rather than
    // watches. The interval is the fetch floor: a tick that arrives early is a no-op anyway.
    public nonisolated var pollInterval: TimeInterval? { floor }

    public func invalidateThrottles() {
        lastFetch = .distantPast  // `holdUntil` stands — a 429 is the endpoint's instruction, not our floor
    }

    // `wantUsageEstimate` is ignored: there is no estimate tier here to gate.
    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        guard now() >= holdUntil, now().timeIntervalSince(lastFetch) >= floor else { return carried() }
        lastFetch = now()  // stamped before the call, so a failing host is not retried every tick

        switch await run(probe.script) {
        case .failed(let reason):
            note = reason
            return carried()
        case .ok(let output):
            return apply(RemoteResponse.parse(output))
        }
    }

    private func apply(_ response: RemoteResponse.Parsed) -> UsageSnapshot? {
        if let message = response.message {
            note = "\(alias): \(message)"
            return carried()
        }
        switch response.status {
        case 200:
            guard var snapshot = probe.parse(response.body, now()) else {
                note = "\(alias): the usage endpoint sent something unreadable"
                return carried()
            }
            snapshot.accountEmail = response.accountEmail ?? snapshot.accountEmail
            note = nil
            snapshot.note = nil
            cached = snapshot
            return snapshot
        case 401, 403:
            // The signed-in session on that box has lapsed. Keeping the last meters would show
            // percentages from an account we can no longer read, so they go with it.
            cached = nil
            note = "Signed out on \(alias) — log in again there"
            return carried()
        case 429:
            holdUntil = now().addingTimeInterval(floor)
            note = "\(alias) is rate-limiting; retrying later"
            return carried()
        case .some(let status):
            note = "\(alias): the usage endpoint answered \(status)"
            return carried()
        case nil:
            note = "\(alias): unexpected output from the remote host"
            return carried()
        }
    }

    // The last good reading, re-emitted with whatever note explains why it is not newer. A transient
    // outage keeps the meters on screen; a signed-out account has no meters left to carry and becomes
    // the note alone, so a ring never quotes a number the account no longer stands behind.
    private func carried() -> UsageSnapshot? {
        guard var snapshot = cached else {
            // No reading has ever landed, so there is nothing to date. `lastUpdated` is the note's
            // own time, not a reading's: the statement "we could not read this account" is itself
            // current, and stamping it `.distantPast` would print an age measured in decades.
            guard let note else { return nil }
            return UsageSnapshot(
                windows: [], localTokensToday: nil, localTokensWeek: nil,
                source: .remote, lastUpdated: now(), note: note)
        }
        snapshot.note = note
        return snapshot
    }
}
