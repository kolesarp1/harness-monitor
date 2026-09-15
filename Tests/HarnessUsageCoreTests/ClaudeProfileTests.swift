import Foundation
import Testing

@testable import HarnessUsageCore

// Defect: a Keychain name that is not the one Claude Code writes, so every second account reads as
// signed out while its token sits in the Keychain. The digest is pinned from `shasum -a 256` over the
// path, not recomputed by the code under test.
@Test func aProfileFolderReadsTheKeychainItemClaudeCodeNamesAfterIt() {
    let home = URL(fileURLWithPath: "/Users/test")
    #expect(ClaudeProfile.named("work", home: home).keychainServices.first == "Claude Code-credentials-03abf0ee")
    #expect(ClaudeProfile.standard(home: home).keychainServices == ["Claude Code-credentials"])
}

// Defect: a scratch config folder with no login getting a ring that can only ever say "no login", or a
// signed-in folder being missed.
@Test func discoveryListsTheDefaultFolderThenOnlySignedInProfilesByName() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("hu-profiles-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let states = [
        "work": #"{"oauthAccount": {"accountUuid": "acct-w"}}"#,
        "alpha": #"{"oauthAccount": {"accountUuid": "acct-a"}}"#,
        "review": #"{"numStartups": 3}"#,
    ]
    for (name, state) in states {
        let profile = ClaudeProfile.named(name, home: home)
        try fm.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        try Data(state.utf8).write(to: profile.stateFile)
    }

    #expect(ClaudeProfile.discover(home: home).map(\.name) == [nil, "alpha", "work"])
}

// Defect: a known tier reaching every surface as an internal code, or losing its Max multiplier.
@Test func thePlanLabelUsesClaudeNamesAndPreservesUnknownValues() {
    #expect(ClaudeCredentials.planLabel(tier: "Default_claude_max_20x", organizationType: "claude_max") == "Max 20x")
    #expect(ClaudeCredentials.planLabel(tier: "DEFAULT_CLAUDE_MAX_5X", organizationType: nil) == "Max 5x")
    #expect(ClaudeCredentials.planLabel(tier: nil, organizationType: "claude_pro") == "Pro")
    #expect(ClaudeCredentials.planLabel(tier: "default_claude_team_5x", organizationType: nil) == "Team")
    #expect(ClaudeCredentials.planLabel(tier: "default_raven", organizationType: "api_individual") == "Default_raven")
}
