import Foundation
import Testing

@testable import HarnessUsageCore

// MARK: - the body/status envelope

@Test func aSuccessfulProbeSplitsBodyFromStatus() {
    let parsed = RemoteResponse.parse("{\"five_hour\":{\"utilization\":40}}\n200")
    #expect(parsed.status == 200)
    #expect(parsed.message == nil)
    #expect(String(decoding: parsed.body, as: UTF8.self) == "{\"five_hour\":{\"utilization\":40}}")
}

// A JSON body with newlines in it must not lose its interior lines to the split.
@Test func aMultiLineBodyIsReassembled() {
    let parsed = RemoteResponse.parse("{\n  \"a\": 1\n}\n200")
    #expect(parsed.status == 200)
    #expect(String(decoding: parsed.body, as: UTF8.self) == "{\n  \"a\": 1\n}")
}

// curl's `-w` adds no trailing newline, but a shell can; the status is the last NON-EMPTY line.
@Test func trailingBlankLinesDoNotHideTheStatus() {
    #expect(RemoteResponse.parse("{}\n429\n\n").status == 429)
}

// The script's own giving-up, distinguished from an HTTP status so the note can quote it verbatim.
@Test func theScriptCanReportItsOwnFailure() {
    let parsed = RemoteResponse.parse("ERR no readable login at ~/.claude-a")
    #expect(parsed.status == nil)
    #expect(parsed.message == "no readable login at ~/.claude-a")
}

@Test func silenceAndNonsenseAreBothReportedRatherThanGuessed() {
    #expect(RemoteResponse.parse("").message != nil)
    #expect(RemoteResponse.parse("   \n  ").message != nil)
    #expect(RemoteResponse.parse("bash: curl: command not found").status == nil)
    #expect(RemoteResponse.parse("bash: curl: command not found").message != nil)
}

// MARK: - shell quoting

// The one rule that keeps a config directory from the accounts file being executable text on the
// remote host: no input may end the quoting.
@Test func quotingSurvivesEverythingAShellCaresAbout() {
    #expect(RemoteScript.quote("~/.claude-a") == "'~/.claude-a'")
    #expect(RemoteScript.quote("a b") == "'a b'")
    #expect(RemoteScript.quote("it's") == #"'it'\''s'"#)
    // The payload a naive quoter would let escape.
    #expect(RemoteScript.quote("'; rm -rf ~; echo '") == #"''\''; rm -rf ~; echo '\'''"#)
    #expect(RemoteScript.quote("$(whoami)") == "'$(whoami)'")
    #expect(RemoteScript.quote("`id`") == "'`id`'")
}

// MARK: - probe scripts

// The credential must be read, used and dropped on the far side: a script that printed the token, or
// passed it in argv where the remote `ps` shows it, would defeat the whole arrangement.
@Test func probeScriptsNeverEmitOrExposeTheToken() throws {
    for harness in [Harness.claude, .codex] {
        let probe = try #require(harness.descriptor.remoteProbe(configDir: "~/.x"))
        // The token reaches curl through its config file, never as an argument.
        #expect(!probe.script.contains("-H \"Authorization"))
        #expect(!probe.script.contains("echo \"$tok\""))
        #expect(probe.script.contains("--config"))
        // And the config file is removed however the script ends.
        #expect(probe.script.contains("trap 'rm -f \"$cfg\"' EXIT"))
        #expect(probe.script.contains("umask 077"))
    }
}

@Test func probeScriptsQuoteTheConfigDirectory() throws {
    let probe = try #require(Harness.claude.descriptor.remoteProbe(configDir: "~/.claude-a"))
    #expect(probe.script.contains("'~/.claude-a'/.credentials.json"))
}

// A harness with no credential-backed endpoint has no remote tier to offer, and must say so rather
// than producing a script that cannot work.
@Test func harnessesWithoutAnEndpointHaveNoRemoteProbe() {
    #expect(Harness.opencode.descriptor.remoteProbe(configDir: "~/.x") == nil)
    #expect(Harness.cursor.descriptor.remoteProbe(configDir: "~/.x") == nil)
}

// The remote tier must build its windows with the SAME decoder as the local one, or a remote ring
// could disagree with a local ring reading the same account.
@Test func theClaudeProbeDecodesARealResponseShape() throws {
    let probe = try #require(Harness.claude.descriptor.remoteProbe(configDir: "~/.claude-a"))
    let now = Date(timeIntervalSince1970: 1_757_600_000)
    let body = Data(
        """
        {"five_hour":{"utilization":40.0,"resets_at":"2099-01-01T00:00:00+00:00"},
         "seven_day":{"utilization":68.0,"resets_at":"2099-01-02T00:00:00+00:00"}}
        """.utf8)

    let snapshot = try #require(probe.parse(body, now))
    #expect(snapshot.windows.map(\.utilization) == [40, 68])
    #expect(snapshot.primaryWindow?.id == "5h")
}

@Test func theCodexProbeDecodesARealResponseShape() throws {
    let probe = try #require(Harness.codex.descriptor.remoteProbe(configDir: "~/.codex"))
    let now = Date(timeIntervalSince1970: 1_757_600_000)
    let body = Data(
        """
        {"rate_limit":{
          "primary_window":{"used_percent":12.5,"reset_at":4070908800,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":61.0,"reset_at":4071168000,"limit_window_seconds":604800}}}
        """.utf8)

    let snapshot = try #require(probe.parse(body, now))
    #expect(snapshot.windows.map(\.title) == ["Session", "Weekly"])
    #expect(snapshot.windows.map(\.utilization) == [12.5, 61])
}

// MARK: - the monitor's failure behaviour

// A monitor with no reading yet still explains itself, rather than rendering an empty ring with no
// account of why — that silence is the failure mode the note exists to prevent.
@Test func aRemoteMonitorWithNothingToShowStillSaysWhy() async {
    let monitor = RemoteMonitor(
        alias: "box", probe: nullProbe,
        run: { _ in .failed("could not reach box over ssh") })

    let snapshot = await monitor.reload(wantUsageEstimate: false)
    #expect(snapshot?.windows.isEmpty == true)
    #expect(snapshot?.note?.contains("could not reach box") == true)
}

// A transient outage keeps the last real meters on screen — a ring that blanked on one dropped ssh
// connection would be less useful than one that says "this is from four minutes ago".
@Test func atransientFailureCarriesTheLastGoodReading() async {
    let monitor = RemoteMonitor(
        alias: "box", probe: claudeProbe, run: scripted([.ok(okBody), .failed("ssh timed out")]),
        floor: 0)

    let first = await monitor.reload(wantUsageEstimate: false)
    #expect(first?.windows.map(\.utilization) == [40, 68])
    #expect(first?.note == nil)

    let second = await monitor.reload(wantUsageEstimate: false)
    #expect(second?.windows.map(\.utilization) == [40, 68])  // the meters stand
    #expect(second?.note?.contains("ssh timed out") == true)  // and say why they are not newer
}

// A signed-out account is the exception: keeping its percentages would show numbers from an account
// we can no longer read, under a ring that claims to be reading it.
@Test func signingOutRemotelyDropsTheMetersRatherThanCarryingThem() async {
    let monitor = RemoteMonitor(
        alias: "box", probe: claudeProbe, run: scripted([.ok(okBody), .ok("{}\n401")]), floor: 0)

    _ = await monitor.reload(wantUsageEstimate: false)
    let after = await monitor.reload(wantUsageEstimate: false)

    #expect(after?.windows.isEmpty == true)
    #expect(after?.note?.contains("Signed out on box") == true)
}

// The floor is what keeps a background refresh off an ssh connection every tick. The Engine calls
// `reload` far more often than 300s, and each call is a process spawn if it is not gated.
@Test func theFetchFloorGatesTheSSHSpawn() async {
    let calls = CallCounter()
    let monitor = RemoteMonitor(
        alias: "box", probe: claudeProbe,
        run: { script in
            await calls.record()
            return .ok(okBody)
        },
        floor: 300)

    _ = await monitor.reload(wantUsageEstimate: false)
    _ = await monitor.reload(wantUsageEstimate: false)
    _ = await monitor.reload(wantUsageEstimate: false)
    #expect(await calls.count == 1)

    // "Update now" drops our own floor, which is exactly what that button is for.
    await monitor.invalidateThrottles()
    _ = await monitor.reload(wantUsageEstimate: false)
    #expect(await calls.count == 2)
}

// A 429 is the endpoint's own instruction, not our floor, so pressing "Update now" must not waive it.
@Test func aRateLimitHoldSurvivesUpdateNow() async {
    let calls = CallCounter()
    let monitor = RemoteMonitor(
        alias: "box", probe: claudeProbe,
        run: { _ in
            await calls.record()
            return .ok("{}\n429")
        },
        floor: 300)

    _ = await monitor.reload(wantUsageEstimate: false)
    await monitor.invalidateThrottles()
    _ = await monitor.reload(wantUsageEstimate: false)

    #expect(await calls.count == 1)
}

// MARK: - stubs

private let nullProbe = RemoteProbe(script: "true") { _, _ in nil }

private let claudeProbe = RemoteProbe(script: "true") { data, now in
    ClaudeOAuthUsage.snapshot(fromResponseData: data, now: now)
}

private let okBody = """
    {"five_hour":{"utilization":40.0,"resets_at":"2099-01-01T00:00:00+00:00"},
     "seven_day":{"utilization":68.0,"resets_at":"2099-01-02T00:00:00+00:00"}}
    200
    """

private actor CallCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

// Hands back one scripted outcome per call, then repeats the last — so a test states the sequence it
// cares about and nothing after it.
private func scripted(_ outcomes: [RemoteShell.Outcome]) -> @Sendable (String) async -> RemoteShell.Outcome {
    let cursor = ScriptCursor(outcomes)
    return { _ in await cursor.next() }
}

private actor ScriptCursor {
    private let outcomes: [RemoteShell.Outcome]
    private var index = 0
    init(_ outcomes: [RemoteShell.Outcome]) { self.outcomes = outcomes }
    func next() -> RemoteShell.Outcome {
        defer { index = min(index + 1, outcomes.count - 1) }
        return outcomes[index]
    }
}
