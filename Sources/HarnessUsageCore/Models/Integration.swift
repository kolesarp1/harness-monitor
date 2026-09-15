import Foundation

// Which coding-agent program a usage reading came from. Each case gets its own folder under
// `Integrations/<name>/` holding its monitor + descriptor (identity, capabilities, branding).
// The computed properties below dispatch to that descriptor, so adding an agent = a case + a folder +
// one registry line — no central switch.
public enum Integration: String, Sendable, CaseIterable, Codable {
    case claude
    case codex
    case cursor
    case opencode

    // The integrations the app initializes, detects and shows. Cursor and opencode stay compiled
    // (enum cases, descriptors, parsers, stored settings) but suspended: uncomment to re-enable.
    // `allCases` remains the complete registry/persistence universe; this is the active subset.
    public static let supportedCases: [Integration] = [
        .claude,
        .codex,
        // .cursor,
        // .opencode,
    ]

    public var displayName: String { descriptor.displayName }

}
