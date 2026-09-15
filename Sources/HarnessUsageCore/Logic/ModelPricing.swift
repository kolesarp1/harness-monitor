import Foundation

// A tiny bundled per-model USD price table (list-price-equivalent, in dollars per MILLION tokens).
// Used to turn the token splits we already parse into an approximate cost — the "≈ API value" the
// Usage widget shows, never "spent" (a flat-fee Max/Pro subscriber doesn't pay list price). No config
// surface: a plain lookup keyed off the model id each agent stamps on its own transcripts. Pricing
// receipt: Anthropic's public API pricing, checked 2026-08-20. Opus 4.5+ is $5/$25, not the legacy
// $15/$75.
public enum ModelPricing {
    public struct Rate: Equatable, Sendable {
        public var input: Double  // per 1M input tokens
        public var output: Double  // per 1M output tokens
        public var cacheWrite: Double  // per 1M cache-creation tokens
        public var cacheRead: Double  // per 1M cache-read tokens
        public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
        }
    }

    // Claude cost from one message's token split. Cache tokens are billed on their own lanes
    // (write ~1.25× input, read ~0.1× input). Unknown/empty model → Sonnet-tier default.
    public static func claudeCost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        let r = claudeRate(model)
        return usd(input, r.input) + usd(output, r.output) + usd(cacheWrite, r.cacheWrite)
            + usd(cacheRead, r.cacheRead)
    }

    // Codex/OpenAI cost. Codex's `input_tokens` INCLUDES its cached subset, so the non-cached
    // remainder is priced on the input lane and the cached portion on the cheaper cache-read lane
    // (OpenAI has no cache-write fee). `output` should already fold in reasoning tokens.
    public static func codexCost(input: Int, cached: Int, output: Int) -> Double {
        let r = codexRate()
        let fresh = max(0, input - cached)
        return usd(fresh, r.input) + usd(cached, r.cacheRead) + usd(output, r.output)
    }

    public static func claudeRate(_ model: String) -> Rate {
        let m = model.lowercased()
        if m.contains("opus") {
            // Opus 4.5 and later are $5/$25; older Opus is $15/$75. Parse the version so date
            // stamps such as `claude-opus-4-20250514` do not look like a minor version.
            if let (major, minor) = opusVersion(m), major > 4 || (major == 4 && minor >= 5) {
                return Rate(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)
            }
            return Rate(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        }
        if m.contains("haiku") {
            return Rate(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)
        }
        return Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)  // sonnet + default
    }

    public static func codexRate() -> Rate {
        // The gpt-5 / gpt-5-codex family: $1.25 in / $10 out / $0.125 cache-read; no cache-write fee.
        Rate(input: 1.25, output: 10, cacheWrite: 0, cacheRead: 0.125)
    }

    private static func opusVersion(_ model: String) -> (Int, Int)? {
        if model.contains("claude-3-opus") { return (3, 0) }
        guard let range = model.range(of: "opus-") else { return nil }
        let parts = model[range.upperBound...].split(separator: "-")
        guard let major = Int(parts.first ?? "") else { return nil }
        let minorText = parts.dropFirst().first.map(String.init) ?? ""
        let minor = minorText.count <= 2 ? (Int(minorText) ?? 0) : 0
        return (major, minor)
    }

    private static func usd(_ tokens: Int, _ perMillion: Double) -> Double {
        Double(tokens) / 1_000_000 * perMillion
    }
}
