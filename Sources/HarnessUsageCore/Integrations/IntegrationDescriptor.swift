import Foundation

// Brand color as Core-agnostic data: a fixed RGB tint, or "follow the text colour" (adaptive) for
// marks whose native #000 is invisible on dark glass. The app renders this to a SwiftUI `Color` in
// `BrandMark` — no per-integration knowledge on the UI side.
public enum BrandColor: Sendable, Equatable {
    case rgb(Double, Double, Double)  // 0...1 per channel
    case adaptive  // white or black, whichever the view's colour scheme calls for
}

// Everything intrinsic about one harness — identity, capabilities, branding data, and a factory
// for one account's monitor. Adding an agent means one descriptor in `Integrations/<name>/` plus one
// registry line, never a central switch.
public protocol IntegrationDescriptor: Sendable {
    var displayName: String { get }
    var reportsTokens: Bool { get }
    var homeRelativePath: String { get }  // probe marker dir, relative to ~
    var brandSVG: String { get }  // embedded brand mark (the app renders it to NSImage)
    var brandColor: BrandColor { get }  // tint for the mark

    /// The monitor for ONE account. `home` is this Mac's home directory; `account` says which config
    /// directory to read and, for a remote account, which machine to read it on.
    func makeMonitor(home: URL, account: AccountConfig) -> any IntegrationMonitor

    /// The live-meter query for an account signed in on another machine, or nil when this harness has
    /// no credential-based endpoint to ask. Default: nil — a harness whose usage is purely local
    /// (opencode) has nothing a remote box could answer.
    func remoteProbe(configDir: String) -> RemoteProbe?
}

extension IntegrationDescriptor {
    public func remoteProbe(configDir: String) -> RemoteProbe? { nil }
}

// The single per-harness registry. Built over `Harness.allCases`, so it is always complete —
// `Harness.descriptor` relies on that invariant. Adding an agent = add a descriptor in
// `Integrations/<name>/` + one line here; the app changes nothing.
let integrationDescriptors: [Harness: any IntegrationDescriptor] = [
    .claude: ClaudeDescriptor(),
    .codex: CodexDescriptor(),
    .cursor: CursorDescriptor(),
    .opencode: OpenCodeDescriptor(),
]

extension Harness {
    // The descriptor for this harness. Force-unwrap is safe: the registry is built from
    // `Harness.allCases`, so every case has an entry.
    public var descriptor: any IntegrationDescriptor { integrationDescriptors[self]! }
}

extension Integration {
    /// The descriptor of this account's harness. Branding and capabilities belong to the program, not
    /// to the login, so every account of one harness shares them.
    public var descriptor: any IntegrationDescriptor { harness.descriptor }
    public var reportsTokens: Bool { descriptor.reportsTokens }
}

/// Builds the monitors for a list of accounts — the composition the app and `--dump` share.
public func makeMonitors(
    accounts: [AccountConfig], home: URL
) -> [Integration: any IntegrationMonitor] {
    Dictionary(
        uniqueKeysWithValues: accounts.map {
            ($0.integration, $0.harness.descriptor.makeMonitor(home: home, account: $0))
        })
}
