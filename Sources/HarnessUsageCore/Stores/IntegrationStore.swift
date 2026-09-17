import Foundation

// Which of the configured accounts are actually present. Drives Settings availability (a
// not-detected account shows a disabled "Not detected" toggle) and gates the Engine. Refreshed on the
// main actor at launch and on a ~30s cadence — the probe is a few `fileExists` checks, cheap enough
// for the tick.
@MainActor @Observable public final class IntegrationStore {
    public var detected: Set<Integration>
    private let home: URL
    private let accounts: [AccountConfig]

    public init(home: URL, accounts: [AccountConfig] = AccountsFile.defaults, detected: Set<Integration> = []) {
        self.home = home
        self.accounts = accounts
        self.detected = detected
    }

    // Detection is "does this account's config directory exist on this Mac".
    //
    // A REMOTE account is always detected. Its directory is on another machine, and the only way to
    // answer the question would be an ssh round trip on the 30s detection sweep — for a fact the
    // monitor establishes anyway on its own next refresh, and reports as a note the user can read.
    // Configuring a remote account is itself the statement that it exists.
    public func refresh() {
        let fm = FileManager.default
        let found = Set(
            accounts.filter { account in
                let source = account.source(in: accounts)
                return source.host.isRemote
                    || fm.fileExists(atPath: source.resolvedConfigDir(home: home))
            }.map(\.integration))
        if found != detected { detected = found }  // only notify observers on an actual change
    }
}
