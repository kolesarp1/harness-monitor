import Foundation

// Brand color as Core-agnostic data: a fixed RGB tint, or "follow the text colour" (adaptive) for
// marks whose native #000 is invisible on dark glass. The app renders this to a SwiftUI `Color` in
// `BrandMark` — no per-integration knowledge on the UI side.
public enum BrandColor: Sendable, Equatable {
    case rgb(Double, Double, Double)  // 0...1 per channel
    case adaptive  // white or black, whichever the view's colour scheme calls for
}

// Everything intrinsic about one integration — identity, capabilities, branding data, and a factory
// for its monitor. Adding an agent means one descriptor in `Integrations/<name>/` plus one registry line,
// never a central switch.
public protocol IntegrationDescriptor: Sendable {
    var displayName: String { get }
    var reportsTokens: Bool { get }
    var homeRelativePath: String { get }  // probe marker dir, relative to ~
    var brandSVG: String { get }  // embedded brand mark (the app renders it to NSImage)
    var brandColor: BrandColor { get }  // tint for the mark
    func planDisplayName(_ raw: String?) -> String?
    func makeMonitor(home: URL) -> any IntegrationMonitor
}

extension IntegrationDescriptor {
    // Providers without a plan vocabulary still keep useful nonempty values rather than hiding them.
    public func planDisplayName(_ raw: String?) -> String? { fallbackPlanDisplayName(raw) }
}

// The single per-integration registry. Built over `Integration.allCases`, so it is always complete —
// `Integration.descriptor` relies on that invariant. Adding an agent = add a descriptor in
// `Integrations/<name>/` + one line here; the app changes nothing.
let integrationDescriptors: [Integration: any IntegrationDescriptor] = [
    .claude: ClaudeDescriptor(),
    .codex: CodexDescriptor(),
    .cursor: CursorDescriptor(),
    .opencode: OpenCodeDescriptor(),
]

extension Integration {
    // The descriptor for this integration. Force-unwrap is safe: the registry is built from
    // `Integration.allCases`, so every case has an entry.
    public var descriptor: any IntegrationDescriptor { integrationDescriptors[self]! }

    // One provider-owned display policy for newly read and already persisted plan values.
    public func planDisplayName(_ raw: String?) -> String? { descriptor.planDisplayName(raw) }
}
