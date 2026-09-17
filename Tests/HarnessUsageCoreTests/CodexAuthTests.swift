import Foundation
import Testing

@testable import HarnessUsageCore

// A JWT whose payload segment is `payload`, base64url-encoded exactly as a real token is: `+/` swapped
// for `-_` and the `=` padding stripped. The header and signature are never read.
private func jwt(payload: String) -> String {
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJSUzI1NiJ9.\(encoded).sig"
}

private func strippedPadCount(_ payload: String) -> Int {
    let unpadded = Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
    return (4 - unpadded.count % 4) % 4
}

private let expected = Date(timeIntervalSince1970: 1_766_000_000)

// Defect: a base64url padding bug that silently disables the live tier for every real token. Both
// non-zero pad counts are mandatory — an unpadded payload decodes even under a broken re-pad, so a
// single fixture can pass while the code is wrong.
@Test func decodesExpiryAcrossEveryBase64urlPaddingLength() {
    let twoPad = #"{"exp": 1766000000}"#  // 19 bytes -> 26 base64 chars -> 2 pad
    let onePad = #"{"exp":1766000000,"aud":"xy"}"#  // 29 bytes -> 39 base64 chars -> 1 pad
    let zeroPad = #"{"exp":1766000000}"#  // 18 bytes -> 24 base64 chars -> 0 pad

    // Pinned here so a future edit to the literals can't quietly drop a padding case.
    #expect(strippedPadCount(twoPad) == 2)
    #expect(strippedPadCount(onePad) == 1)
    #expect(strippedPadCount(zeroPad) == 0)

    #expect(CodexAuth.decodeExpiry(fromJWT: jwt(payload: twoPad)) == expected)
    #expect(CodexAuth.decodeExpiry(fromJWT: jwt(payload: onePad)) == expected)
    #expect(CodexAuth.decodeExpiry(fromJWT: jwt(payload: zeroPad)) == expected)
}

@Test func garbageAndExpirylessTokensDecodeToNil() {
    #expect(CodexAuth.decodeExpiry(fromJWT: "not-a-jwt") == nil)
    #expect(CodexAuth.decodeExpiry(fromJWT: "aaa.!!!not-base64!!!.bbb") == nil)
    #expect(CodexAuth.decodeExpiry(fromJWT: jwt(payload: #"{"sub":"abc"}"#)) == nil)
    #expect(CodexAuth.decodeExpiry(fromJWT: "") == nil)
}

@Test func parsesTheAuthFileShapeTheCLIWrites() throws {
    let token = jwt(payload: #"{"exp":1766000000}"#)
    let idToken = jwt(
        payload:
            #"{"name":"alex.k","email":"alex@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"prolite","chatgpt_user_id":"user-7","chatgpt_account_id":"workspace-4"}}"#)
    let data = Data(
        """
        {"auth_mode": "chatgpt",
         "OPENAI_API_KEY": null,
         "tokens": {"id_token": "\(idToken)", "access_token": "\(token)", "refresh_token": "rt.1.secret", "account_id": "acct-42"},
         "last_refresh": "2026-08-17T10:00:00Z"}
        """.utf8)

    let parsed = try #require(CodexAuth.parse(data))
    #expect(parsed.accessToken == token)
    #expect(parsed.accountId == "acct-42")
    #expect(parsed.identityId == "acct-42")
    #expect(parsed.name == "alex.k")
    #expect(parsed.email == "alex@example.com")
    #expect(parsed.plan == "Pro 5x")
    #expect(parsed.expiresAt == expected)
    #expect(parsed.isExpired(now: expected.addingTimeInterval(1)))
    #expect(parsed.isExpired(now: expected.addingTimeInterval(-1)) == false)
}

@Test func anApiKeyOnlyAuthFileYieldsNoToken() {
    #expect(CodexAuth.parse(Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8)) == nil)
    #expect(CodexAuth.parse(Data(#"{"tokens":{"access_token":""}}"#.utf8)) == nil)
    #expect(CodexAuth.parse(Data("not json".utf8)) == nil)
}

// Defect: only a few Codex plan variants becoming readable while known workspace plans leak codes.
@Test(
    arguments: [
        ("free", "Free"), ("go", "Go"), ("plus", "Plus"), ("pro", "Pro 20x"),
        ("prolite", "Pro 5x"), ("Pro 5x", "Pro 5x"), ("team", "Team"),
        ("self_serve_business_prolite", "Self Serve Business ProLite"),
        ("self_serve_business_usage_based", "Self Serve Business Usage Based"),
        ("business", "Business"), ("ent26", "Enterprise"),
        ("enterprise_cbp_automation", "Enterprise (Automation)"),
        ("enterprise_cbp_usage_based", "Enterprise CBP Usage Based"),
        ("enterprise", "Enterprise"), ("hc", "Enterprise"),
        ("education", "Edu"), ("edu", "Edu"), ("edu_plus", "Edu Plus"),
        ("edu_pro", "Edu Pro"),
    ])
func knownPlanLabelsMatchCodex(_ raw: String, _ expected: String) {
    #expect(CodexAuth.planLabel(raw) == expected)
}

@Test func planLabelsHandlePersistedCapitalizationAndUnknownValues() {
    #expect(Integration.codex.planDisplayName("Prolite") == "Pro 5x")
    #expect(Integration.codex.planDisplayName("SELF_SERVE_BUSINESS_USAGE_BASED") == "Self Serve Business Usage Based")
    #expect(CodexAuth.planLabel("future_plan") == "Future_plan")
    #expect(CodexAuth.planLabel("  ") == nil)
}

// Defect: a second $CODEX_HOME implementation drifting from `CodexMonitor.codexRoot` — the live tier
// would read auth.json from a different root than the rollout scan uses.
@Test func readHonoursCodexHomeThroughTheSharedRootResolver() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hu-codex-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let token = jwt(payload: #"{"exp":1766000000}"#)
    try Data(#"{"tokens":{"access_token":"\#(token)","account_id":"acct-9"}}"#.utf8)
        .write(to: root.appendingPathComponent("auth.json"))

    let unusedHome = URL(fileURLWithPath: "/nonexistent-home")
    let read = try #require(CodexAuth.read(home: unusedHome, env: ["CODEX_HOME": root.path]))
    #expect(read.accountId == "acct-9")
    // No CODEX_HOME and no ~/.codex/auth.json under that home -> nothing.
    #expect(CodexAuth.read(home: unusedHome, env: [:]) == nil)
}
