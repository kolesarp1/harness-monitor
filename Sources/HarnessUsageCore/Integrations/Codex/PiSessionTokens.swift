import Foundation

// Token usage for Codex models driven through the pi harness. The Codex CLI writes rollout files only
// for its own sessions; usage that flows through pi (the `openai-codex` provider) lands in pi's own
// session logs instead — `~/.pi/agent/sessions/<project>/*.jsonl`, one `usage` object per assistant
// message (`{"type":"message","message":{"role":"assistant","provider":"openai-codex",...,
// "usage":{"input":..,"output":..,"cacheRead":..,"cacheWrite":..,"reasoning":..,"totalTokens":..}}}`).
// Without this source the Codex "today tokens" lane is blind to harness-driven usage entirely.
//
// Read-only, like every usage source here. Files are parsed once per mtime; each cached file keeps a
// per-local-day sum table, so a midnight rollover re-aggregates without re-parsing and stale days
// simply stop being selected.
struct PiDaySums: Equatable {
    var input = 0  // fresh input + cache writes
    var cached = 0  // cache reads (subset of the display input convention is applied by the merger)
    var output = 0  // output + reasoning (reasoning folds into the output lane, same as rollouts)
    var total = 0  // totalTokens as pi reports it (includes cache)
}

enum PiSessionTokens {
    // The pi provider id whose messages burn the ChatGPT/Codex plan cap.
    static let codexProvider = "openai-codex"

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // One session file → per-day sums of its openai-codex assistant messages. Empty when the file holds
    // none, which is the ordinary case: the caller caches that result, so a log full of other providers'
    // messages is read once per change rather than once per scan.
    static func parseFile(_ url: URL, calendar: Calendar) -> [String: PiDaySums] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? h.close() }
        let raw = (try? h.readToEnd())?.split(separator: 10) ?? []

        var days: [String: PiDaySums] = [:]
        for line in raw {
            // Cheap substring gate before any JSON work: most lines in a session log are tool calls
            // and user text with no provider field at all.
            let text = String(decoding: line, as: UTF8.self)
            guard text.contains(Self.codexProvider),
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                object["type"] as? String == "message",
                let message = object["message"] as? [String: Any],
                message["role"] as? String == "assistant",
                message["provider"] as? String == Self.codexProvider,
                let usage = message["usage"] as? [String: Any],
                let timestamp = object["timestamp"] as? String,
                let date = Self.parse(timestamp)
            else { continue }

            func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            var sums = days[Self.dayKey(for: date, calendar: calendar)] ?? PiDaySums()
            sums.input += int("input") + int("cacheWrite")
            sums.cached += int("cacheRead")
            sums.output += int("output") + int("reasoning")
            sums.total += int("totalTokens")
            days[Self.dayKey(for: date, calendar: calendar)] = sums
        }
        return days
    }

    static func parse(_ string: String) -> Date? {
        if let d = isoFractional.date(from: string) { return d }
        return isoWhole.date(from: string)
    }

    // Immutable after creation and only read by `date(from:)`, which is thread-safe — safe to share.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoWhole = ISO8601DateFormatter()
}
