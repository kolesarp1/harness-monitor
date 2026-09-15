import Foundation

// Reads the Codex CLI's OAuth access token from `auth.json`, READ-ONLY. Nothing here writes, and
// there is deliberately no refresh path: OpenAI's refresh tokens are single-use and rotated
// server-side, so refreshing behind the CLI's back can race its own rotation and invalidate the
// user's session. An expired token simply falls through to the rollout-file tier.
//
// Codex can also keep its auth in the Keychain rather than a file; that setup gets no live tier here
// and surfaces as the "No Codex login found" note rather than as silence.
public enum CodexAuth {
    public struct Token: Sendable, Equatable {
        public let accessToken: String
        public let accountId: String?
        public let accountEmail: String?
        public let expiresAt: Date?  // the JWT `exp` claim, when the token is a readable JWT

        public init(accessToken: String, accountId: String?, expiresAt: Date?, accountEmail: String? = nil) {
            self.accessToken = accessToken
            self.accountId = accountId
            self.expiresAt = expiresAt
            self.accountEmail = accountEmail
        }

        public func isExpired(now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
    }

    private struct Root: Decodable {
        let tokens: Tokens?
    }
    private struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?
        let idToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
            case idToken = "id_token"
        }
    }

    // `auth.json` under the root `CodexMonitor.codexRoot` resolves — never a second $CODEX_HOME
    // implementation, since that one already handles the comma-split and tilde expansion.
    public static func read(home: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> Token? {
        read(root: CodexMonitor.codexRoot(home: home, environment: env))
    }

    /// The login under one explicit config root. This is the per-account entry point: an account
    /// names its own root, and $CODEX_HOME has no say in it.
    public static func read(root: URL) -> Token? {
        let url = root.appendingPathComponent("auth.json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Token? {
        guard let tokens = try? JSONDecoder().decode(Root.self, from: data).tokens,
            let access = tokens.accessToken, !access.isEmpty
        else { return nil }
        return Token(
            accessToken: access, accountId: tokens.accountId, expiresAt: decodeExpiry(fromJWT: access),
            accountEmail: tokens.idToken.flatMap(AccountIdentity.email(fromJWT:)))
    }

    // The `exp` claim out of a JWT's payload segment. base64url is base64 with `-`/`_` swapped in and
    // the `=` padding stripped — restoring that padding is the whole trick, and getting it wrong
    // returns nil for every real token, silently disabling the live tier.
    static func decodeExpiry(fromJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = (json["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
