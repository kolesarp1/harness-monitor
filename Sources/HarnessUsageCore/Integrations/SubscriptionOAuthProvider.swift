import CommonCrypto
import Foundation

struct SubscriptionOAuthCredential: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var idToken: String?

    init(accessToken: String, refreshToken: String, expiresAt: Date, idToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.idToken = idToken
    }
}

struct SubscriptionOAuthIdentity: Codable, Sendable, Equatable {
    var id: String
    var email: String?
    var name: String?
    var plan: String?
    var verified: Bool
}

struct SubscriptionOAuthAuthorization: Sendable {
    let authorizationURL: URL
    let redirectURL: URL
}

enum SubscriptionOAuthUsageOutcome: Sendable {
    case success(snapshot: UsageSnapshot, identity: SubscriptionOAuthIdentity)
    case unauthorized
    case rateLimited(until: Date?)
    case failed
}

enum SubscriptionOAuthTransportError: Error, Sendable {
    case rejected
    case ambiguous
}

protocol SubscriptionOAuthProvider: Sendable {
    var integration: Integration { get }
    func authorization(verifier: String, challenge: String, state: String) throws -> SubscriptionOAuthAuthorization
    func exchange(code: String, verifier: String, state: String, redirectURL: URL) async throws -> SubscriptionOAuthCredential
    func refresh(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthCredential
    func identify(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthIdentity
    func usage(_ credential: SubscriptionOAuthCredential, identity: SubscriptionOAuthIdentity, now: Date) async -> SubscriptionOAuthUsageOutcome
}

enum SubscriptionOAuthSecurity {
    static func randomToken(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        let bytes = Array(verifier.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return base64URL(Data(digest))
    }

    static func form(_ values: [(String, String)]) -> Data {
        Data(
            values.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

func fallbackPlanDisplayName(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    return raw.prefix(1).uppercased() + raw.dropFirst()
}
