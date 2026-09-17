import Foundation

/// Controller actions are explicit and separate from the background usage monitor. Only an opaque
/// backup identifier and a structured outcome cross back from the profile's owning machine.
public protocol CredentialController: Sendable {
    func preflight() async -> ControllerOutcome
    func exchange(backupID: UUID) async -> ControllerOutcome
    func copyFirstToSecond(backupID: UUID) async -> ControllerOutcome
    func copySecondToFirst(backupID: UUID) async -> ControllerOutcome
    func preflightRestore(backupID: UUID) async -> ControllerOutcome
    func restore(backupID: UUID, newBackupID: UUID) async -> ControllerOutcome
}

public enum ControllerOutcome: Sendable, Equatable {
    case ready
    case exchanged(backupID: UUID)
    case copied(backupID: UUID)
    case restored(backupID: UUID)
    case partial(backupID: UUID)
    case refused(String)
    case failed(String)

    public var message: String {
        switch self {
        case .ready: "Both remote logins are ready to exchange."
        case .exchanged: "Remote logins exchanged. Restart the affected Claude sessions."
        case .copied: "Remote login copied to both profiles. Restart the affected Claude sessions."
        case .restored: "Original remote logins restored. Restart the affected Claude sessions."
        case .partial: "The remote action was interrupted and automatic rollback failed. The backup remains on the SSH box."
        case .refused(let reason), .failed(let reason): reason
        }
    }
}
