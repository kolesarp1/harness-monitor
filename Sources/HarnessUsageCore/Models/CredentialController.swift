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
    /// The logins parked on the owning machine, newest first. Each entry names only the accounts it
    /// holds, by the login email the provider already stores as non-secret metadata.
    func parkedLogins() async -> [ParkedLogin]
}

/// A pair of logins saved on the owning machine before a lane change, and the way back to them.
///
/// It is NOT an "original" state: no account belongs to a lane, so a parked pair is simply a
/// snapshot of who sat where at one moment, which the user may choose to load again.
extension CredentialController {
    /// A provider whose controller keeps nothing aside has nothing parked.
    public func parkedLogins() async -> [ParkedLogin] { [] }
}

public struct ParkedLogin: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The account that was in the first lane of the pair, and in the second. nil when the parked
    /// file carries no readable login email.
    public let firstEmail: String?
    public let secondEmail: String?
    public let savedAt: Date?

    public init(id: UUID, firstEmail: String?, secondEmail: String?, savedAt: Date? = nil) {
        self.id = id
        self.firstEmail = firstEmail
        self.secondEmail = secondEmail
        self.savedAt = savedAt
    }
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
        case .ready: "Both lanes are ready."
        case .exchanged: "Lanes swapped. Restart the affected Claude sessions."
        case .copied: "That login is now in both lanes. Restart the affected Claude sessions."
        case .restored: "Parked logins loaded into their lanes. Restart the affected Claude sessions."
        case .partial: "The lane change was interrupted and automatic rollback failed. The parked copy remains on the host."
        case .refused(let reason), .failed(let reason): reason
        }
    }
}
