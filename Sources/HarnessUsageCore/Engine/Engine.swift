import Foundation

// The effect-free orchestrator. Owns the single tick loop and pumps the @Observable usage store on the
// main actor. No AppKit. Fully integration-agnostic: holds a `[Integration: IntegrationMonitor]` and
// iterates it. Detection is the only gate for a monitor.
@MainActor public final class Engine {
    private let monitors: [Integration: any IntegrationMonitor]
    public let integrations: IntegrationStore?
    public let accounts: SubscriptionAccountStore?
    public let usage: UsageStore
    public let settings: SettingsStore
    private let now: () -> Date

    private var lastDetect: Date = .distantPast
    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var signalContinuation: AsyncStream<Void>.Continuation?

    // Event-driven reload plumbing: FSEvents marks roots dirty; a tick reloads only the dirty
    // monitors and reuses the last snapshot for the rest. Monitors with neither watchPaths nor a
    // pollInterval (MockMonitor) are polled every tick, network-backed monitors follow their own
    // interval, and a slow heartbeat forces a full reload of the rest for the time-driven bits
    // (usage freshness windows, reset-time expiry).
    private var watcher: FileWatcher?
    private var rootMap: [(root: String, integration: Integration)] = []
    private var alwaysPolled: Set<Integration> = []
    private var pollDriven: Set<Integration> = []
    private var pollIntervals: [Integration: TimeInterval] = [:]
    private var lastReload: [Integration: Date] = [:]
    private var lastSnapshots: [Integration: [String?: UsageSnapshot]] = [:]
    private var lastHeartbeat: Date = .distantPast
    private var lastDetected: Set<Integration> = []
    private var explicitlyDue: Set<Integration> = []
    private var pendingDirty: Set<Integration> = []
    private var configuredInterval: UsageUpdateInterval
    private let heartbeatInterval: TimeInterval = 60

    public init(
        monitors: [Integration: any IntegrationMonitor],
        usage: UsageStore,
        settings: SettingsStore,
        integrations: IntegrationStore? = nil,
        accounts: SubscriptionAccountStore? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.monitors = monitors
        self.integrations = integrations
        self.accounts = accounts
        self.usage = usage
        self.settings = settings
        self.now = now
        self.configuredInterval = settings.settings.updateInterval
        settings.onUpdate = { [weak self] in self?.wake() }
        if let accounts {
            Task { [weak self] in
                await accounts.setUpdateHandler { [weak self] integration in
                    Task { @MainActor in
                        self?.explicitlyDue.insert(integration)
                        self?.wake()
                    }
                }
            }
        }
    }

    // Which integrations must reload this tick.
    //  - pollDue: poll-driven monitors whose own interval has elapsed.
    //  - dirty roots: accumulated into `pendingDirty`, then reloaded when the global cadence is due.
    //    The watcher's drain is destructive, so retaining the integration bit is mandatory.
    //  - heartbeat: additionally wake every detected monitor that is NOT poll-driven, for the
    //    time-driven bookkeeping (usage freshness, reset-time expiry).
    nonisolated static func dueIntegrations(
        dirtyRoots: Set<String>, rootMap: [(root: String, integration: Integration)],
        alwaysPolled: Set<Integration>, pollDriven: Set<Integration>, pollDue: Set<Integration>,
        heartbeat: Bool, detected: Set<Integration>
    ) -> Set<Integration> {
        var due = pollDue
        for (root, integration) in rootMap where dirtyRoots.contains(root) {
            due.insert(integration)
        }
        if heartbeat {
            due.formUnion(detected.subtracting(pollDriven))
        } else {
            due.formUnion(alwaysPolled.subtracting(pollDriven))
        }
        return due.intersection(detected)
    }

    nonisolated static func cadenceDecision(
        candidates: Set<Integration>, pendingDirty: Set<Integration>, newlyDirty: Set<Integration>,
        explicitlyDue: Set<Integration>, detected: Set<Integration>, lastReload: [Integration: Date],
        now: Date, interval: TimeInterval, bypassAppCadence: Bool
    ) -> (due: Set<Integration>, pendingDirty: Set<Integration>) {
        let retainedDirty = pendingDirty.union(newlyDirty).intersection(detected)
        let considered = candidates.union(retainedDirty).intersection(detected)
        var due =
            bypassAppCadence
            ? detected
            : Set(considered.filter { now.timeIntervalSince(lastReload[$0] ?? .distantPast) >= interval })
        due.formUnion(explicitlyDue.intersection(detected))
        return (due, retainedDirty.subtracting(due))
    }

    public func wake() {
        if let watcher {
            watcher.signal()
        } else {
            signalContinuation?.yield(())
        }
    }

    // One pass: collect usage work, apply the global cadence, reload eligible monitors, merge with
    // cached snapshots of the rest, and pump the store.
    // A tick with nothing due returns without touching the store at all — that is the idle steady state.
    public func tick(bypassAppCadence: Bool = false) async {
        let s = settings.settings

        if let integrations, now().timeIntervalSince(lastDetect) >= 30 {
            integrations.refresh()
            lastDetect = now()
        }

        let filesystemDetected = integrations?.detected ?? Set(monitors.keys)
        let accountAvailable = await accounts?.availableIntegrations() ?? []
        let detected = filesystemDetected.union(accountAvailable)
        let heartbeatDue = now().timeIntervalSince(lastHeartbeat) >= heartbeatInterval
        let intervalChanged = configuredInterval != s.updateInterval
        configuredInterval = s.updateInterval
        let pollDue = Set(
            pollDriven.filter { integration in
                guard let interval = pollIntervals[integration] else { return false }
                return now().timeIntervalSince(lastReload[integration] ?? .distantPast) >= interval
            })
        let dirtyRoots = watcher?.drain() ?? []
        let newlyDirty = Set(rootMap.compactMap { dirtyRoots.contains($0.root) ? $0.integration : nil })
        var candidates = Engine.dueIntegrations(
            dirtyRoots: [], rootMap: rootMap,
            alwaysPolled: alwaysPolled, pollDriven: pollDriven, pollDue: pollDue,
            heartbeat: heartbeatDue, detected: detected)
        candidates.formUnion(detected.subtracting(lastDetected))
        if intervalChanged { candidates.formUnion(detected) }
        let cadence = integrations == nil && accounts == nil ? 0 : s.updateInterval.seconds
        let decision = Engine.cadenceDecision(
            candidates: candidates, pendingDirty: pendingDirty, newlyDirty: newlyDirty,
            explicitlyDue: explicitlyDue, detected: detected, lastReload: lastReload,
            now: now(), interval: cadence, bypassAppCadence: bypassAppCadence)
        let due = decision.due
        // Clear before awaiting monitors. New dirtiness/account updates arriving during this tick remain.
        explicitlyDue.subtract(due)
        pendingDirty = decision.pendingDirty
        if heartbeatDue { lastHeartbeat = now() }
        lastSnapshots = lastSnapshots.filter { detected.contains($0.key) }
        if detected != lastDetected {
            lastDetected = detected
            publish(detected: detected)
        }
        if due.isEmpty { return }

        // Concurrent monitor reload: all due monitors do their IO on their own actors in parallel,
        // so the main actor stays free to handle UI (window dragging, rendering) while waiting.
        let results = await withTaskGroup(of: (Integration, IntegrationReloadResult).self) { group in
            for (integration, monitor) in monitors {
                guard due.contains(integration) else { continue }
                group.addTask(priority: .utility) {
                    let want = s.provider(for: integration).showTokenEstimate
                    let includeDetected = filesystemDetected.contains(integration)
                    guard PerfLog.enabled else {
                        return (
                            integration,
                            await monitor.reloadForEngine(
                                wantUsageEstimate: want, includeDetected: includeDetected,
                                policy: UsageReloadPolicy(
                                    interval: s.updateInterval,
                                    bypassAppCadence: bypassAppCadence))
                        )
                    }
                    let t0 = ContinuousClock.now
                    let r = await monitor.reloadForEngine(
                        wantUsageEstimate: want, includeDetected: includeDetected,
                        policy: UsageReloadPolicy(
                            interval: s.updateInterval,
                            bypassAppCadence: bypassAppCadence))
                    let ms = PerfLog.ms(ContinuousClock.now - t0)
                    if ms > 5 { PerfLog.log(String(format: "monitor %@ reload %.1fms", "\(integration)", ms)) }
                    return (integration, r)
                }
            }
            var collected: [(Integration, IntegrationReloadResult)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }
        let stamp = now()
        var supersededAny = false
        for (integration, result) in results {
            guard let monitor = monitors[integration] else { continue }
            switch await monitor.disposition(for: result) {
            case .accepted:
                lastReload[integration] = stamp
                lastSnapshots[integration] = result.readings
            case .superseded(let current):
                // Validation is the account result's publication linearization point. A mutation that
                // advanced the persisted generation before this check owns the provider now, so use
                // the store's current retained view and schedule fresh work instead of consuming the
                // stale in-flight result. Mutations after this point land on a later engine signal.
                lastSnapshots[integration] = current
                explicitlyDue.insert(integration)
                supersededAny = true
            case .validationFailed(let current):
                // A persistent lock/read failure is an attempted reload, not evidence of newer data.
                // Keep the marked retained view and its normal cadence; immediately waking here would
                // bypass cadence forever while the persistence problem remains.
                lastReload[integration] = stamp
                lastSnapshots[integration] = current
            }
        }
        if supersededAny { wake() }

        publish(detected: detected)
    }

    // Every detected harness's logins, one reading each, written only when something actually changed.
    private func publish(detected: Set<Integration>) {
        var readings: [UsageKey: UsageSnapshot] = [:]
        for integration in detected {
            for (profile, snapshot) in lastSnapshots[integration] ?? [:] {
                readings[UsageKey(integration, profile: profile)] = snapshot
            }
        }
        if readings != usage.readings { usage.readings = readings }
    }

    // "Update now": every detected monitor reads for real, right now.
    //
    // App cadence has separate engine and monitor gates; manual refresh bypasses both and invalidates
    // local scan floors, while server Retry-After holds remain authoritative. Detection runs first, so
    // a harness installed since the last 30s sweep gets its ring on the same press. Awaits the tick it
    // asks for, so a caller can hold a spinner up for exactly as long as the work takes.
    public func refreshNow() async {
        integrations?.refresh()
        lastDetect = now()
        let filesystemDetected = integrations?.detected ?? Set(monitors.keys)
        let detected = filesystemDetected.union(await accounts?.availableIntegrations() ?? [])
        await withTaskGroup(of: Void.self) { group in
            for (integration, monitor) in monitors where detected.contains(integration) {
                group.addTask(priority: .utility) { await monitor.invalidateThrottles() }
            }
        }
        await tick(bypassAppCadence: true)
    }

    public func start() {
        stop()
        var roots: [(url: URL, integration: Integration)] = []
        for (integration, monitor) in monitors {
            if let interval = monitor.pollInterval {
                pollDriven.insert(integration)
                pollIntervals[integration] = interval
            }
            let paths = monitor.watchPaths
            if paths.isEmpty {
                alwaysPolled.insert(integration)
            } else {
                roots += paths.map { (url: $0, integration: integration) }
            }
        }
        // Keys must match what FileWatcher stores (it resolves symlinks) so dirty-root lookup hits.
        rootMap = roots.map { (root: $0.url.resolvingSymlinksInPath().path, integration: $0.integration) }
        watcher = roots.isEmpty ? nil : FileWatcher(roots: roots.map { $0.url })
        if watcher == nil {
            // No stream (all-mock run, or FSEvents failed) — degrade to polling everything except the
            // poll-driven monitors, which keep their own clock. Without the subtraction a network
            // provider would fire on every 400ms tick.
            alwaysPolled = Set(monitors.keys)
        }
        alwaysPolled.subtract(pollDriven)
        let signals: AsyncStream<Void>
        if let watcher {
            signals = watcher.signals
        } else {
            var continuation: AsyncStream<Void>.Continuation!
            signals = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
            signalContinuation = continuation
        }
        wake()
        loopTask = Task { [weak self] in
            guard let self else { return }
            for await _ in signals {
                if Task.isCancelled { return }
                await self.tick()
            }
        }
        let heartbeat: Duration = watcher == nil ? .milliseconds(400) : .seconds(60)
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeat)
                guard !Task.isCancelled else { return }
                self?.wake()
            }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        signalContinuation?.finish()
        signalContinuation = nil
        loopTask?.cancel()
        loopTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    deinit {
        loopTask?.cancel()
        heartbeatTask?.cancel()
    }
}
