import Foundation

// Cursor integration descriptor: passive. Usage is the monthly billing cycle from Cursor's
// dashboard RPC, fetched with the token Cursor already stores on this Mac whenever Cursor is present.
struct CursorDescriptor: IntegrationDescriptor {
    var displayName: String { "Cursor" }
    var reportsTokens: Bool { false }
    // The App Support dir, not ~/.cursor: that is where the token lives, and a Cursor install whose
    // CLI was never used may have no ~/.cursor at all — which would leave usage readable but the
    // integration undetected.
    var homeRelativePath: String { "Library/Application Support/Cursor" }
    var brandSVG: String { BrandSVG.cursor }
    var brandColor: BrandColor { .adaptive }  // native #000 is invisible on dark glass → adaptive label
    // Cursor keeps one login per Mac, in a fixed App Support location it does not let a config
    // directory move. A second Cursor account is therefore a second machine, and `account.configDir`
    // has nothing to point at — so this reads the one login, whichever account names it.
    func makeMonitor(home: URL, account: AccountConfig) -> any IntegrationMonitor {
        CursorMonitor(home: home)
    }
}
