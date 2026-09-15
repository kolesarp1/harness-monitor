import Foundation

// opencode integration descriptor: passive — reads ~/.local/share/opencode/opencode.db (SQLite)
// directly. Reports usage (per-session token columns, auth-free, no plan limit).
struct OpenCodeDescriptor: IntegrationDescriptor {
    var displayName: String { "OpenCode" }
    var reportsTokens: Bool { true }
    var homeRelativePath: String { ".local/share/opencode" }
    var brandSVG: String { BrandSVG.opencode }
    var brandColor: BrandColor { .adaptive }
    func makeMonitor(home: URL) -> any IntegrationMonitor { OpenCodeMonitor(home: home) }
}
