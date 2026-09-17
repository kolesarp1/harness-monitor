import Foundation

/// The user-driven half of a lane change: pick the other lane and what to do, run a dry-run
/// preflight, confirm, apply, and record the result.
///
/// This lives in Core rather than in the Settings view so the parts that decide what actually
/// happens — which lanes are eligible, what a refusal means for what is parked, what reaches the
/// audit log — are provider-neutral and testable. It holds lane keys, login emails and opaque
/// parked-pair identifiers only; credentials never leave their owning machine.
@MainActor @Observable public final class CredentialControllerSession {
    public enum Action: Sendable, Hashable, CaseIterable {
        /// Give each lane the other's login.
        case swap
        /// Put this lane's login in both lanes.
        case useOwnInBoth
        /// Put the other lane's login in both lanes.
        case usePartnerInBoth
    }

    /// A preflighted change waiting for the user to confirm it.
    public struct Pending: Sendable, Equatable {
        public let partner: AccountConfig
        public let action: Action
        /// The parked pair being loaded back into the two lanes, or nil for a swap or copy.
        public let loading: ParkedLogin?
    }

    public let account: AccountConfig
    /// The lanes this one can trade logins with: same harness, same machine, distinct directory,
    /// and a provider that supports the exchange.
    public let candidates: [AccountConfig]

    public var action: Action = .swap
    public private(set) var partner: AccountConfig?
    public private(set) var isRunning = false
    public private(set) var message = ""
    /// Login pairs saved on the host by earlier changes, newest first. A lane has no home account,
    /// so these are offers to load, never a state the lanes are expected to return to.
    public private(set) var parked: [ParkedLogin] = []
    public private(set) var pending: Pending?

    private let accounts: [AccountConfig]
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
        self.accounts = accounts
        self.audit = audit
        self.makeController = make
        self.candidates = accounts.filter {
            $0.integration != account.integration && $0.host == account.host
                && make(account, $0) != nil
        }
        self.partner = candidates.first
    }

    private var host: String { account.host.sshAlias ?? "" }

    /// Point the controller at a different lane.
    public func select(_ candidate: Integration) {
        guard !isRunning, let chosen = candidates.first(where: { $0.integration == candidate }) else { return }
        partner = chosen
        message = ""
        parked = []
    }

    /// Ask the host which login pairs are parked there. Safe to call when a lane is signed out.
    public func refreshParked() async {
        guard let partner, let controller = makeController(account, partner) else { return }
        parked = await controller.parkedLogins()
    }

    /// Dry-run the configured change. On success it becomes `pending` for the user to confirm;
    /// otherwise the refusal is reported and nothing is staged.
    public func prepare(_ requested: Action? = nil) async {
        guard !isRunning, let partner, let controller = makeController(account, partner) else { return }
        if let requested { action = requested }
        let chosen = action
        await run {
            let outcome = await controller.preflight()
            guard outcome == .ready else {
                self.message = outcome.message
                return
            }
            self.pending = Pending(partner: partner, action: chosen, loading: nil)
        }
    }

    /// Which lane each half of a parked pair came out of. A pair is stored positionally, and the
    /// audit is the only record of what those positions meant, so everything that reads or writes a
    /// parked pair goes through this — the display, and the load itself.
    public func origin(of entry: ParkedLogin) -> (first: AccountConfig, second: AccountConfig)? {
        guard let logged = audit.entry(forBackup: entry.id),
            let first = accounts.first(where: { $0.integration == logged.first }),
            let second = accounts.first(where: { $0.integration == logged.second })
        else { return nil }
        return (first, second)
    }

    /// The controller oriented the way this pair was parked, so each login goes back to the lane it
    /// came from rather than to whichever lane happens to be showing.
    private func loader(for entry: ParkedLogin) -> (any CredentialController)? {
        guard let origin = origin(of: entry) else { return nil }
        return makeController(origin.first, origin.second)
    }

    /// Dry-run loading a parked pair back into the two lanes.
    public func prepareLoad(_ entry: ParkedLogin) async {
        guard !isRunning, let partner, let controller = loader(for: entry) else {
            message =
                "This saved pair predates the app's record of which lane each login came from, so it cannot be loaded safely."
            return
        }
        await run {
            let outcome = await controller.preflightRestore(backupID: entry.id)
            guard outcome == .ready else {
                self.message = outcome.message
                return
            }
            self.pending = Pending(partner: partner, action: self.action, loading: entry)
        }
    }

    public func cancel() { pending = nil }

    /// Apply the confirmed change. Returns true when the lanes changed on the owning host, so the
    /// caller can re-read what they now hold.
    @discardableResult
    public func confirm() async -> Bool {
        guard let pending, !isRunning else { return false }
        // A load is oriented by the record of how the pair was parked, and never falls back to the
        // showing lane pair: the wrong orientation would put each login in the other's lane.
        let resolved: (any CredentialController)?
        if let loading = pending.loading {
            resolved = loader(for: loading)
        } else {
            resolved = makeController(account, pending.partner)
        }
        guard let controller = resolved else { return false }
        self.pending = nil
        // Every change is identified by the pair it parks first, so a result that never reaches this
        // Mac can still be found on the host under this identifier.
        let operationID = UUID()
        var changed = false
        await run {
            let outcome: ControllerOutcome
            if let loading = pending.loading {
                outcome = await controller.restore(backupID: loading.id, newBackupID: operationID)
            } else {
                switch pending.action {
                case .swap: outcome = await controller.exchange(backupID: operationID)
                case .useOwnInBoth: outcome = await controller.copyFirstToSecond(backupID: operationID)
                case .usePartnerInBoth: outcome = await controller.copySecondToFirst(backupID: operationID)
                }
            }
            changed = self.record(outcome, pending: pending, operationID: operationID)
            self.parked = await controller.parkedLogins()
        }
        return changed
    }

    /// Fold one outcome into the audit log. The distinction that matters is whether the host may
    /// have written: a refusal happens before anything is parked, so it must not log a parked
    /// identifier that does not exist, while a transport failure is genuinely unknown and keeps its
    /// identifier so the parked pair stays findable.
    private func record(_ outcome: ControllerOutcome, pending: Pending, operationID: UUID) -> Bool {
        message = outcome.message
        let parkedAPair: Bool
        var succeeded = false
        switch outcome {
        case .exchanged, .copied, .restored:
            succeeded = true
            parkedAPair = true
        case .partial:
            parkedAPair = true
        case .refused:
            parkedAPair = false
        case .ready, .failed:
            parkedAPair = true
        }
        let entry = ControllerAuditStore.Entry(
            action: pending.loading != nil ? .restore : (pending.action == .swap ? .exchange : .copy),
            host: host, first: account.integration, second: pending.partner.integration,
            succeeded: succeeded, backupID: parkedAPair ? operationID : nil,
            restoredFrom: pending.loading?.id)
        if !audit.append(entry) {
            message += " The controller audit could not be saved locally."
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
