import Foundation

/// The user-driven half of a controller action: choose a partner profile and an action, run a
/// dry-run preflight, confirm, apply, and record the result.
///
/// This lives in Core rather than in the Settings view so the parts that decide what actually
/// happens — which profiles are eligible, what a refusal means for the recovery path, what reaches
/// the audit log — are provider-neutral and testable. It holds profile keys and opaque backup
/// identifiers only; credentials never leave their owning machine.
@MainActor @Observable public final class CredentialControllerSession {
    public enum Action: Sendable, Hashable, CaseIterable {
        /// Give each profile the other's login.
        case exchange
        /// Put this pane's login in both profiles.
        case useOwnInBoth
        /// Put the partner's login in both profiles.
        case usePartnerInBoth
    }

    /// A preflighted action waiting for the user to confirm it.
    public struct Pending: Sendable, Equatable {
        public let partner: AccountConfig
        public let action: Action
        /// The backup being restored, or nil when this is a forward change.
        public let restoring: UUID?
    }

    public let account: AccountConfig
    /// The configured profiles this account can trade logins with: same harness, same machine,
    /// distinct profile directory, and a provider that supports the exchange.
    public let candidates: [AccountConfig]

    public var action: Action = .exchange
    public private(set) var partner: AccountConfig?
    public private(set) var isRunning = false
    public private(set) var message = ""
    /// The remote backup the "recover originals" path would restore, if any.
    public private(set) var restorableBackup: UUID?
    public private(set) var pending: Pending?

    private let audit: ControllerAuditStore
    private let makeController: @MainActor (AccountConfig, AccountConfig) -> (any CredentialController)?

    public init(
        account: AccountConfig, accounts: [AccountConfig], audit: ControllerAuditStore,
        makeController: (@MainActor (AccountConfig, AccountConfig) -> (any CredentialController)?)? = nil
    ) {
        let make =
            makeController
            ?? { first, second in
                first.harness.descriptor.credentialController(first: first, second: second)
            }
        self.account = account
        self.audit = audit
        self.makeController = make
        self.candidates = accounts.filter {
            $0.integration != account.integration && $0.host == account.host
                && make(account, $0) != nil
        }
        self.partner = candidates.first
        self.restorableBackup = candidates.first.flatMap {
            Self.latestBackup(pairing: account, with: $0, in: audit)
        }
    }

    /// The backup the recovery path would put back for one pair of profiles, if any.
    private static func latestBackup(
        pairing account: AccountConfig, with partner: AccountConfig, in audit: ControllerAuditStore
    ) -> UUID? {
        audit.latestRestorableBackup(
            host: account.host.sshAlias ?? "", first: account.integration,
            second: partner.integration)
    }

    private var host: String { account.host.sshAlias ?? "" }

    /// Point the controller at a different partner profile. The recovery offer follows the pair,
    /// since a backup belongs to the two profiles it was taken from.
    public func select(_ candidate: Integration) {
        guard !isRunning, let chosen = candidates.first(where: { $0.integration == candidate }) else { return }
        partner = chosen
        restorableBackup = Self.latestBackup(pairing: account, with: chosen, in: audit)
        message = ""
    }

    /// Dry-run the configured change. On success the action becomes `pending` for the user to
    /// confirm; otherwise the refusal is reported and nothing is staged.
    public func prepare(with candidate: Integration? = nil) async {
        if let candidate { select(candidate) }
        guard !isRunning, let partner, let controller = makeController(account, partner) else { return }
        let requested = action
        await run {
            let outcome = await controller.preflight()
            guard outcome == .ready else {
                self.message = outcome.message
                return
            }
            self.pending = Pending(partner: partner, action: requested, restoring: nil)
        }
    }

    /// Dry-run putting the last backup back.
    public func prepareRestore() async {
        guard !isRunning, let partner, let backupID = restorableBackup,
            let controller = makeController(account, partner)
        else { return }
        await run {
            let outcome = await controller.preflightRestore(backupID: backupID)
            guard outcome == .ready else {
                self.message = outcome.message
                return
            }
            self.pending = Pending(partner: partner, action: self.action, restoring: backupID)
        }
    }

    public func cancel() { pending = nil }

    /// Apply the confirmed action. Returns true when the owning profiles changed on the remote
    /// host, so the caller can refresh what the rings are reading.
    @discardableResult
    public func confirm() async -> Bool {
        guard let pending, !isRunning, let controller = makeController(account, pending.partner) else { return false }
        self.pending = nil
        // Every change is identified by the backup it takes first, so a result that never reaches
        // this Mac can still be found on the remote host under this identifier.
        let operationID = UUID()
        var changed = false
        await run {
            let outcome: ControllerOutcome
            if let restoring = pending.restoring {
                outcome = await controller.restore(backupID: restoring, newBackupID: operationID)
            } else {
                switch pending.action {
                case .exchange: outcome = await controller.exchange(backupID: operationID)
                case .useOwnInBoth: outcome = await controller.copyFirstToSecond(backupID: operationID)
                case .usePartnerInBoth: outcome = await controller.copySecondToFirst(backupID: operationID)
                }
            }
            changed = self.record(outcome, pending: pending, operationID: operationID)
        }
        return changed
    }

    /// Fold one outcome into the recovery offer and the audit log. The distinction that matters is
    /// whether the remote host may have written: a refusal happens before any backup exists, so it
    /// must not leave behind a recovery offer that would shadow a real earlier backup, while a
    /// transport failure is genuinely unknown and keeps its identifier so the backup stays findable.
    private func record(_ outcome: ControllerOutcome, pending: Pending, operationID: UUID) -> Bool {
        message = outcome.message
        let wroteBackup: Bool
        var succeeded = false
        switch outcome {
        case .exchanged, .copied, .restored:
            succeeded = true
            wroteBackup = true
        case .partial:
            wroteBackup = true
        case .refused:
            wroteBackup = false
        case .ready, .failed:
            wroteBackup = true
        }
        let entry = ControllerAuditStore.Entry(
            action: pending.restoring != nil ? .restore : (pending.action == .exchange ? .exchange : .copy),
            host: host, first: account.integration, second: pending.partner.integration,
            succeeded: succeeded, backupID: wroteBackup ? operationID : nil,
            restoredFrom: pending.restoring)
        if !audit.append(entry) {
            message += " The controller audit could not be saved locally."
        }
        if wroteBackup {
            // A successful restore consumes the backup it came from; the audit decides what — if
            // anything — remains offerable for this pair.
            restorableBackup =
                succeeded && pending.restoring != nil
                ? Self.latestBackup(pairing: account, with: pending.partner, in: audit)
                : operationID
        }
        return succeeded
    }

    private func run(_ body: () async -> Void) async {
        isRunning = true
        message = ""
        await body()
        isRunning = false
    }
}
