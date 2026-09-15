import Foundation

// The effect-free orchestrator. Owns the single tick loop and pumps the @Observable usage store on the
// main actor. No AppKit. Fully integration-agnostic: holds a `[Integration: IntegrationMonitor]` and
// iterates it. Detection is the only gate for a monitor.
@MainActor public final class Engine {
    private var monitors: [Integration: any IntegrationMonitor]
    public let integrations: IntegrationStore?
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
    private var lastSnapshots: [Integration: UsageSnapshot] = [:]
    private var lastHeartbeat: Date = .distantPast
    private var lastDetected: Set<Integration> = []
    private let heartbeatInterval: TimeInterval = 60

    public init(
        monitors: [Integration: any IntegrationMonitor],
        usage: UsageStore,
        settings: SettingsStore,
        integrations: IntegrationStore? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.monitors = monitors
        self.integrations = integrations
        self.usage = usage
        self.settings = settings
        self.now = now
        settings.onUpdate = { [weak self] in self?.wake() }
    }

    // Which integrations must reload this tick.
    //  - pollDue: poll-driven monitors whose own interval has elapsed.
    //  - dirty roots: always honoured, on every tick. The watcher's drain is destructive, so an event
    //    that arrives on a heartbeat tick must still be acted on here or it is gone.
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

    public func wake() {
        if let watcher {
            watcher.signal()
        } else {
            signalContinuation?.yield(())
        }
    }

    // One pass: refresh usage from the due monitors (event-dirty + always-polled + poll-interval
    // elapsed, or all on the heartbeat), merge with the cached snapshots of the rest, pump the store.
    // A tick with nothing due returns without touching the store at all — that is the idle steady state.
    public func tick() async {
        let s = settings.settings

        if let integrations, now().timeIntervalSince(lastDetect) >= 30 {
            integrations.refresh()
            lastDetect = now()
        }

        let detected = integrations?.detected ?? Set(monitors.keys)
        let heartbeatDue = now().timeIntervalSince(lastHeartbeat) >= heartbeatInterval
        let pollDue = Set(
            pollDriven.filter { integration in
                guard let interval = pollIntervals[integration] else { return false }
                return now().timeIntervalSince(lastReload[integration] ?? .distantPast) >= interval
            })
        let due = Engine.dueIntegrations(
            dirtyRoots: watcher?.drain() ?? [], rootMap: rootMap,
            alwaysPolled: alwaysPolled, pollDriven: pollDriven, pollDue: pollDue,
            heartbeat: heartbeatDue, detected: detected)
        if heartbeatDue { lastHeartbeat = now() }
        lastSnapshots = lastSnapshots.filter { detected.contains($0.key) }
        if detected != lastDetected {
            lastDetected = detected
            let usageMap = lastSnapshots.filter { detected.contains($0.key) }
            if usageMap != usage.byIntegration { usage.byIntegration = usageMap }
        }
        if due.isEmpty { return }

        // Concurrent monitor reload: all due monitors do their IO on their own actors in parallel,
        // so the main actor stays free to handle UI (window dragging, rendering) while waiting.
        let results = await withTaskGroup(of: (Integration, UsageSnapshot?).self) { group in
            for (integration, monitor) in monitors {
                guard due.contains(integration) else { continue }
                group.addTask(priority: .utility) {
                    guard PerfLog.enabled else {
                        return (integration, await monitor.reload(wantUsageEstimate: s.provider(for: integration).showTokenEstimate))
                    }
                    let t0 = ContinuousClock.now
                    let r = await monitor.reload(wantUsageEstimate: s.provider(for: integration).showTokenEstimate)
                    let ms = PerfLog.ms(ContinuousClock.now - t0)
                    if ms > 5 { PerfLog.log(String(format: "monitor %@ reload %.1fms", "\(integration)", ms)) }
                    return (integration, r)
                }
            }
            var collected: [(Integration, UsageSnapshot?)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }
        let stamp = now()
        for (integration, snapshot) in results {
            lastReload[integration] = stamp
            lastSnapshots[integration] = snapshot
        }

        var usageMap: [Integration: UsageSnapshot] = [:]
        for integration in detected {
            if let snapshot = lastSnapshots[integration] { usageMap[integration] = snapshot }
        }

        if usageMap != usage.byIntegration { usage.byIntegration = usageMap }
    }

    // "Update now": every detected monitor reads for real, right now.
    //
    // Three separate throttles stand between a press and a fresh number, and this drops all of them —
    // each monitor's own refresh floor, the engine's per-monitor poll clock, and the heartbeat that
    // decides which monitors a tick even asks. Detection runs first, so a harness installed since the
    // last 30s sweep gets its ring on the same press. Awaits the tick it asks for, so a caller can
    // hold a spinner up for exactly as long as the work takes.
    public func refreshNow() async {
        integrations?.refresh()
        lastDetect = now()
        let detected = integrations?.detected ?? Set(monitors.keys)
        await withTaskGroup(of: Void.self) { group in
            for (integration, monitor) in monitors where detected.contains(integration) {
                group.addTask(priority: .utility) { await monitor.invalidateThrottles() }
            }
        }
        lastReload = [:]
        lastHeartbeat = .distantPast
        await tick()
    }

    /// Swap one account's monitor after its Settings source changes. The integration identity stays
    /// the same, so rings and provider preferences remain intact; only the place its data is read
    /// from changes. Rebuilding the watcher/poll schedule makes the replacement live immediately.
    public func replaceMonitor(_ monitor: any IntegrationMonitor, for integration: Integration) async {
        stop()
        monitors[integration] = monitor
        lastReload.removeValue(forKey: integration)
        lastSnapshots.removeValue(forKey: integration)
        usage.byIntegration.removeValue(forKey: integration)
        pollDriven = []
        pollIntervals = [:]
        alwaysPolled = []
        rootMap = []
        start()
        await refreshNow()
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
