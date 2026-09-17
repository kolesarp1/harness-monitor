import Foundation
import Testing

@testable import HarnessUsageCore

private final class OAuthTransportStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1_024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                captured.httpBody = data
            }
            Self.requests.append(captured)
            let result = try Self.handler?(captured) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: result.0, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private func oauthSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OAuthTransportStub.self]
    return URLSession(configuration: configuration)
}

private func oauthJWT(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    let payload = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

@Suite(.serialized) struct SubscriptionOAuthTests {
    // Defect: copying Codex's form encoding into Claude, or omitting state from Claude's JSON exchange.
    @Test func claudeUsesReferenceJSONEncodingAndVerifiedProfileIdentity() async throws {
        OAuthTransportStub.requests = []
        OAuthTransportStub.handler = { request in
            switch request.url?.path {
            case "/v1/oauth/token":
                return (200, Data(#"{"access_token":"owned-access","refresh_token":"owned-refresh","expires_in":3600}"#.utf8))
            case "/api/oauth/profile":
                return (200, Data(#"{"account":{"uuid":"person-1","email_address":"a@example.com","display_name":"Alex"},"organization":{"uuid":"org-2","rate_limit_tier":"prolite"}}"#.utf8))
            default: return (404, Data())
            }
        }
        let provider = ClaudeSubscriptionOAuth(session: oauthSession(), now: { Date(timeIntervalSince1970: 1_000) })
        let authorization = try provider.authorization(verifier: "verifier", challenge: "challenge", state: "state")
        let credential = try await provider.exchange(
            code: "code", verifier: "verifier", state: "state", redirectURL: authorization.redirectURL)
        let identity = try await provider.identify(credential)

        let exchange = try #require(OAuthTransportStub.requests.first)
        #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let exchangeBody = try #require(exchange.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: exchangeBody) as? [String: String])
        #expect(body["state"] == "state")
        #expect(body["code_verifier"] == "verifier")
        #expect(identity.id == "person-1/org-2")
        #expect(identity.plan == "Prolite")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 4_300))
        #expect(OAuthTransportStub.requests[1].value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    // Defect: using JSON for Codex, dropping its account header identity, or leaking raw `prolite`.
    @Test func codexUsesReferenceFormEncodingAndPreservesPlanSpelling() async throws {
        let access = try oauthJWT([
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "workspace-9", "chatgpt_plan_type": "prolite",
            ]
        ])
        let idToken = try oauthJWT(["email": "codex@example.com", "name": "Codex Person"])
        OAuthTransportStub.requests = []
        OAuthTransportStub.handler = { _ in
            (200, Data("{\"access_token\":\"\(access)\",\"refresh_token\":\"refresh-1\",\"expires_in\":3600,\"id_token\":\"\(idToken)\"}".utf8))
        }
        let provider = CodexSubscriptionOAuth(session: oauthSession(), now: { Date(timeIntervalSince1970: 2_000) })
        let authorization = try provider.authorization(verifier: "verify me", challenge: "challenge", state: "csrf")
        let credential = try await provider.exchange(
            code: "code/value", verifier: "verify me", state: "csrf", redirectURL: authorization.redirectURL)
        let identity = try await provider.identify(credential)
        let request = try #require(OAuthTransportStub.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(body.contains("code=code%2Fvalue"))
        #expect(body.contains("code_verifier=verify%20me"))
        #expect(identity.id == "workspace-9")
        #expect(identity.name == "Codex Person")
        #expect(identity.email == "codex@example.com")
        #expect(identity.plan == "Pro 5x")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 5_600))
    }

    // Defect: refresh silently retaining the old rotating refresh token.
    @Test func bothProviderRefreshesPersistTheRotatedTokenFromTheirOwnEncoding() async throws {
        var isClaude = true
        OAuthTransportStub.handler = { request in
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            if isClaude {
                #expect(contentType == "application/json")
                isClaude = false
            } else {
                #expect(contentType == "application/x-www-form-urlencoded")
            }
            return (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }
        let old = SubscriptionOAuthCredential(
            accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
        let claude = try await ClaudeSubscriptionOAuth(session: oauthSession(), now: { .distantFuture }).refresh(old)
        let codex = try await CodexSubscriptionOAuth(session: oauthSession(), now: { .distantFuture }).refresh(old)
        #expect(claude.refreshToken == "new-refresh")
        #expect(codex.refreshToken == "new-refresh")
    }
}
