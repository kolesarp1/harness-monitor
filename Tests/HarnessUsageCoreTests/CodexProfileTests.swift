import Foundation
import Testing

@testable import HarnessUsageCore

private func codexJWT(_ payload: String) -> String {
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

private func codexAuth(account: String, name: String, email: String, plan: String, expiresAt: Date) -> Data {
    let access = codexJWT(#"{"exp":\#(Int(expiresAt.timeIntervalSince1970))}"#)
    let identity = codexJWT(
        #"{"name":"\#(name)","email":"\#(email)","https://api.openai.com/auth":{"chatgpt_plan_type":"\#(plan)","chatgpt_account_id":"\#(account)"}}"#)
    return Data(
        #"{"tokens":{"id_token":"\#(identity)","access_token":"\#(access)","account_id":"\#(account)"}}"#.utf8)
}

private func writeCodexProfile(
    _ profile: CodexProfile, account: String, name: String, email: String, plan: String,
    utilization: Int, now: Date
) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: profile.directory, withIntermediateDirectories: true)
    try codexAuth(
        account: account, name: name, email: email, plan: plan,
        expiresAt: now.addingTimeInterval(-60)
    ).write(to: profile.authFile)

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy/MM/dd"
    let sessions = profile.sessionsDirectory.appendingPathComponent(formatter.string(from: now), isDirectory: true)
    try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
    let rollout = sessions.appendingPathComponent("rollout.jsonl")
    let reset = Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
    try Data(
        #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(utilization),"resets_at":\#(reset),"window_minutes":300}}}}"#.utf8
    ).write(to: rollout)
    try fm.setAttributes([.modificationDate: now], ofItemAtPath: rollout.path)
}

// Defect: every `.codex-*` scratch directory getting an empty ring, or an authenticated home being
// missed. The default is retained even while signed out because its local rollouts can still be useful.
@Test func discoveryListsTheDefaultThenOnlySignedInCodexHomes() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("hu-codex-profiles-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    for name in ["work", "alpha", "scratch"] {
        try fm.createDirectory(at: home.appendingPathComponent(".codex-\(name)"), withIntermediateDirectories: true)
    }
    try Data(#"{"tokens":{"access_token":"token"}}"#.utf8)
        .write(to: home.appendingPathComponent(".codex-work/auth.json"))
    try Data(#"{"tokens":{"access_token":"token"}}"#.utf8)
        .write(to: home.appendingPathComponent(".codex-alpha/auth.json"))

    #expect(CodexProfile.discover(home: home, environment: [:]).map(\.name) == [nil, "alpha", "work"])
}

// Defect: a multi-account wrapper discovering two homes but constructing both readers against the
// default CODEX_HOME, which duplicates one account's percentages and identity under both rings.
@Test func everyCodexHomeReadsItsOwnRolloutsAndIdentity() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("hu-codex-accounts-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    let now = Date(timeIntervalSince1970: 1_766_000_000)
    let personal = CodexProfile.standard(home: home, environment: [:])
    let work = CodexProfile.named("work", home: home)
    try writeCodexProfile(
        personal, account: "acct-personal", name: "alex.k", email: "alex@example.com", plan: "prolite",
        utilization: 21, now: now)
    try writeCodexProfile(
        work, account: "acct-work", name: "Alex Northwind", email: "alex@northwind.dev", plan: "team",
        utilization: 78, now: now)

    let monitor = CodexProfilesMonitor(home: home, environment: [:], now: { now })
    let readings = await monitor.reloadProfiles(wantUsageEstimate: false)
    let defaultLogin: String? = nil
    let personalReading = try #require(readings[defaultLogin])
    let workReading = try #require(readings["work"])

    #expect(personalReading.windows.first?.utilization == 21)
    #expect(workReading.windows.first?.utilization == 78)
    #expect(
        personalReading.account
            == UsageAccount(
                id: "acct-personal", email: "alex@example.com", plan: "Pro 5x",
                location: "~/.codex", suggestedName: "alex.k"))
    #expect(
        workReading.account
            == UsageAccount(
                id: "acct-work", email: "alex@northwind.dev", plan: "Team",
                location: "~/.codex-work", suggestedName: "Alex Northwind"))
}
