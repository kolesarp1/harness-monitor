import CryptoKit
import Foundation

public enum LocalUsageEstimator {
    // The scan runs every ~15s, so a directory that cannot be walked would repeat its line forever.
    private static let walkFailureUnreported = OnceFlag()

    // today/week are the cache-inclusive grand totals (back-compat). todayInput/todayOutput are the
    // raw input/output split for the fallback card. todayCostUSD is the approximate "≈ API value" for
    // today's entries, priced per-line off `message.model` via the bundled table.
    public struct Estimate: Equatable, Sendable {
        public var today: Int
        public var week: Int
        public var todayInput: Int
        public var todayOutput: Int
        public var todayCostUSD: Double

        public init(today: Int, week: Int, todayInput: Int, todayOutput: Int, todayCostUSD: Double) {
            self.today = today
            self.week = week
            self.todayInput = todayInput
            self.todayOutput = todayOutput
            self.todayCostUSD = todayCostUSD
        }
    }

    // One usage-bearing transcript line, parsed once and kept in the per-file cache. A nil `ts`
    // (unparseable timestamp) still claims its dedupe key during aggregation, mirroring the
    // line-by-line scan's check order.
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var ts: Date?
        public var input: Int
        public var output: Int
        public var cacheWrite: Int
        public var cacheRead: Int
        public var model: String
    }

    // Per-file incremental parse state. Transcripts are append-only, so `offset` (always a record
    // boundary) lets the next scan read only the appended bytes instead of re-parsing the whole
    // file; a size regression means the file was rewritten and forces a full re-parse.
    public struct FileState: Equatable, Sendable {
        public var offset: UInt64
        public var size: UInt64
        public var entries: [Entry]

        public init(offset: UInt64, size: UInt64, entries: [Entry]) {
            self.offset = offset
            self.size = size
            self.entries = entries
        }
    }

    public typealias Cache = [String: FileState]

    // The full scan outcome: the totals, the next cache, and the delta relative to the passed-in
    // cache — parsedPaths (files (re)read this scan) and removedPaths (files that left the window)
    // are exactly what the persistent index needs to write.
    public struct ScanResult: Sendable {
        public var estimate: Estimate
        public var cache: Cache
        public var parsedPaths: [String]
        public var removedPaths: [String]
    }

    // `previous` + `previousDay` power the no-op skip: when nothing was parsed or removed and the
    // day hasn't rolled over (the week boundary can only move with the day), the previous totals
    // are returned without re-aggregating the ~30k cached entries.
    public static func scan(
        projectsDir: URL, now: Date, cache: Cache, previous: Estimate?, previousDay: Date?
    ) -> ScanResult {
        let fm = FileManager.default
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = UsageMath.mostRecentMonday(onOrBefore: now, calendar: cal)
        guard
            let walker = fm.enumerator(
                at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else {
            // The walk FAILED — an absent or unreadable projects directory — which is not the same
            // answer as a walk that found no transcripts. Reporting every cached path as removed hands
            // `UsageIndex.apply` a delete for the whole persisted index, throwing away a scan that costs
            // seconds to re-derive over what is usually transient. Keep the cache, remove nothing, and
            // carry today's totals so the strip doesn't blink to zero.
            if walkFailureUnreported.claim() {
                FileHandle.standardError.write(
                    Data("HarnessUsage: cannot walk \(projectsDir.path) — Claude token estimate paused\n".utf8))
            }
            return ScanResult(
                estimate: (previousDay == startOfToday ? previous : nil)
                    ?? Estimate(today: 0, week: 0, todayInput: 0, todayOutput: 0, todayCostUSD: 0),
                cache: cache, parsedPaths: [], removedPaths: [])
        }

        // Files absent from this walk (deleted, or aged past the week boundary) drop out of the
        // rebuilt cache; their entries can no longer count, so keeping them would only hold memory.
        var next: Cache = [:]
        var ordered: [[Entry]] = []  // walk order, so cross-file dedupe stays deterministic
        let t0 = ContinuousClock.now
        var parsedPaths: [String] = []
        var newBytes: UInt64 = 0

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // Transcripts are append-only, so a file last modified before the week boundary holds no
            // in-window entries — skip it without reading (avoids re-parsing all history).
            if let mtime = rv?.contentModificationDate, mtime < startOfWeek { continue }
            let path = url.path
            let state: FileState
            if let prior = cache[path], let sz = (rv?.fileSize).map(UInt64.init),
                sz == prior.size, prior.offset == prior.size
            {
                state = prior  // fully parsed and unchanged — reuse without opening
            } else {
                state = parseFile(atPath: path, prior: cache[path])
                parsedPaths.append(path)
                newBytes += state.offset - min(cache[path]?.offset ?? 0, state.offset)
            }
            next[path] = state
            ordered.append(state.entries)
        }
        let removedPaths = cache.keys.filter { next[$0] == nil }
        if PerfLog.enabled {
            let entries = next.values.reduce(0) { $0 + $1.entries.count }
            PerfLog.log(
                String(
                    format: "usage estimate: %.0fms, reused %d, parsed %d (+%.1fMB), entries %d",
                    PerfLog.ms(ContinuousClock.now - t0), next.count - parsedPaths.count,
                    parsedPaths.count, Double(newBytes) / 1e6, entries))
        }
        let est: Estimate
        if parsedPaths.isEmpty, removedPaths.isEmpty, let previous, previousDay == startOfToday {
            est = previous  // nothing changed and the boundaries haven't moved — totals are still valid
        } else {
            est = aggregate(ordered, startOfToday: startOfToday, startOfWeek: startOfWeek)
        }
        return ScanResult(estimate: est, cache: next, parsedPaths: parsedPaths, removedPaths: removedPaths)
    }

    // Pure fold over the per-file entries in walk order — dedupe across files (the same assistant
    // turn appears across resumes/sidechains), then bucket by the day/week boundaries. A zero-token
    // or timestamp-less entry still claims its key before being skipped.
    public static func aggregate(_ files: [[Entry]], startOfToday: Date, startOfWeek: Date) -> Estimate {
        var seen = Set<String>()
        var est = Estimate(today: 0, week: 0, todayInput: 0, todayOutput: 0, todayCostUSD: 0)
        for entries in files {
            for e in entries {
                if seen.contains(e.key) { continue }
                seen.insert(e.key)
                let tokens = e.input + e.output + e.cacheWrite + e.cacheRead
                if tokens == 0 { continue }
                guard let ts = e.ts else { continue }
                if ts >= startOfWeek { est.week += tokens }
                if ts >= startOfToday {
                    est.today += tokens
                    est.todayInput += e.input
                    est.todayOutput += e.output
                    est.todayCostUSD += ModelPricing.claudeCost(
                        model: e.model, input: e.input, output: e.output,
                        cacheWrite: e.cacheWrite, cacheRead: e.cacheRead)
                }
            }
        }
        return est
    }

    // Reads only the bytes past `prior.offset` in bounded chunks — never the whole file at once
    // (a week of 1M-context transcripts runs to hundreds of MB; whole-file loads spiked the app's
    // footprint toward a GB). A prior offset beyond the current size means the file was rewritten:
    // start over.
    static func parseFile(atPath path: String, prior: FileState?) -> FileState {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return prior ?? FileState(offset: 0, size: 0, entries: [])
        }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var offset: UInt64 = 0
        var entries: [Entry] = []
        if let prior, prior.offset <= size {
            offset = prior.offset
            entries = prior.entries
        }
        guard offset < size, (try? fh.seek(toOffset: offset)) != nil else {
            return FileState(offset: offset, size: size, entries: entries)
        }

        var buf = Data()
        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            buf.append(chunk)
            for line in drainCompleteLines(&buf) {
                offset += UInt64(line.count) + 1  // + the newline
                if let e = parseEntry(fromLine: line, path: path) { entries.append(e) }
            }
        }
        // A final line without a trailing newline is consumed only when it is a complete record
        // (valid JSON) — a torn in-flight append stays unconsumed so the next scan retries it from
        // the same offset instead of losing it or double-counting it.
        if !buf.isEmpty, (try? JSONSerialization.jsonObject(with: buf)) != nil {
            if let e = parseEntry(fromLine: buf, path: path) { entries.append(e) }
            offset += UInt64(buf.count)
        }
        return FileState(offset: offset, size: size, entries: entries)
    }

    // Splits every complete (newline-terminated) line off the front of `buf`, leaving the torn tail
    // in place for the next chunk. Returned lines exclude the newline; they are slices, valid until
    // the caller appends to `buf`. The survivor is rebuilt with subdata so its indices restart at
    // zero — Data slices keep their parent's indices, the classic Data footgun.
    public static func drainCompleteLines(_ buf: inout Data) -> [Data] {
        var lines: [Data] = []
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            lines.append(buf[start..<nl])
            start = nl + 1
        }
        if start != buf.startIndex {
            buf = buf.subdata(in: start..<buf.endIndex)
        }
        return lines
    }

    // The `"usage"` byte-scan is a fast path: only usage-bearing lines pay for JSON parsing. The
    // dedupe key is message.id + requestId; when both are absent (older transcript format) it falls
    // back to the file path plus a digest of the line, so each entry counts exactly once.
    static func parseEntry(fromLine line: Data, path: String) -> Entry? {
        guard !line.isEmpty, line.range(of: usageMarker) != nil,
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let message = obj["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else { return nil }
        let id = (message["id"] as? String) ?? ""
        let req = (obj["requestId"] as? String) ?? ""
        let key: String
        if !id.isEmpty || !req.isEmpty {
            key = id + "|" + req
        } else {
            key = path + "#" + digest(line)
        }
        return Entry(
            key: key,
            ts: (obj["timestamp"] as? String).flatMap(UsageParser.parseResetDate),
            input: intToken(usage, "input_tokens"),
            output: intToken(usage, "output_tokens"),
            cacheWrite: intToken(usage, "cache_creation_input_tokens"),
            cacheRead: intToken(usage, "cache_read_input_tokens"),
            model: (message["model"] as? String) ?? "")
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    // A fixed-width stand-in for the line itself. The key is persisted verbatim in
    // `usage-index.sqlite` for every id-less entry, and a 1M-context transcript line runs to hundreds
    // of KB — keying on the raw text stored a second copy of the transcripts in the cache meant to
    // make them cheap. SHA-256 keeps "same line, same key", which is all the dedupe needs, in 64 bytes.
    private static func digest(_ line: Data) -> String {
        SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
    }

    private static func intToken(_ usage: [String: Any], _ key: String) -> Int {
        (usage[key] as? NSNumber)?.intValue ?? 0
    }

}

// A one-shot claim, so a condition that recurs every scan reports itself exactly once per process.
// `NSLock` rather than an actor: the estimator is a nonisolated static called from actor isolation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
