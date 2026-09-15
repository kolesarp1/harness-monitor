import Foundation

// Which coding-agent PROGRAM a usage reading came from. Each case gets its own folder under
// `Integrations/<name>/` holding its monitor + descriptor (identity, capabilities, branding).
// Adding an agent = a case + a folder + one registry line — no central switch.
//
// A harness is not what the app draws a ring for; an ACCOUNT is (see `Integration` below). One
// harness can be signed into several accounts at once, each in its own config directory, and on
// several machines.
public enum Harness: String, Sendable, CaseIterable, Hashable, Codable {
    case claude
    case codex
    case cursor
    case opencode

    public var displayName: String { descriptor.displayName }
}

// One tracked ACCOUNT of one harness — the app's unit of identity, and what a ring, a settings pane,
// a monitor and a usage snapshot are each keyed by.
//
// It stays named `Integration` because that is what every surface already calls the thing it draws
// one of: the ordering, the per-provider settings and the selection logic were all written per-ring,
// and reading "ring" as "account" rather than "harness" leaves them correct as they stand.
//
// `account` is a stable slug, empty for the machine's default login (`~/.claude`, `~/.codex`). That
// emptiness is load-bearing for persistence: `Integration.claude.rawValue` is still `"claude"`, so
// every settings key written before accounts existed still resolves to the default account.
public struct Integration: Hashable, Sendable, RawRepresentable, Codable {
    public let harness: Harness
    public let account: String

    // `#` separates the two halves. It cannot appear in a harness case, and `AccountConfig` rejects it
    // in a slug, so `rawValue` round-trips unambiguously.
    private static let separator: Character = "#"

    public init(harness: Harness, account: String = "") {
        self.harness = harness
        self.account = account
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard let harness = Harness(rawValue: String(parts[0])) else { return nil }
        let account = parts.count > 1 ? String(parts[1]) : ""
        // `"claude#"` is not a spelling of `"claude"` — a trailing separator means a corrupt key, and
        // silently folding it into the default account would merge two rings' settings into one.
        guard parts.count == 1 || !account.isEmpty else { return nil }
        self.init(harness: harness, account: account)
    }

    public var rawValue: String {
        account.isEmpty ? harness.rawValue : "\(harness.rawValue)\(Self.separator)\(account)"
    }

    public var isDefaultAccount: Bool { account.isEmpty }

    // The default account of each harness — the shape the app had before accounts existed, and what
    // the seeded `accounts.json` starts from.
    public static let claude = Integration(harness: .claude)
    public static let codex = Integration(harness: .codex)
    public static let cursor = Integration(harness: .cursor)
    public static let opencode = Integration(harness: .opencode)

    // The harness's own name, with no account on it — what the brand mark stands for.
    public var harnessName: String { harness.displayName }

    // What the user reads: "Claude" for a lone account, "Claude · Work" once a harness has more than
    // one. The label comes from the account registry, never from the slug, so renaming an account in
    // `accounts.json` does not change this key and cannot orphan its settings.
    public var displayName: String {
        let label = Accounts.label(for: self)
        return label.isEmpty ? harnessName : "\(harnessName) · \(label)"
    }
}
