import Foundation

/// Whether the percentages in a published account snapshot came from a usable source now.
public enum UsageFreshness: String, Sendable, Equatable, Codable {
    case fresh
    case fallback
    case disconnected
}

/// A credential source associated with one provider-reported subscription identity.
public struct UsageAccountSource: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case owned
        case detected
    }

    public let kind: Kind
    public let reference: String
    public let isAvailable: Bool

    public init(kind: Kind, reference: String, isAvailable: Bool) {
        self.kind = kind
        self.reference = reference
        self.isAvailable = isAvailable
    }

    public var id: String { "\(kind.rawValue):\(reference)" }
}

/// The source selected for the account's currently published reading.
public enum UsageActiveAccountSource: String, Sendable, Equatable, Codable {
    case owned
    case detected
    case retained
}

/// Secret-free state used by Settings and by the engine availability gate.
public struct SubscriptionAccountSnapshot: Sendable, Equatable, Identifiable {
    public let integration: Integration
    public let account: UsageAccount
    public let key: UsageKey
    public let hasOwnedConnection: Bool
    public let freshness: UsageFreshness
    public let sources: [UsageAccountSource]
    public let lastReading: UsageSnapshot?
    public let status: String?

    public init(
        integration: Integration, account: UsageAccount, key: UsageKey,
        hasOwnedConnection: Bool, freshness: UsageFreshness,
        sources: [UsageAccountSource], lastReading: UsageSnapshot?, status: String?
    ) {
        self.integration = integration
        self.account = account
        self.key = key
        self.hasOwnedConnection = hasOwnedConnection
        self.freshness = freshness
        self.sources = sources
        self.lastReading = lastReading
        self.status = status
    }

    public var id: String { "\(integration.rawValue):\(account.id)" }
}

/// The browser-facing half of a pending OAuth login. The PKCE verifier and expected state stay in Core.
public struct SubscriptionLogin: Sendable {
    public let id: UUID
    public let authorizationURL: URL
    public let redirectURL: URL

    public init(id: UUID, authorizationURL: URL, redirectURL: URL) {
        self.id = id
        self.authorizationURL = authorizationURL
        self.redirectURL = redirectURL
    }
}

public enum SubscriptionAccountError: LocalizedError, Sendable, Equatable {
    case unsupportedIntegration
    case loginNotPending
    case invalidCallback
    case stateMismatch
    case providerRejectedLogin
    case tokenExchangeFailed
    case identityUnavailable
    case reconnectIdentityMismatch
    case accountNotFound
    case persistenceFailed
    case reconnectRequired

    public var errorDescription: String? {
        switch self {
        case .unsupportedIntegration: "This provider does not support subscription login."
        case .loginNotPending: "This login is no longer active."
        case .invalidCallback: "The login callback was invalid."
        case .stateMismatch: "The login callback did not match this request."
        case .providerRejectedLogin: "The provider did not complete the login."
        case .tokenExchangeFailed: "The provider could not complete the token exchange."
        case .identityUnavailable: "The provider did not return a subscription identity."
        case .reconnectIdentityMismatch: "Reconnect used a different subscription account."
        case .accountNotFound: "The subscription account no longer exists."
        case .persistenceFailed: "The subscription account could not be saved."
        case .reconnectRequired: "This connection must be reconnected."
        }
    }
}
