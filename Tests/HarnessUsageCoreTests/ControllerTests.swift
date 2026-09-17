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
    init(_ scripted: [ControllerOutcome]) { self.scripted = scripted }

    private func next() -> ControllerOutcome {
        scripted.isEmpty ? .failed("the test ran out of scripted outcomes") : scripted.removeFirst()
    }

    func preflight() async -> ControllerOutcome { next() }
    func exchange(backupID: UUID) async -> ControllerOutcome { next() }
    func copyFirstToSecond(backupID: UUID) async -> ControllerOutcome { next() }
    func copySecondToFirst(backupID: UUID) async -> ControllerOutcome { next() }
    func preflightRestore(backupID: UUID) async -> ControllerOutcome { next() }
    func restore(backupID: UUID, newBackupID: UUID) async -> ControllerOutcome { next() }
}

@MainActor
private func makeSession(
    audit: ControllerAuditStore, outcomes: [ControllerOutcome]
) -> CredentialControllerSession {
    let stub = StubController(outcomes)
    return CredentialControllerSession(
        account: first, accounts: [first, second], audit: audit, makeController: { _, _ in stub })
}

private func temporaryAudit() -> (ControllerAuditStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (ControllerAuditStore(url: dir.appendingPathComponent("controller-audit.jsonl")), dir)
}

@MainActor
@Test func aRefusedPreflightStagesNothing() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(audit: audit, outcomes: [.refused("One remote Claude profile has no readable credential file.")])
    #expect(session.partner?.integration == second.integration)

    await session.prepare()
    #expect(session.pending == nil)
    #expect(session.message.contains("no readable credential file"))
    #expect(session.restorableBackup == nil)
    #expect(!FileManager.default.fileExists(atPath: audit.url.path))  // nothing ran, nothing audited
}

@MainActor
@Test func aConfirmedExchangeRecordsItsBackupAndReportsTheChange() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(audit: audit, outcomes: [.ready, .exchanged(backupID: UUID())])

    await session.prepare()
    #expect(session.pending?.action == .exchange)
    #expect(await session.confirm())
    let backup = try #require(session.restorableBackup)
    #expect(
        audit.latestRestorableBackup(
            host: "box", first: first.integration, second: second.integration) == backup)
}

// A refusal happens before the remote host writes anything, so it must not leave a recovery offer
// pointing at a backup that was never taken — which would also hide the last real one.
@MainActor
@Test func aRefusedChangeLeavesTheEarlierBackupRecoverable() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(
        audit: audit,
        outcomes: [.ready, .exchanged(backupID: UUID()), .ready, .refused("Another remote credential operation is running.")])

    await session.prepare()
    #expect(await session.confirm())
    let original = try #require(session.restorableBackup)

    await session.prepare()
    #expect(!(await session.confirm()))
    #expect(session.restorableBackup == original)
    #expect(
        audit.latestRestorableBackup(
            host: "box", first: first.integration, second: second.integration) == original)
}

// An ssh failure is genuinely ambiguous: the remote may have written before the link dropped, so
// the operation keeps its identifier and the backup stays findable.
@MainActor
@Test func anInterruptedChangeKeepsItsBackupFindable() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(audit: audit, outcomes: [.ready, .failed("ssh timed out")])

    await session.prepare()
    #expect(!(await session.confirm()))
    #expect(session.message == "ssh timed out")
    let backup = try #require(session.restorableBackup)
    #expect(
        audit.latestRestorableBackup(
            host: "box", first: first.integration, second: second.integration) == backup)
}

@MainActor
@Test func aSuccessfulRestoreConsumesTheBackupItCameFrom() async throws {
    let (audit, dir) = temporaryAudit()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = makeSession(
        audit: audit,
        outcomes: [.ready, .exchanged(backupID: UUID()), .ready, .restored(backupID: UUID())])

    await session.prepare()
    #expect(await session.confirm())
    await session.prepareRestore()
    #expect(session.pending?.restoring != nil)
    #expect(await session.confirm())
    #expect(session.restorableBackup == nil)
}
