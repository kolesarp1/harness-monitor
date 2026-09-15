import Foundation
import HarnessUsageCore
import Testing

@testable import HarnessUsage
@testable import HarnessUsageCore

private final class LoginTransportStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let result = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: result.0, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func loginSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LoginTransportStub.self]
    return URLSession(configuration: configuration)
}

private func loginJWT(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    let payload = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

private func callbackRequest(for login: SubscriptionLogin) throws -> String {
    let state = try #require(
        URLComponents(url: login.authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value)
    return "GET \(login.redirectURL.path)?code=fake-code&state=\(state) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
}

@Suite("OAuth callback producer-consumer integration", .serialized)
struct OAuthCallbackIntegrationTests {
    @Test("Claude issued redirect survives listener parsing and Core validation")
    func claudeIssuedRedirectCompletes() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("callback-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        LoginTransportStub.handler = { request in
            if request.url?.path == "/v1/oauth/token" {
                return (200, Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8))
            }
            return (200, Data(#"{"account":{"uuid":"person"},"organization":{"uuid":"org"}}"#.utf8))
        }
        let store = SubscriptionAccountStore(
            home: home, providers: [.claude: ClaudeSubscriptionOAuth(session: loginSession())])
        let login = try await store.beginLogin(for: .claude)
        let parsed = try #require(
            OAuthCallbackListener.parse(request: callbackRequest(for: login), redirectURL: login.redirectURL))

        #expect(parsed.host == "localhost")
        #expect(try await store.completeLogin(login.id, callbackURL: parsed).id == "person/org")
    }

    @Test("Codex issued redirect survives listener parsing and Core validation")
    func codexIssuedRedirectCompletes() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("callback-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let access = try loginJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "workspace"]])
        let idToken = try loginJWT(["name": "Profile Name", "email": "profile@example.com"])
        LoginTransportStub.handler = { _ in
            (200, Data("{\"access_token\":\"\(access)\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"id_token\":\"\(idToken)\"}".utf8))
        }
        let store = SubscriptionAccountStore(
            home: home, providers: [.codex: CodexSubscriptionOAuth(session: loginSession())])
        let login = try await store.beginLogin(for: .codex)
        let parsed = try #require(
            OAuthCallbackListener.parse(request: callbackRequest(for: login), redirectURL: login.redirectURL))
        let account = try await store.completeLogin(login.id, callbackURL: parsed)

        #expect(parsed.host == "localhost")
        #expect(account.id == "workspace")
        #expect(account.email == "profile@example.com")
        #expect(account.suggestedName == "Profile Name")
    }
}
