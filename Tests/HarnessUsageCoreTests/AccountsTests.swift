import Foundation
import Testing

@testable import HarnessUsageCore

// MARK: - Integration identity

// The persistence contract: a default account's key is still the bare harness name, so every
// settings key written before accounts existed keeps resolving to the same ring.
@Test func defaultAccountKeepsItsPreAccountsKey() {
    #expect(Integration.claude.rawValue == "claude")
    #expect(Integration(rawValue: "claude") == .claude)
    #expect(Integration.claude.isDefaultAccount)
}

@Test func namedAccountRoundTripsThroughItsKey() {
    let work = Integration(harness: .claude, account: "work")
    #expect(work.rawValue == "claude#work")
    #expect(Integration(rawValue: "claude#work") == work)
    #expect(work != .claude)
    #expect(!work.isDefaultAccount)
}

// A trailing separator is a corrupt key, not another spelling of the default account: folding it in
// would merge two rings' stored settings into one.
@Test func malformedKeysAreRejectedRatherThanFolded() {
    #expect(Integration(rawValue: "claude#") == nil)
    #expect(Integration(rawValue: "nosuchharness") == nil)
    #expect(Integration(rawValue: "nosuchharness#work") == nil)
    #expect(Integration(rawValue: "") == nil)
}

@Test func anAccountKeepsItsHarnessBranding() {
    let work = Integration(harness: .claude, account: "work")
    #expect(work.harnessName == "Claude")
    #expect(work.reportsTokens == Integration.claude.reportsTokens)
}

// MARK: - Labels

// A lone account reads as just "Claude" however the file labels it — a single-account install must
// look exactly as it did before accounts existed.
@Test func aSingleAccountShowsNoLabel() {
    let accounts = [AccountConfig(harness: .claude, label: "Personal")]
    #expect(Accounts.label(for: .claude, in: accounts) == "")
}

@Test func labelsAppearOnceAHarnessHasTwoAccounts() {
    let accounts = [
        AccountConfig(harness: .claude, label: "Personal"),
        AccountConfig(harness: .claude, account: "work", label: "Work"),
        AccountConfig(harness: .codex, label: "Personal"),
    ]
    #expect(Accounts.label(for: .claude, in: accounts) == "Personal")
    #expect(Accounts.label(for: Integration(harness: .claude, account: "work"), in: accounts) == "Work")
    // Codex still has one account, so it stays unlabeled even though the file names it.
    #expect(Accounts.label(for: .codex, in: accounts) == "")
}

// MARK: - Paths

@Test func configDirDefaultsToTheHarnessOwnDirectory() {
    let home = URL(fileURLWithPath: "/Users/x")
    #expect(AccountConfig(harness: .claude).resolvedConfigDir(home: home) == "/Users/x/.claude")
    #expect(AccountConfig(harness: .codex).resolvedConfigDir(home: home) == "/Users/x/.codex")
}

@Test func tildeExpandsAgainstTheGivenHome() {
    let home = URL(fileURLWithPath: "/Users/x")
    let account = AccountConfig(harness: .claude, account: "work", configDir: "~/.claude-work")
    #expect(account.resolvedConfigDir(home: home) == "/Users/x/.claude-work")
}

// A remote account's `~` belongs to the REMOTE login, so it is left for the remote shell to expand —
// substituting this Mac's home would point the probe at a path that does not exist over there.
@Test func remoteTildeIsLeftForTheRemoteShell() {
    let account = AccountConfig(
        harness: .claude, account: "work", host: .ssh("box"), configDir: "~/.claude-a")
    #expect(account.resolvedConfigDir(home: nil) == "~/.claude-a")
}

// Two logins of one harness must not share a usage cache or a parse index.
@Test func eachAccountGetsItsOwnCacheDirectory() {
    #expect(AccountConfig(harness: .claude).cacheDirName == "claude")
    #expect(AccountConfig(harness: .claude, account: "work").cacheDirName == "claude-work")
}

// MARK: - accounts.json

private func parse(_ json: String) -> [AccountConfig]? {
    AccountsFile.parse(Data(json.utf8))
}

@Test func aFullEntryParses() {
    let accounts = parse(
        """
        { "accounts": [
          { "harness": "claude", "label": "Personal" },
          { "harness": "claude", "account": "work", "label": "Work",
            "host": "sunny-new", "configDir": "~/.claude-a" }
        ] }
        """)
    #expect(accounts?.count == 2)
    #expect(accounts?[0].host == .local)
    #expect(accounts?[0].account == "")
    #expect(accounts?[1].host == .ssh("sunny-new"))
    #expect(accounts?[1].configDir == "~/.claude-a")
    #expect(accounts?[1].integration.rawValue == "claude#work")
}

@Test func anOperationalSlotCanUseAnotherAccountsLoginProfile() throws {
    let accounts = parse(
        """
        { "accounts": [
          { "harness": "claude", "label": "Personal", "configDir": "~/.claude-personal" },
          { "harness": "claude", "account": "work", "label": "Work",
            "configDir": "~/.claude-work", "usageSource": "" }
        ] }
        """)!
    let work = try #require(accounts.last)
    let source = work.source(in: accounts)
    #expect(source.integration == .claude)
    #expect(source.configDir == "~/.claude-personal")
    // The Work login remains independently configured, so the assignment can later be swapped back.
    #expect(work.configDir == "~/.claude-work")
}

@Test func invalidOperationalAssignmentFallsBackToTheSlotsOwnLogin() {
    var warnings: [String] = []
    let accounts = AccountsFile.parse(
        Data(#"{ "accounts": [{ "harness": "codex", "account": "a", "usageSource": "missing" }] }"#.utf8),
        warn: { warnings.append($0) })!
    #expect(accounts[0].usageSource == nil)
    #expect(accounts[0].source(in: accounts).integration == accounts[0].integration)
    #expect(warnings.contains { $0.contains("unknown usage source") })
}

// One bad entry must not take its siblings with it — the file is a list of independent accounts.
@Test func oneBadEntryIsDroppedAndTheRestSurvive() {
    let accounts = parse(
        """
        { "accounts": [
          { "harness": "claude" },
          { "harness": "nosuchtool" },
          { "harness": "codex", "account": "has spaces" },
          { "harness": "codex", "account": "work" }
        ] }
        """)
    #expect(accounts?.map(\.integration.rawValue) == ["claude", "codex#work"])
}

// A repeated key would put two rings under one identity, which is not a state SwiftUI has an answer
// for — the same rule `providerOrder` applies on the way in.
@Test func duplicateAccountsAreDropped() {
    let accounts = parse(
        """
        { "accounts": [
          { "harness": "claude", "label": "First" },
          { "harness": "claude", "label": "Second" }
        ] }
        """)
    #expect(accounts?.count == 1)
    #expect(accounts?[0].label == "First")
}

// nil, not an empty list: the caller falls back to the default accounts, because an app with no
// rings at all is worse than an app ignoring a broken file.
@Test func anUnusableFileFallsBackRatherThanEmptying() {
    #expect(parse("not json at all") == nil)
    #expect(parse("{ }") == nil)
    #expect(parse(#"{ "accounts": [] }"#) == nil)
    #expect(parse(#"{ "accounts": [ { "harness": "nope" } ] }"#) == nil)
}

// The alias reaches an `ssh` argument list, so anything that is not a host name is refused rather
// than handed to the shell — `-o` first among them.
@Test func hostilesSSHAliasesAreRefused() {
    #expect(AccountsFile.isValidSSHAlias("sunny-new"))
    #expect(AccountsFile.isValidSSHAlias("box.example.com"))
    #expect(!AccountsFile.isValidSSHAlias("-oProxyCommand=touch /tmp/pwned"))
    #expect(!AccountsFile.isValidSSHAlias("box; rm -rf /"))
    #expect(!AccountsFile.isValidSSHAlias("box name"))
    #expect(!AccountsFile.isValidSSHAlias("$(whoami)"))
    #expect(!AccountsFile.isValidSSHAlias(""))
}

@Test func aSlugMustBeSafeForAKeyAndAPath() {
    #expect(AccountConfig.isValidSlug("work"))
    #expect(AccountConfig.isValidSlug("box-2"))
    #expect(!AccountConfig.isValidSlug("has space"))
    #expect(!AccountConfig.isValidSlug("a/b"))
    #expect(!AccountConfig.isValidSlug("a#b"))  // would collide with Integration's own separator
    #expect(!AccountConfig.isValidSlug(""))
}

// The seed is the app's first-run shape AND its own documentation, so it has to survive its own parser.
@Test func theSeededFileParsesToTheDefaultShape() {
    let seeded = AccountsFile.parse(Data(AccountsFile.seedDocument.utf8))
    #expect(seeded?.map(\.integration) == AccountsFile.defaultKeys)
    #expect(seeded?.allSatisfy { $0.host == .local } == true)
}

@Test func seedingNeverOverwritesAnExistingFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("accounts.json")

    #expect(AccountsFile.seedIfAbsent(at: url))
    try Data("{\"accounts\":[{\"harness\":\"codex\"}]}".utf8).write(to: url)
    #expect(!AccountsFile.seedIfAbsent(at: url))
    #expect(AccountsFile.load(at: url)?.map(\.integration) == [.codex])
}

@Test func updatingAnAccountsHostPreservesTheAccountAndItsOtherFields() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("accounts.json")
    try Data(
        #"{"version":1,"accounts":[{"harness":"codex","account":"work","label":"Work","host":"old","configDir":"~/.codex-work"}]}"#.utf8
    ).write(to: url)

    let work = Integration(harness: .codex, account: "work")
    #expect(AccountsFile.setHost("sunny-new-direct", for: work, at: url))
    let saved = try #require(AccountsFile.load(at: url)?.first)
    #expect(saved.host == .ssh("sunny-new-direct"))
    #expect(saved.label == "Work")
    #expect(saved.configDir == "~/.codex-work")

    #expect(AccountsFile.setHost(nil, for: work, at: url))
    #expect(AccountsFile.load(at: url)?.first?.host == .local)
}

@Test func assigningAnOperationalSlotPreservesBothLoginProfiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("accounts.json")
    try Data(
        #"{"accounts":[{"harness":"claude","account":"a","configDir":"~/.claude-a"},{"harness":"claude","account":"b","configDir":"~/.claude-b"}]}"#.utf8
    ).write(to: url)

    let a = Integration(harness: .claude, account: "a")
    let b = Integration(harness: .claude, account: "b")
    #expect(AccountsFile.setUsageSource(a, for: b, at: url))
    let accounts = try #require(AccountsFile.load(at: url))
    let savedB = try #require(accounts.first { $0.integration == b })
    #expect(savedB.usageSource == "a")
    #expect(savedB.source(in: accounts).configDir == "~/.claude-a")
    #expect(accounts.first { $0.integration == a }?.configDir == "~/.claude-a")
}
