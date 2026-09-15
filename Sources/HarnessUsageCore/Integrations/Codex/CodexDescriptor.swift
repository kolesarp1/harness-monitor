import Foundation

// Codex integration descriptor. Usage is the live ChatGPT backend meter when the CLI's
// stored login is readable and unexpired, falling back to each CODEX_HOME's sessions/**/*.jsonl
// rollout tail (which supplies today's token counts and cost either way).
struct CodexDescriptor: IntegrationDescriptor {
    var displayName: String { "Codex" }
    var reportsTokens: Bool { true }
    var homeRelativePath: String { ".codex" }
    var brandSVG: String { BrandSVG.codex }
    var brandColor: BrandColor { .rgb(0x54 / 255, 0x66 / 255, 0xFF / 255) }
    func planDisplayName(_ raw: String?) -> String? { CodexAuth.planDisplayName(raw) }
    func makeMonitor(home: URL) -> any IntegrationMonitor { CodexProfilesMonitor(home: home) }
}
