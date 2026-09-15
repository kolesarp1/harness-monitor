import Foundation

// The Claude integration: the real usage meters from the OAuth endpoint with the local token estimate
// underneath, refreshed on an internal 15s floor. `claudeHome` is this account's config directory —
// `~/.claude` for the default login, or whatever CLAUDE_CONFIG_DIR the account uses — where Claude
// Code writes the transcripts the token estimate streams.
public actor ClaudeMonitor: IntegrationMonitor {
    private let claudeHome: String
    private let usage: ClaudeUsageProvider

    // `configDir` is the account's Claude config directory, and nil means "this Mac's default
    // login" — which keeps `ClaudeCredentials` on its unsuffixed Keychain item and its
    // CLAUDE_CODE_OAUTH_TOKEN override. `claudeHome` is the same directory: it is where the
    // transcripts are, and for a non-default account the two are always the same path.
    public init(
        claudeHome: URL, cacheURL: URL, home: URL, configDir: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        runSecurity: (@Sendable (String) async -> ClaudeCredentials.KeychainRead)? = nil
    ) {
        self.claudeHome = claudeHome.path
        self.usage = ClaudeUsageProvider(
            cacheURL: cacheURL, home: home, configDir: configDir, now: now, runSecurity: runSecurity)
    }

    // Projects holds the transcripts the local token estimate streams. The OAuth endpoint is
    // time-driven, so only transcript writes need to wake this monitor immediately.
    public nonisolated var watchPaths: [URL] {
        [URL(fileURLWithPath: claudeHome).appendingPathComponent("projects")]
    }

    public func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        await usage.refresh(force: false, wantEstimate: wantUsageEstimate)
    }

    public func invalidateThrottles() async {
        await usage.invalidateThrottles()
    }
}
