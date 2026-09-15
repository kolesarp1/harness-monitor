import Foundation

public enum UsageSource: String, Sendable, Codable {
    case localEstimate  // auth-free token estimate, summed from the user's own on-disk transcripts
    case codexLocal  // Codex's own 5h/weekly rate-limit snapshot, read from ~/.codex rollout files
    case opencodeLocal  // opencode's per-session token columns (auth-free, no plan limit)
    case claudeOAuth  // Claude's real 5h/7-day usage %, read from the OAuth usage endpoint
    case cursorDashboard  // Cursor's monthly billing-cycle usage, read from its dashboard RPC
    case codexUsageAPI  // Codex's real 5h/weekly meters, read from the ChatGPT backend usage endpoint
}

// One metered window a provider reports. Nothing here is named after a plan shape: a provider
// publishes the windows it has and every surface renders the list, so a plan with one weekly cap,
// one with a 5h and a 7d, and one with a billing cycle need no Core concept of their own.
public struct UsageWindow: Equatable, Sendable, Identifiable, Codable {
    /// Stable across renames and restarts, assigned by the monitor, never parsed by Core. A stored
    /// scope points at this, so a provider that renames a cap must not change it.
    public let id: String
    public let title: String  // what the user reads
    public let utilization: Double  // always 0...100 — the init clamps, so the invariant lives in the type
    public let period: TimeInterval?  // window length when the provider reports one; nil sorts last
    public let resetsAt: Date?
    public let kind: Kind

    // Whether the cap binds the whole plan or one model, and which model. A model cap is hidden by
    // that provider's Extra switch, never leads the widget, and enters `.mostUrgent` only while the
    // switch is on — spending one blocks that model, not the account. The name rides along because
    // the Settings row has to say "Show Fable", and only the monitor knows what the model is called;
    // Core must not go parsing it back out of an id or a window title.
    public enum Kind: Sendable, Equatable, RawRepresentable, Codable {
        case account
        case model(String)

        private static let modelPrefix = "model:"

        public init?(rawValue: String) {
            if rawValue == "account" {
                self = .account
                return
            }
            let name = String(rawValue.dropFirst(Self.modelPrefix.count))
            guard rawValue.hasPrefix(Self.modelPrefix), !name.isEmpty else { return nil }
            self = .model(name)
        }

        public var rawValue: String {
            switch self {
            case .account: "account"
            case .model(let name): Self.modelPrefix + name
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let value = Kind(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid usage-window kind")
            }
            self = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var isAccount: Bool { self == .account }
        public var modelName: String? {
            if case .model(let name) = self { return name }
            return nil
        }
    }

    public init(
        id: String, title: String, utilization: Double, period: TimeInterval? = nil,
        resetsAt: Date? = nil, kind: Kind
    ) {
        self.id = id
        self.title = title
        self.utilization = min(100, max(0, utilization))
        self.period = period
        self.resetsAt = resetsAt
        self.kind = kind
    }
}

// Which reading a snapshot is: a harness, and which of its logins. Most harnesses keep one login per
// Mac and publish under `profile: nil`. Claude and Codex keep one login per config folder, so each
// extra folder signed in to an account publishes under its own profile name beside the default.
public struct UsageKey: Hashable, Sendable, Identifiable {
    public let integration: Integration
    public let profile: String?

    public init(_ integration: Integration, profile: String? = nil) {
        self.integration = integration
        self.profile = profile
    }

    /// "claude" for a default login, "claude:work" for a profile — the spelling the ring order persists.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let integration = Integration(rawValue: String(parts[0])) else { return nil }
        if parts.count == 2 {
            guard !parts[1].isEmpty else { return nil }
            self.init(integration, profile: String(parts[1]))
        } else {
            self.init(integration)
        }
    }

    public var rawValue: String { profile.map { "\(integration.rawValue):\($0)" } ?? integration.rawValue }
    public var id: String { rawValue }
}

// Who a reading belongs to, for a harness that says. Claude reads it from its state file and Codex
// from auth.json; harnesses that report none carry no identity line on their cards.
public struct UsageAccount: Equatable, Sendable, Codable {
    /// Stable identity of the login, and what a name the user gives it is stored against.
    public let id: String
    public let email: String?
    /// The provider's nonempty plan value. Presentation applies that integration's display policy.
    public let plan: String?
    /// Where the login lives, home-relative: "~/.claude", "~/.claude-work".
    public let location: String
    /// The automatic account name: subscription profile, email local part, then config folder/provider.
    public let suggestedName: String

    public init(id: String, email: String?, plan: String?, location: String, suggestedName: String) {
        self.id = id
        self.email = email
        self.plan = plan
        self.location = location
        self.suggestedName = suggestedName
    }

    // New accounts name themselves from the subscription profile, then the email's local part.
    // The config-folder/provider fallback covers tokens that expose neither.
    public static func automaticName(reportedName: String?, email: String?, fallback: String) -> String {
        if let name = reportedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let local = email?.split(separator: "@", maxSplits: 1).first.map(String.init), !local.isEmpty {
            return local
        }
        return fallback
    }
}

public struct UsageSnapshot: Equatable, Sendable, Codable {
    public var windows: [UsageWindow]
    public var localTokensToday: Int?
    // Tokens since the most recent local Monday 00:00 (`UsageMath.mostRecentMonday`) — a calendar week,
    // not a rolling 168 hours. Every provider that fills this uses that boundary, so one card cannot
    // print two different "this week"s.
    public var localTokensWeek: Int?
    public var source: UsageSource
    public var lastUpdated: Date
    // Today's input / output token split — the auth-free fallback the Usage widget renders as a
    // provider card when there are no real % meters. `todayInput`/`todayOutput` are the raw counts
    // each agent writes; the card's headline "Total" is their sum (cache excluded, so it tracks real
    // work, not the cache-read-inflated grand total). nil when the integration has no fallback data.
    public var todayInput: Int?
    public var todayOutput: Int?
    // `costTodayUSD` is a provider-precomputed real cost for today (opencode's `session.cost`).
    // `estimatedCostUSD` is OUR approximate "≈ API value" for today, derived from token splits × a
    // bundled price table — never labelled "spent". All nil when absent.
    public var costTodayUSD: Double?
    public var estimatedCostUSD: Double?
    // Why a provider could not deliver what it was asked for (an expired token, an unreachable
    // endpoint). Surfaced in Settings so a tier that silently never fires names itself.
    public var note: String?
    // The login these numbers belong to, when the harness names one.
    public var account: UsageAccount?
    // Explicit account state for rendering and source resolution. Existing monitor call sites default
    // to a current detected reading; the account resolver fills all three fields precisely.
    public var freshness: UsageFreshness
    public var activeAccountSource: UsageActiveAccountSource?
    public var accountSources: [UsageAccountSource]

    public init(
        windows: [UsageWindow], localTokensToday: Int?, localTokensWeek: Int?, source: UsageSource,
        lastUpdated: Date, todayInput: Int? = nil, todayOutput: Int? = nil,
        costTodayUSD: Double? = nil, estimatedCostUSD: Double? = nil, note: String? = nil,
        account: UsageAccount? = nil, freshness: UsageFreshness = .fresh,
        activeAccountSource: UsageActiveAccountSource? = .detected,
        accountSources: [UsageAccountSource] = []
    ) {
        self.windows = windows.enumerated()
            .sorted { a, b in
                let l = a.element.period ?? .infinity
                let r = b.element.period ?? .infinity
                return l == r ? a.offset < b.offset : l < r
            }
            .map(\.element)
        self.localTokensToday = localTokensToday
        self.localTokensWeek = localTokensWeek
        self.source = source
        self.lastUpdated = lastUpdated
        self.todayInput = todayInput
        self.todayOutput = todayOutput
        self.costTodayUSD = costTodayUSD
        self.estimatedCostUSD = estimatedCostUSD
        self.note = note
        self.account = account
        self.freshness = freshness
        self.activeAccountSource = activeAccountSource
        self.accountSources = accountSources
    }

    public func windows(includingExtras: Bool) -> [UsageWindow] {
        includingExtras ? windows : windows.filter { $0.kind.isAccount }
    }

    // The window that leads this provider: the shortest ACCOUNT cap, and where two are the same
    // length, the one further along. A model cap leads only when the provider reports no account
    // window at all — otherwise a dormant 0% model limit would take the headline while the meter the
    // plan actually spends sat underneath it.
    //
    // `includingExtras` is that provider's Extra switch, and it has to be honoured here: the one
    // comparator answers both the ring (through `UsageSelection.resolved`) and the card (through
    // `spotlightRows(showingExtras:)`), so a lead picked over the unfiltered list would let the ring quote a model cap
    // the card is not allowed to draw. Nil when the switch leaves nothing visible.
    public func primaryWindow(includingExtras: Bool) -> UsageWindow? {
        let visible = windows(includingExtras: includingExtras)
        return visible.filter { $0.kind.isAccount }
            .min {
                let l = $0.period ?? .infinity
                let r = $1.period ?? .infinity
                return l == r ? $0.utilization > $1.utilization : l < r
            } ?? visible.first
    }

    public var primaryWindow: UsageWindow? { primaryWindow(includingExtras: true) }

    public func spotlightRows(showingExtras: Bool) -> (hero: UsageWindow?, compact: [UsageWindow]) {
        guard let hero = primaryWindow(includingExtras: showingExtras) else { return (nil, []) }
        return (hero, windows(includingExtras: showingExtras).filter { $0.id != hero.id })
    }
}

public enum UsageLevel: Sendable { case safe, warn, critical }

public enum UsageStatus {
    // Thresholds are user-configurable (Settings.warningAt/criticalAt). If the user inverts them
    // (warning >= critical), swap so the bands stay sane: safe < warn < critical.
    public static func level(_ utilization: Double, warningAt: Double = 50, criticalAt: Double = 80) -> UsageLevel {
        let warn = min(warningAt, criticalAt)
        let crit = max(warningAt, criticalAt)
        switch utilization {
        case ..<warn: return .safe
        case ..<crit: return .warn
        default: return .critical
        }
    }
}
