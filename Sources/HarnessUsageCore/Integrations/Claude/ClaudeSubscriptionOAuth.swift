import Foundation

struct ClaudeSubscriptionOAuth: SubscriptionOAuthProvider {
    let integration: Integration = .claude
    private let session: URLSession
    private let now: @Sendable () -> Date

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let redirectURL = URL(string: "http://localhost:53692/callback")!
    private static let scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    init(session: URLSession? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session ?? UsageEndpoint.makeSession(requestTimeout: 30)
        self.now = now
    }

    func authorization(verifier: String, challenge: String, state: String) throws -> SubscriptionOAuthAuthorization {
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw SubscriptionAccountError.tokenExchangeFailed }
        return SubscriptionOAuthAuthorization(authorizationURL: url, redirectURL: Self.redirectURL)
    }

    func exchange(code: String, verifier: String, state: String, redirectURL: URL) async throws -> SubscriptionOAuthCredential {
        try await tokenRequest([
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code,
            "state": state, "redirect_uri": redirectURL.absoluteString, "code_verifier": verifier,
        ])
    }

    func refresh(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthCredential {
        try await tokenRequest([
            "grant_type": "refresh_token", "client_id": Self.clientID,
            "refresh_token": credential.refreshToken,
        ])
    }

    func identify(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthIdentity {
        var request = URLRequest(url: Self.profileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeOAuthUsage.betaHeader, forHTTPHeaderField: "anthropic-beta")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw SubscriptionOAuthTransportError.ambiguous }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SubscriptionOAuthTransportError.rejected
        }
        guard let profile = ClaudeProfileResponse.parse(data), let accountID = profile.accountID,
            let organizationID = profile.organizationID
        else { throw SubscriptionAccountError.identityUnavailable }
        return SubscriptionOAuthIdentity(
            id: "\(accountID)/\(organizationID)", email: profile.email, name: profile.name,
            plan: Integration.claude.planDisplayName(profile.plan), verified: true)
    }

    func usage(
        _ credential: SubscriptionOAuthCredential, identity: SubscriptionOAuthIdentity, now: Date
    ) async -> SubscriptionOAuthUsageOutcome {
        let token = ClaudeCredentials.Token(accessToken: credential.accessToken, expiresAt: credential.expiresAt)
        switch await ClaudeOAuthUsage.fetch(token: token, session: session, now: now) {
        case .ok(let snapshot): return .success(snapshot: snapshot, identity: identity)
        case .unauthorized: return .unauthorized
        case .rateLimited(let until): return .rateLimited(until: until)
        case .failed: return .failed
        }
    }

    private func tokenRequest(_ body: [String: String]) async throws -> SubscriptionOAuthCredential {
        var request = URLRequest(url: Self.tokenURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw SubscriptionOAuthTransportError.ambiguous }
        guard let http = response as? HTTPURLResponse else { throw SubscriptionOAuthTransportError.ambiguous }
        guard (200..<300).contains(http.statusCode) else { throw SubscriptionOAuthTransportError.rejected }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
            !decoded.accessToken.isEmpty, !decoded.refreshToken.isEmpty
        else { throw SubscriptionOAuthTransportError.ambiguous }
        return SubscriptionOAuthCredential(
            accessToken: decoded.accessToken, refreshToken: decoded.refreshToken,
            expiresAt: now().addingTimeInterval(max(0, decoded.expiresIn - 300)))
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
}

private struct ClaudeProfileResponse {
    let accountID: String?
    let organizationID: String?
    let email: String?
    let name: String?
    let plan: String?

    static func parse(_ data: Data) -> ClaudeProfileResponse? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        func value(_ objects: [[String: Any]?], _ keys: [String]) -> String? {
            for object in objects.compactMap({ $0 }) {
                for key in keys {
                    guard let raw = object[key] as? String else { continue }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        return ClaudeProfileResponse(
            accountID: value([account, root], ["uuid", "accountUuid", "account_uuid"]),
            organizationID: value([organization, root], ["uuid", "organizationUuid", "organization_uuid"]),
            email: value([account, root], ["emailAddress", "email_address", "email"]),
            name: value([account, root], ["displayName", "display_name", "name", "fullName", "full_name"]),
            plan: value([organization, root], ["rateLimitTier", "rate_limit_tier", "organizationType", "organization_type", "plan"])
        )
    }
}
