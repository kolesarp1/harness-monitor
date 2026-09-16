import Foundation

public struct UsageReloadPolicy: Sendable, Equatable {
    public let interval: UsageUpdateInterval
    public let bypassAppCadence: Bool

    public init(interval: UsageUpdateInterval, bypassAppCadence: Bool = false) {
        self.interval = interval
        self.bypassAppCadence = bypassAppCadence
    }
}

// Account-backed monitor results carry an internal disk generation to the Engine boundary. Other
// integrations use the public readings-only initializer and require no acceptance work.
struct AccountReloadValidationToken: Sendable, Equatable {
    let integration: Integration
    let generation: UInt64?
}

public struct IntegrationReloadResult: Sendable {
    public let readings: [String?: UsageSnapshot]
    let accountValidationToken: AccountReloadValidationToken?

    public init(readings: [String?: UsageSnapshot]) {
        self.readings = readings
        self.accountValidationToken = nil
    }

    init(
        readings: [String?: UsageSnapshot],
        accountValidationToken: AccountReloadValidationToken
    ) {
        self.readings = readings
        self.accountValidationToken = accountValidationToken
    }
}

public enum IntegrationReloadDisposition: Sendable {
    case accepted
    case superseded(current: [String?: UsageSnapshot])
    case validationFailed(current: [String?: UsageSnapshot])
}

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

    // Every login this monitor reads, keyed by profile name, with nil for the default login. Most
    // harnesses keep one login per Mac, so the default answers `reload` under nil; Claude and Codex
    // answer once per config folder signed in to an account. This is what the Engine calls.
    func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot]

    // The Engine supplies filesystem detection separately from account availability. Account-wrapped
    // monitors use this to avoid probing nonexistent local credentials for an app-only account.
    func reloadProfiles(wantUsageEstimate: Bool, includeDetected: Bool) async -> [String?: UsageSnapshot]

    func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot]

    // Engine-only acceptance boundary. Account wrappers attach their persisted detection generation
    // to the result and validate it immediately before consumption. Ordinary monitors use the default
    // readings-only result and are always accepted.
    func reloadForEngine(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> IntegrationReloadResult
    func disposition(for result: IntegrationReloadResult) async -> IntegrationReloadDisposition

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

    // Server-directed account backoff learned by another credential source. A provider monitor uses
    // this to keep an owned connection's 429 from being evaded through a matching detected token.
    func applyAccountBackoffs(_ holds: [String: Date]) async
    func accountBackoffs() async -> [String: Date]
}

extension IntegrationMonitor {
    public func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot] {
        guard let snapshot = await reload(wantUsageEstimate: wantUsageEstimate) else { return [:] }
        let defaultLogin: String? = nil
        return [defaultLogin: snapshot]
    }

    public func reloadProfiles(wantUsageEstimate: Bool, includeDetected: Bool) async -> [String?: UsageSnapshot] {
        guard includeDetected else { return [:] }
        return await reloadProfiles(wantUsageEstimate: wantUsageEstimate)
    }

    public func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        await reloadProfiles(wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected)
    }

    public func reloadForEngine(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> IntegrationReloadResult {
        IntegrationReloadResult(
            readings: await reloadProfiles(
                wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
                policy: policy))
    }

    public func disposition(for result: IntegrationReloadResult) async -> IntegrationReloadDisposition {
        .accepted
    }

    public nonisolated var watchPaths: [URL] { [] }
    public nonisolated var pollInterval: TimeInterval? { nil }
    // A monitor that throttles nothing has nothing to drop.
    public func invalidateThrottles() async {}
    public func applyAccountBackoffs(_ holds: [String: Date]) async {}
    public func accountBackoffs() async -> [String: Date] { [:] }
}
