import Foundation

// Where one account's files live. A harness signed in on another machine is read over SSH, using the
// alias from the user's own `~/.ssh/config` — the app never learns a hostname, a key or a password.
public enum AccountHost: Sendable, Equatable, Hashable {
    case local
    case ssh(String)  // an ssh_config alias, e.g. "sunny-new"

    public var sshAlias: String? {
        if case .ssh(let alias) = self { return alias }
        return nil
    }

    public var isRemote: Bool { sshAlias != nil }
}

// One tracked account, as configured in `~/.harness-usage/accounts.json`.
//
// Nothing here is a credential. An account names a MACHINE and a CONFIG DIRECTORY; the harness's own
// login inside that directory is what the monitors read, exactly as they always have.
public struct AccountConfig: Sendable, Equatable {
    public var harness: Harness
    /// Stable slug, unique within the harness. Empty = this machine's default login.
    public var account: String
    /// What the user reads next to the brand mark. Empty for a harness with a single account.
    public var label: String
    public var host: AccountHost
    /// The harness's config directory. nil = that harness's own default for the host
    /// (`~/.claude`, `~/.codex`). A leading `~` is expanded against the RELEVANT home — this Mac's for
    /// a local account, the remote login's for an SSH one — so one spelling works on both.
    public var configDir: String?
    /// The account slug whose login this operational ring monitors. nil means this ring's own
    /// login; an empty string names the default account for this harness. This is an assignment
    /// only — it never changes a provider's login or copies a credential.
    public var usageSource: String?

    public init(
        harness: Harness, account: String = "", label: String = "", host: AccountHost = .local,
        configDir: String? = nil, usageSource: String? = nil
    ) {
        self.harness = harness
        self.account = account
        self.label = label
        self.host = host
        self.configDir = configDir
        self.usageSource = usageSource
    }

    public var integration: Integration { Integration(harness: harness, account: account) }

    /// A slug is a filesystem- and key-safe token: it names a settings key and a cache directory, and
    /// `#` would collide with `Integration.rawValue`'s own separator.
    public static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            && slug.allSatisfy(\.isASCII)
    }

    /// This account's config directory on ITS OWN machine, as an absolute POSIX path.
    /// `home` is that machine's home directory — this Mac's for a local account; for a remote one the
    /// caller passes nil and the remote shell expands `~` itself.
    public func resolvedConfigDir(home: URL?) -> String {
        let raw = configDir ?? "~/\(harness.descriptor.homeRelativePath)"
        guard raw.hasPrefix("~") else { return raw }
        guard let home else { return raw }  // remote: leave the ~ for the remote shell
        return home.path + String(raw.dropFirst())
    }

    /// Where this account's caches and parse indexes live, under `~/.harness-usage/`. Per account, so
    /// two logins of one harness cannot overwrite each other's usage cache.
    public var cacheDirName: String {
        account.isEmpty ? harness.rawValue : "\(harness.rawValue)-\(account)"
    }

    /// The login profile assigned to this operational ring. Invalid or missing assignments safely
    /// fall back to the ring's own configured login.
    public func source(in accounts: [AccountConfig]) -> AccountConfig {
        guard let usageSource,
            let source = accounts.first(where: {
                $0.harness == harness && $0.account == usageSource
            })
        else { return self }
        return source
    }
}

// The accounts this app tracks, and the one place anything asks "what rings exist".
//
// Loaded once, lazily, from `~/.harness-usage/accounts.json` — a global `let`, thread-safe by the
// language, and immutable for the run. Editing the file and relaunching is how an account is added;
// nothing in the app writes it back, so a hand-edited file is never reformatted or overwritten.
//
// Every pure function in Core takes its account list as a parameter instead of reading this, so the
// tests never touch the user's home directory. Only the app's composition root and `displayName` read
// the global.
public enum Accounts {
    public static let configuredURL: URL =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".harness-usage/accounts.json")

    public static let configured: [AccountConfig] =
        AccountsFile.load(at: configuredURL) ?? AccountsFile.defaults

    /// Every tracked account's key, in the file's own order.
    public static var all: [Integration] { configured.map(\.integration) }

    public static func config(for integration: Integration) -> AccountConfig? {
        configured.first { $0.integration == integration }
    }

    /// The account's label, blank when its harness has only one account — a lone Claude is just
    /// "Claude", however the file labels it, so a single-account install reads exactly as before.
    public static func label(for integration: Integration) -> String {
        label(for: integration, in: configured)
    }

    static func label(for integration: Integration, in accounts: [AccountConfig]) -> String {
        guard accounts.filter({ $0.harness == integration.harness }).count > 1,
            let config = accounts.first(where: { $0.integration == integration })
        else { return "" }
        return config.label
    }
}
