import Foundation

/// A lane is one working directory a provider CLI runs against — `~/.claude-a`, `~/.claude-b`.
///
/// The distinction this type exists to keep is that a lane is a PLACE, not an account. No account
/// belongs to a lane: a login can be swapped into one, copied into both, or parked away, and the
/// lane is whatever it currently holds. So a lane is named by its position (a letter) and its
/// directory, never by a label that would go stale the moment a login moves.
public struct Lane: Sendable, Equatable, Identifiable {
    public let account: AccountConfig
    /// A, B, C… in `accounts.json` order, per harness and across every host it reaches.
    public let letter: String

    public var id: Integration { account.integration }
    public var integration: Integration { account.integration }
    public var host: AccountHost { account.host }

    public init(account: AccountConfig, letter: String) {
        self.account = account
        self.letter = letter
    }

    /// "Lane B", the one name for this place.
    public var name: String { "Lane \(letter)" }

    /// The directory as configured, which is how the user recognizes it. `resolvedConfigDir` is
    /// deliberately not used: `~` belongs to the lane's own machine, and expanding it against this
    /// Mac's home would print a path that does not exist anywhere.
    public var directory: String {
        account.configDir ?? "~/\(account.harness.descriptor.homeRelativePath)"
    }

    public var machine: String { account.host.sshAlias ?? "This Mac" }
}

extension Array where Element == AccountConfig {
    /// Letter every account of one harness, in file order. Lettering spans hosts, so two lanes never
    /// share a letter even when they sit on different machines.
    public func lanes(of harness: Harness) -> [Lane] {
        filter { $0.harness == harness }.enumerated().map { index, account in
            Lane(account: account, letter: Lane.letter(at: index))
        }
    }

    /// Every harness that has more than one lane, in file order — the ones where a letter carries
    /// information. A harness with a single login has nothing to distinguish.
    public var multiLaneHarnesses: [Harness] {
        var seen: Set<Harness> = []
        return compactMap { account in
            guard seen.insert(account.harness).inserted,
                filter({ $0.harness == account.harness }).count > 1
            else { return nil }
            return account.harness
        }
    }
}

extension Lane {
    /// A, B … Z, then AA, AB — so a 27th lane stays distinguishable instead of wrapping onto A.
    static func letter(at index: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard index >= alphabet.count else { return String(alphabet[index]) }
        let (quotient, remainder) = (index / alphabet.count, index % alphabet.count)
        return String(alphabet[quotient - 1]) + String(alphabet[remainder])
    }
}
