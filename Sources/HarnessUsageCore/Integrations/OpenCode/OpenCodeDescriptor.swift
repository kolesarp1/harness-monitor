import Foundation

// opencode integration descriptor: passive — reads ~/.local/share/opencode/opencode.db (SQLite)
// directly. Reports usage (per-session token columns, auth-free, no plan limit).
struct OpenCodeDescriptor: IntegrationDescriptor {
    var displayName: String { "OpenCode" }
    var reportsTokens: Bool { true }
    var homeRelativePath: String { ".local/share/opencode" }
    var brandSVG: String { BrandSVG.opencode }
    var brandColor: BrandColor { .adaptive }
    // opencode's usage is read straight out of its SQLite db and involves no login at all, so there
    // is no per-account credential to point a second entry at.
    func makeMonitor(home: URL, account: AccountConfig) -> any IntegrationMonitor {
        OpenCodeMonitor(home: home)
    }
}
