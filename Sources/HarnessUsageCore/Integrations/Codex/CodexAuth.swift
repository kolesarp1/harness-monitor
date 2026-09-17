import Foundation

// Reads the Codex CLI's OAuth access token and account identity from `auth.json`, READ-ONLY. Nothing here writes, and
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
        public let expiresAt: Date?  // the JWT `exp` claim, when the token is a readable JWT
        public let identityId: String?
        public let name: String?
        public let email: String?
        public let plan: String?

        public init(
            accessToken: String, accountId: String?, expiresAt: Date?, identityId: String? = nil,
            name: String? = nil, email: String? = nil, plan: String? = nil
        ) {
            self.accessToken = accessToken
            self.accountId = accountId
            self.expiresAt = expiresAt
            self.identityId = identityId
            self.name = name
            self.email = email
            self.plan = plan
        }

        public func isExpired(now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }

        // Account switches must clear retained meters even when the old token still works. Prefer the
        // stable account/user claim; an unusual token without identity falls back to the token itself.
        var loginIdentity: String { accountId ?? accessToken }

        func usageAccount(profile: CodexProfile) -> UsageAccount? {
            guard let id = accountId else { return nil }
            let proposal = UsageAccount.automaticName(
                reportedName: name, email: email, fallback: profile.name ?? "Codex")
            return UsageAccount(
                id: id, email: email, plan: plan, location: profile.location,
                suggestedName: proposal)
        }
    }

    private struct Root: Decodable {
        let tokens: Tokens?
    }
    private struct Tokens: Decodable {
        let idToken: String?
        let accessToken: String?
        let accountId: String?
        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }

    // `auth.json` under the default profile — never a second CODEX_HOME implementation.
    public static func read(home: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> Token? {
        read(profile: .standard(home: home, environment: env))
    }

    public static func read(profile: CodexProfile) -> Token? {
        guard let data = FileManager.default.contents(atPath: profile.authFile.path) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Token? {
        guard let tokens = try? JSONDecoder().decode(Root.self, from: data).tokens,
            let access = tokens.accessToken, !access.isEmpty
        else { return nil }
        let identity = tokens.idToken.flatMap(decodeIdentity)
        let accountId = nonEmpty(tokens.accountId) ?? identity?.accountId
        return Token(
            accessToken: access, accountId: accountId, expiresAt: decodeExpiry(fromJWT: access),
            identityId: accountId,
            name: identity?.name, email: identity?.email, plan: planLabel(identity?.plan))
    }

    // The `exp` claim out of a JWT's payload segment. base64url is base64 with `-`/`_` swapped in and
    // the `=` padding stripped — restoring that padding is the whole trick, and getting it wrong
    // returns nil for every real token, silently disabling the live tier.
    static func decodeExpiry(fromJWT token: String) -> Date? {
        guard let json = decodePayload(fromJWT: token), let exp = (json["exp"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private struct Identity {
        let accountId: String?
        let userId: String?
        let name: String?
        let email: String?
        let plan: String?
    }

    private static func decodeIdentity(fromJWT token: String) -> Identity? {
        guard let json = decodePayload(fromJWT: token) else { return nil }
        let profile = json["https://api.openai.com/profile"] as? [String: Any]
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        return Identity(
            accountId: nonEmpty(auth?["chatgpt_account_id"] as? String),
            userId: nonEmpty(auth?["chatgpt_user_id"] as? String) ?? nonEmpty(auth?["user_id"] as? String),
            name: nonEmpty(json["name"] as? String) ?? nonEmpty(profile?["name"] as? String),
            email: nonEmpty(json["email"] as? String) ?? nonEmpty(profile?["email"] as? String),
            plan: nonEmpty(auth?["chatgpt_plan_type"] as? String))
    }

    private static func decodePayload(fromJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func planLabel(_ raw: String?) -> String? { planDisplayName(raw) }

    // Mirrors Codex's current PlanType vocabulary and labels. Matching is case-insensitive so a
    // capitalized value from an older persisted reading gets the same label without a migration.
    static func planDisplayName(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        switch value.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro 20x"
        case "prolite", "pro lite": return "Pro 5x"
        case "team": return "Team"
        case "self_serve_business_prolite": return "Self Serve Business ProLite"
        case "self_serve_business_usage_based": return "Self Serve Business Usage Based"
        case "business": return "Business"
        case "ent26": return "Enterprise"
        case "enterprise_cbp_automation": return "Enterprise (Automation)"
        case "enterprise_cbp_usage_based": return "Enterprise CBP Usage Based"
        case "enterprise", "hc": return "Enterprise"
        case "education", "edu": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        default: return fallbackPlanDisplayName(value)
        }
    }
}
