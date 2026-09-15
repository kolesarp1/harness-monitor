import Foundation

// Claude integration descriptor: everything intrinsic about Claude owned in its own folder. Usage comes
// from the OAuth endpoint, falling back to the local token estimate.
struct ClaudeDescriptor: IntegrationDescriptor {
    var displayName: String { "Claude" }
    var reportsTokens: Bool { true }
    var homeRelativePath: String { ".claude" }
    var brandSVG: String { BrandSVG.claude }
    var brandColor: BrandColor { .rgb(0xD9 / 255, 0x77 / 255, 0x57 / 255) }
    func planDisplayName(_ raw: String?) -> String? { ClaudeCredentials.planDisplayName(raw) }
    func makeMonitor(home: URL) -> any IntegrationMonitor {
        ClaudeMonitor(
            home: home, cacheDirectory: home.appendingPathComponent(".harness-usage/claude"),
            runSecurity: ClaudeCredentials.securityCLIReader())
    }
}
