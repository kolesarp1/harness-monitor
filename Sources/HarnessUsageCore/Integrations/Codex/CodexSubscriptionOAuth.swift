import Foundation

struct CodexSubscriptionOAuth: SubscriptionOAuthProvider {
    let integration: Integration = .codex
    private let session: URLSession
    private let now: @Sendable () -> Date

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let redirectURL = URL(string: "http://localhost:1455/auth/callback")!

    init(session: URLSession? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session ?? UsageEndpoint.makeSession(requestTimeout: 30)
        self.now = now
    }

    func authorization(verifier: String, challenge: String, state: String) throws -> SubscriptionOAuthAuthorization {
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "pi"),
        ]
        guard let url = components?.url else { throw SubscriptionAccountError.tokenExchangeFailed }
        return SubscriptionOAuthAuthorization(authorizationURL: url, redirectURL: Self.redirectURL)
    }

    func exchange(code: String, verifier: String, state: String, redirectURL: URL) async throws -> SubscriptionOAuthCredential {
        try await tokenRequest([
            ("grant_type", "authorization_code"), ("client_id", Self.clientID), ("code", code),
            ("code_verifier", verifier), ("redirect_uri", redirectURL.absoluteString),
        ])
    }

    func refresh(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthCredential {
        try await tokenRequest([
            ("grant_type", "refresh_token"), ("refresh_token", credential.refreshToken),
            ("client_id", Self.clientID),
        ])
    }

    func identify(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthIdentity {
        guard let claims = Self.claims(credential.accessToken),
            let auth = claims["https://api.openai.com/auth"] as? [String: Any],
            let accountID = Self.nonEmpty(auth["chatgpt_account_id"] as? String)
                ?? Self.nonEmpty(claims["chatgpt_account_id"] as? String)
        else { throw SubscriptionAccountError.identityUnavailable }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let idClaims = credential.idToken.flatMap(Self.claims)
        let idProfile = idClaims?["https://api.openai.com/profile"] as? [String: Any]
        return SubscriptionOAuthIdentity(
            id: accountID,
            email: Self.nonEmpty(idClaims?["email"] as? String)
                ?? Self.nonEmpty(idProfile?["email"] as? String)
                ?? Self.nonEmpty(claims["email"] as? String) ?? Self.nonEmpty(profile?["email"] as? String),
            name: Self.nonEmpty(idClaims?["name"] as? String)
                ?? Self.nonEmpty(idProfile?["name"] as? String)
                ?? Self.nonEmpty(claims["name"] as? String) ?? Self.nonEmpty(profile?["name"] as? String),
            plan: Integration.codex.planDisplayName(auth["chatgpt_plan_type"] as? String), verified: true)
    }

    func usage(
        _ credential: SubscriptionOAuthCredential, identity: SubscriptionOAuthIdentity, now: Date
    ) async -> SubscriptionOAuthUsageOutcome {
        let token = CodexAuth.Token(
            accessToken: credential.accessToken, accountId: identity.id,
            expiresAt: credential.expiresAt, identityId: identity.id,
            name: identity.name, email: identity.email, plan: identity.plan)
        switch await CodexUsageClient.fetch(token: token, session: session, now: now) {
        case .ok(var snapshot):
            if let responseAccount = snapshot.account, responseAccount.id != identity.id { return .failed }
            let current = SubscriptionOAuthIdentity(
                id: identity.id, email: snapshot.account?.email ?? identity.email,
                name: identity.name, plan: snapshot.account?.plan ?? identity.plan, verified: true)
            snapshot.account = nil
            return .success(snapshot: snapshot, identity: current)
        case .unauthorized: return .unauthorized
        case .rateLimited(let until): return .rateLimited(until: until)
        case .failed: return .failed
        }
    }

    private func tokenRequest(_ values: [(String, String)]) async throws -> SubscriptionOAuthCredential {
        var request = URLRequest(url: Self.tokenURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = SubscriptionOAuthSecurity.form(values)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw SubscriptionOAuthTransportError.ambiguous }
        guard let http = response as? HTTPURLResponse else { throw SubscriptionOAuthTransportError.ambiguous }
        guard (200..<300).contains(http.statusCode) else { throw SubscriptionOAuthTransportError.rejected }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
            !decoded.accessToken.isEmpty, !decoded.refreshToken.isEmpty
        else { throw SubscriptionOAuthTransportError.ambiguous }
        return SubscriptionOAuthCredential(
            accessToken: decoded.accessToken, refreshToken: decoded.refreshToken,
            expiresAt: now().addingTimeInterval(decoded.expiresIn), idToken: decoded.idToken)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
        let idToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !value.count.isMultiple(of: 4) { value.append("=") }
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
