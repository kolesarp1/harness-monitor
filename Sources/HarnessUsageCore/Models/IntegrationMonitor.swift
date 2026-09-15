import Foundation

// A usage-reporting integration monitor. Each integration provides its own conforming actor under
// `Integrations/<name>/`. The Engine holds a `[Integration: IntegrationMonitor]` and iterates it,
// with no integration-specific knowledge. Each monitor owns its own throttling and caching.
public protocol IntegrationMonitor: Sendable {
    // `wantUsageEstimate` mirrors the "show token estimate" setting: when false, a monitor may skip
    // any expensive work whose only purpose is that strip — today Claude's transcript scan and Codex's
    // walk of pi's session logs.
    // A monitor is only ever reloaded while its integration is detected. Each network-backed monitor
    // throttles its own requests internally.
    // nil means "no reading available right now".
    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot?

    // Directories whose file events mean this monitor has new data. The Engine watches them via
    // FSEvents and reloads the monitor only when one fires, plus a slow heartbeat.
    nonisolated var watchPaths: [URL] { get }

    // How often a monitor with no file to watch wants waking. Set only by network-backed monitors
    // (today: Cursor). nil plus empty `watchPaths` means "reload me every tick", which MockMonitor
    // relies on.
    nonisolated var pollInterval: TimeInterval? { get }

    // Drop this monitor's OWN refresh floors so the next `reload` does the work for real instead of
    // handing back what it read minutes ago. Asked for by "Update now"; nothing else calls it.
    // A backoff the server instructed (a 429's Retry-After) is deliberately left in place — that one
    // is not ours to waive, and a user pressing a menu item is not a reason to ignore it.
    func invalidateThrottles() async
}

extension IntegrationMonitor {
    public nonisolated var watchPaths: [URL] { [] }
    public nonisolated var pollInterval: TimeInterval? { nil }
    // A monitor that throttles nothing has nothing to drop.
    public func invalidateThrottles() async {}
}
