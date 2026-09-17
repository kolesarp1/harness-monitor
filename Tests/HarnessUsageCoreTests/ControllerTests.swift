import Foundation
import Testing

@testable import HarnessUsageCore

private let first = AccountConfig(
    harness: .claude, label: "A", host: .ssh("box"), configDir: "~/.claude-a")
private let second = AccountConfig(
    harness: .claude, account: "b", label: "B", host: .ssh("box"), configDir: "~/.claude-b")

@Test func credentialExchangeRequiresTwoDistinctProfilesOnOneHost() {
    #expect(ClaudeCredentialController(first: first, second: first) == nil)
    #expect(
        ClaudeCredentialController(
            first: first,
            second: AccountConfig(harness: .claude, account: "b", host: .ssh("other"))) == nil)
    #expect(
        ClaudeCredentialController(
            first: first,
            second: AccountConfig(
                harness: .claude, account: "b", host: .ssh("box"), configDir: "~/.claude-a")) == nil)
}

@Test func controllerPreflightAndRemoteFailureAreStructured() async throws {
    let ready = try #require(
        ClaudeCredentialController(
            first: first, second: second, run: { _ in .ok("READY\n") }))
    #expect(await ready.preflight() == .ready)

    let refused = try #require(
        ClaudeCredentialController(
            first: first, second: second, run: { _ in .ok("ERR missing_login\n") }))
    #expect(await refused.preflight() == .refused("One remote Claude profile has no readable credential file."))

    let failed = try #require(
        ClaudeCredentialController(
            first: first, second: second, run: { _ in .failed("ssh timed out") }))
    #expect(await failed.preflight() == .failed("ssh timed out"))
}

@Test func controllerExchangeReportsOnlyItsRemoteBackupIdentifier() async throws {
    let backupID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let controller = try #require(
        ClaudeCredentialController(
            first: first, second: second,
            run: { script in
                #expect(script.contains("HU_FIRST="))
                #expect(script.contains("HU_SECOND="))
                #expect(script.contains("first.profile.json"))
                #expect(script.contains("second.credentials.json"))
                #expect(!script.contains("echo \"$tok\""))
                return .ok("EXCHANGED \(backupID.uuidString)\n")
            }))
    #expect(await controller.exchange(backupID: backupID) == .exchanged(backupID: backupID))
}

@Test func controllerCanReportAConfirmedSharedLogin() async throws {
    let backupID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let controller = try #require(
        ClaudeCredentialController(
            first: first, second: second,
            run: { script in
                #expect(script.contains("HU_MODE='copyFirst'"))
                return .ok("COPIED \(backupID.uuidString)\n")
            }))
    #expect(await controller.copyFirstToSecond(backupID: backupID) == .copied(backupID: backupID))
}

@Test func auditKeepsTheLastRemoteBackupAvailableForRestore() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ControllerAuditStore(url: dir.appendingPathComponent("controller-audit.jsonl"))
    let backupID = UUID()
    let entry = ControllerAuditStore.Entry(
        action: .exchange, host: "box", first: first.integration, second: second.integration,
        succeeded: true, backupID: backupID)
    #expect(store.append(entry))
    #expect(
        store.latestRestorableBackup(
            host: "box", first: first.integration, second: second.integration) == backupID)

    #expect(
        store.append(
            ControllerAuditStore.Entry(
                action: .restore, host: "box", first: first.integration, second: second.integration,
                succeeded: true, restoredFrom: backupID)))
    #expect(
        store.latestRestorableBackup(
            host: "box", first: first.integration, second: second.integration) == nil)
}

// MARK: - Session flow

/// Answers with a scripted sequence, so a test can pin the preflight and the action separately.
private actor StubController: CredentialController {
    private var scripted: [ControllerOutcome]
    private let parked: [ParkedLogin]

    init(_ scripted: [ControllerOutcome], parked: [ParkedLogin] = []) {
        self.scripted = scripted
        self.parked = parked
    }

    private func next() -> ControllerOutcome {
        scripted.isEmpty ? .failed("the test ran out of scripted outcomes") : scripted.removeFirst()
    }

    func preflight() async -> ControllerOutcome { next() }
    func exchange(backupID: UUID) async -> ControllerOutcome { next() }
    func copyFirstToSecond(backupID: UUID) async -> ControllerOutcome { next() }
    func copySecondToFirst(backupID: UUID) async -> ControllerOutcome { next() }
    func preflightRestore(backupID: UUID) async -> ControllerOutcome { next() }
    func restore(backupID: UUID, newBackupID: UUID) async -> ControllerOutcome { next() }
    func parkedLogins() async -> [ParkedLogin] { parked }
}

@MainActor
private func makeSession(
    audit: ControllerAuditStore, outcomes: [ControllerOutcome], parked: [ParkedLogin] = []
) -> CredentialControllerSession {
    let stub = StubController(outcomes, parked: parked)
    return CredentialControllerSession(
        account: first, accounts: [first, second], audit: audit, makeController: { _, _ in stub })
}

private func temporaryAudit() -> (ControllerAuditStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (ControllerAuditStore(url: dir.appendingPathComponent("controller-audit.jsonl")), dir)
}

private func auditedEntries(_ store: ControllerAuditStore) -> [ControllerAuditStore.Entry] {
    guard let data = try? Data(contentsOf: store.url) else { return [] }
    return data.split(separator: 10).compactMap {
        try? JSONDecoder().decode(ControllerAuditStore.Entry.self, from: Data($0))
    }
}

@MainActor
@Test func aRefusedPreflightStagesNothing() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(
        audit: audit, outcomes: [.refused("One remote Claude profile has no readable credential file.")])
    #expect(session.partner?.integration == second.integration)

    await session.prepare(.swap)
    #expect(session.pending == nil)
    #expect(session.message.contains("no readable credential file"))
    #expect(auditedEntries(audit).isEmpty)  // nothing ran, nothing audited
}

@MainActor
@Test func aConfirmedSwapIsAuditedWithThePairItParked() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(audit: audit, outcomes: [.ready, .exchanged(backupID: UUID())])

    await session.prepare(.swap)
    #expect(session.pending?.action == .swap)
    #expect(session.pending?.loading == nil)
    #expect(await session.confirm())

    let entry = try #require(auditedEntries(audit).last)
    #expect(entry.action == .exchange)
    #expect(entry.succeeded)
    #expect(entry.backupID != nil)
}

// A refusal happens before the host writes anything, so the audit must not claim a parked pair that
// was never taken — the log is what says where a login can still be found.
@MainActor
@Test func aRefusedChangeIsAuditedWithoutAParkedPair() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(
        audit: audit, outcomes: [.ready, .refused("Another remote credential operation is running.")])

    await session.prepare(.swap)
    #expect(!(await session.confirm()))
    let entry = try #require(auditedEntries(audit).last)
    #expect(!entry.succeeded)
    #expect(entry.backupID == nil)
}

// An ssh failure is genuinely ambiguous: the host may have parked and written before the link
// dropped, so the identifier is kept and the pair stays findable.
@MainActor
@Test func anInterruptedChangeKeepsItsParkedPairFindable() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(audit: audit, outcomes: [.ready, .failed("ssh timed out")])

    await session.prepare(.swap)
    #expect(!(await session.confirm()))
    #expect(session.message == "ssh timed out")
    let entry = try #require(auditedEntries(audit).last)
    #expect(!entry.succeeded)
    #expect(entry.backupID != nil)
}

// What is parked is read back from the machine that holds it, never inferred locally — a lane has no
// home account, so the only truth about a saved pair is the pair itself.
@MainActor
@Test func parkedPairsComeFromTheOwningMachine() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let entry = ParkedLogin(
        id: UUID(), firstEmail: "one@example.com", secondEmail: "two@example.com",
        savedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let session = makeSession(audit: audit, outcomes: [.ready, .restored(backupID: UUID())], parked: [entry])

    await session.refreshParked()
    #expect(session.parked == [entry])

    await session.prepareLoad(entry)
    #expect(session.pending?.loading == entry)
    #expect(await session.confirm())
    #expect(auditedEntries(audit).last?.restoredFrom == entry.id)
}

// MARK: - Lanes

@Test func lanesAreLetteredInFileOrderAcrossEveryMachine() {
    let accounts = [
        AccountConfig(harness: .claude, label: "Personal", host: .ssh("sunny"), configDir: "~/.claude-a"),
        AccountConfig(harness: .claude, account: "work", label: "Work", host: .ssh("sunny"), configDir: "~/.claude-b"),
        AccountConfig(harness: .claude, account: "factory", host: .ssh("sparkles"), configDir: "~/.claude-factory"),
        AccountConfig(harness: .cursor),
    ]
    let lanes = accounts.lanes(of: .claude)
    #expect(lanes.map(\.letter) == ["A", "B", "C"])
    #expect(lanes.map(\.name) == ["Lane A", "Lane B", "Lane C"])
    // A lane on another machine still gets its own letter, so no two lanes are ever both "A".
    #expect(lanes[2].machine == "sparkles")
    #expect(lanes[2].directory == "~/.claude-factory")
    // A single-login harness has no lanes worth lettering.
    #expect(accounts.multiLaneHarnesses == [.claude])
}

@Test func aLaneIsNamedByItsPlaceNotByALabel() {
    let accounts = [
        AccountConfig(harness: .codex, label: "Personal", host: .ssh("sunny")),
        AccountConfig(harness: .codex, account: "work", label: "Work", host: .ssh("sunny"), configDir: "~/.codex-2"),
    ]
    let lanes = accounts.lanes(of: .codex)
    // The label is deliberately absent from every name a lane answers to: a login that moves would
    // leave the label describing an account that is no longer there.
    #expect(!lanes[0].name.contains("Personal"))
    #expect(lanes[0].directory == "~/.codex")
    #expect(lanes[1].directory == "~/.codex-2")
}
