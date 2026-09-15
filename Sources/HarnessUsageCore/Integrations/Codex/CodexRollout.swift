import Foundation

// Pure parsing for Codex CLI rollout transcripts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`):
// an append-only JSON-Lines stream of `{timestamp, type, payload}`. No IO here — `CodexMonitor` feeds
// these functions strings so each is deterministic and covered by the test suite. Tolerant of
// missing/renamed fields across CLI versions (key off `type`, accept either `resets_at` or `resets_in_seconds`).
public enum CodexRollout {
    // The 5h/weekly rate-limit windows from the tail's `token_count.rate_limits`. Null on free and
    // API-key plans, where only the cumulative token counts are available.
    public static func rateLimits(fromParsed objects: [[String: Any]], now: Date)
        -> (primary: UsageWindow?, secondary: UsageWindow?, expired: Bool)
    {
        // Which real window a slot holds is declared by `window_minutes`, NOT by its position: on a
        // weekly-only plan `primary` carries the 7-day window (10080) and `secondary` is null.
        // Mapping by position puts that weekly figure under the 5-hour meter and leaves the weekly
        // meter blank.
        //
        // Each slot keeps its own last-non-nil value. A tail interleaves blocks under different
        // `limit_id`s, and the `premium` one reports both slots null on plans without it — letting a
        // whole block overwrite would wipe real numbers an earlier block supplied, the same trap the
        // monitor already avoids across files.
        var session: UsageWindow?
        var week: UsageWindow?
        var sawRateLimits = false
        for o in objects {
            guard (o["type"] as? String) == "event_msg",
                let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count",
                let rl = p["rate_limits"] as? [String: Any]
            else { continue }
            for (index, slot) in [rl["primary"], rl["secondary"]].enumerated() {
                // A slot counts only when it is a window OBJECT. `JSONSerialization` decodes a JSON
                // `null` as `NSNull`, which is non-nil — so testing for nil made a `premium` block with
                // both slots null report "expired", and the monitor then overwrote a valid Pro meter
                // with nothing.
                if slot is [String: Any] { sawRateLimits = true }
                let weekly = isWeekly(slot, positionalDefault: index == 1)
                guard let w = window(slot, now: now, weekly: weekly) else { continue }
                if weekly { week = w } else { session = w }
            }
        }
        return (session, week, sawRateLimits && session == nil && week == nil)
    }

    // One day splits the two: Codex's observed `window_minutes` are 300 (the 5-hour window) and 10080
    // (the 7-day one), so anything under a day is the short rolling window. Older CLI builds omit the
    // field entirely — those fall back to the positional convention it replaced.
    private static func isWeekly(_ any: Any?, positionalDefault: Bool) -> Bool {
        guard let d = any as? [String: Any],
            let minutes = (d["window_minutes"] as? NSNumber)?.doubleValue
        else { return positionalDefault }
        return minutes >= 1440
    }

    // Split a tail Data block into lines on the raw newline byte, THEN decode each line — so a
    // multi-byte UTF-8 codepoint straddling the read boundary only drops its own (leading) partial
    // line, never the whole block (which `String(data:)` over the full slice would).
    public static func lines(fromTail data: Data) -> [String] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
    }

    // Parse a tail's lines into JSON objects once, so the extractors don't each re-parse every line.
    // Tolerant: invalid lines become `[:]`.
    public static func parseObjects(fromTail lines: [String]) -> [[String: Any]] {
        lines.compactMap { object($0) }
    }

    public static func totalTokens(fromParsed objects: [[String: Any]]) -> Int? {
        var total: Int?
        for o in objects {
            guard (o["type"] as? String) == "event_msg",
                let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count",
                let info = p["info"] as? [String: Any],
                let tot = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber
            else { continue }
            total = tot.intValue
        }
        return total
    }

    // Latest `token_count` cumulative breakdown → (input, cached, output). Codex's `input_tokens`
    // INCLUDES its cached portion (`cached_input_tokens` is a subset), so the cost path subtracts
    // `cached` and prices it on the cheaper cache-read lane. nil when the tail has no token_count.
    public static func tokenBreakdown(fromParsed objects: [[String: Any]])
        -> (input: Int, cached: Int, output: Int)?
    {
        var out: (Int, Int, Int)?
        for o in objects {
            guard (o["type"] as? String) == "event_msg",
                let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count",
                let info = p["info"] as? [String: Any],
                let tot = info["total_token_usage"] as? [String: Any]
            else { continue }
            let input = (tot["input_tokens"] as? NSNumber)?.intValue ?? 0
            let cached = (tot["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (tot["output_tokens"] as? NSNumber)?.intValue ?? 0
            out = (input, cached, output)
        }
        return out
    }

    // Latest cumulative `reasoning_output_tokens` from `total_token_usage` — reasoning is billed on the
    // output lane, so the cost path adds it to `output` (kept separate from `tokenBreakdown` so that
    // function's shape stays stable). 0 when the tail has no token_count.
    public static func reasoningOutput(fromParsed objects: [[String: Any]]) -> Int {
        var out = 0
        for o in objects {
            guard (o["type"] as? String) == "event_msg",
                let p = o["payload"] as? [String: Any], (p["type"] as? String) == "token_count",
                let info = p["info"] as? [String: Any],
                let tot = info["total_token_usage"] as? [String: Any],
                let r = (tot["reasoning_output_tokens"] as? NSNumber)?.intValue
            else { continue }
            out = r
        }
        return out
    }

    // A single rate-limit window: `used_percent` plus a reset given as either an absolute epoch
    // (`resets_at`) or a relative offset (`resets_in_seconds`).
    public static func window(_ any: Any?, now: Date, weekly: Bool) -> UsageWindow? {
        guard let d = any as? [String: Any],
            let pct = (d["used_percent"] as? NSNumber)?.doubleValue
        else { return nil }
        var resetsAt: Date?
        if let at = (d["resets_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: at)
        } else if let inSec = (d["resets_in_seconds"] as? NSNumber)?.doubleValue {
            resetsAt = now.addingTimeInterval(inSec)
        }
        let period = (d["window_minutes"] as? NSNumber).map { $0.doubleValue * 60 }
        return UsageMath.window(
            id: weekly ? "7d" : "5h", title: weekly ? "Weekly" : "Session", percent: pct,
            period: period, resetsAt: resetsAt, kind: .account, now: now)
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
