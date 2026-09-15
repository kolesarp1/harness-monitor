import CoreServices
import Foundation

// One coalesced FSEvents stream over all watched roots, so the Engine ticks when files actually
// change instead of stat-polling every 400ms. Events are collected on a private queue into a
// lock-guarded dirty set; the Engine drains it each loop iteration (drain is cheap enough that the
// loop itself stays a trivial heartbeat when nothing changed). The 0.4s latency window batches a
// streaming session's appends into at most ~2 wakeups/s — the same freshness as the old poll, at
// zero cost when idle.
public final class FileWatcher: @unchecked Sendable {
    public let signals: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    // @unchecked: `dirtyRoots` is only touched under `lock`; `stream` is written on the main actor
    // (init/stop) and torn down via `queue.sync` in `stop()`, which drains any in-flight callback
    // before release (the callback holds no strong ref — passUnretained — so a UAF would otherwise
    // be possible on teardown; see `stop()`).
    private let lock = NSLock()
    private var dirtyRoots: Set<String> = []
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.mikeben.harness-widget.fsevents", qos: .utility)
    private let roots: [String]
    private var stopped = false

    // nil when the stream can't be created (e.g. a root on a dead volume) — callers degrade to polling.
    public init?(roots: [URL], latency: TimeInterval = 0.4) {
        var continuation: AsyncStream<Void>.Continuation!
        self.signals = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.signalContinuation = continuation
        // Resolve symlinks so the roots match FSEvents' kernel-canonical paths: FSEvents reports
        // e.g. /private/var/… where the watch root was /var/…, and `hasPrefix` would miss it. Home
        // dirs under /Users are symlink-free so this is a no-op there, but it keeps the prefix match
        // (and any /tmp- or /var-rooted test) honest rather than silently falling back to the heartbeat.
        self.roots = roots.map { $0.resolvingSymlinksInPath().path }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            // Without kFSEventStreamCreateFlagUseCFTypes the paths argument is a char** array.
            let cPaths = paths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
            var hit: [String] = []
            for i in 0..<count {
                if let p = cPaths[i] { hit.append(String(cString: p)) }
            }
            watcher.mark(paths: hit)
        }
        guard
            let s = FSEventStreamCreate(
                nil, callback, &context, self.roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func signal() { signalContinuation.yield(()) }

    // Which watched roots saw events since the last drain. Resets the set.
    public func drain() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let d = dirtyRoots
        dirtyRoots = []
        return d
    }

    private func mark(paths: [String]) {
        lock.lock()
        var changed = false
        for p in paths {
            for r in roots where p == r || p.hasPrefix(r + "/") {
                changed = dirtyRoots.insert(r).inserted || changed
            }
        }
        lock.unlock()
        if changed { signalContinuation.yield(()) }
    }

    public func stop() {
        lock.lock()
        let shouldFinish = !stopped
        stopped = true
        lock.unlock()
        if shouldFinish { signalContinuation.finish() }

        guard let s = stream else { return }
        stream = nil
        // Drain on the callback queue: after this returns no callback is executing or pending, so
        // releasing the stream can't race a callback that would dereference a deallocating `self`.
        // `deinit` can't run on `queue` (the callback holds no strong ref), so this never deadlocks.
        queue.sync {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    deinit { stop() }
}
