import Foundation

// Resolves Claude Code's OAuth access token, READ-ONLY. Nothing here writes or deletes a credential:
// there is no refresh path and no file write. An expired or rejected token falls through to the next
// usage tier and the real `claude` CLI refreshes it on its own schedule.
//
// Three sources, first non-empty wins: the CLAUDE_CODE_OAUTH_TOKEN environment variable (default profile
// only), the profile's credentials file, then the macOS Keychain. On macOS the file usually does NOT
// exist — Claude Code stores the blob in the Keychain item `Claude Code-credentials`, suffixed per config
// folder (see `ClaudeProfile`) — so the Keychain branch is the one that normally runs, and it is the
// branch that can raise a system prompt. The caller gates it.
public enum ClaudeCredentials {
    public static let keychainService = "Claude Code-credentials"

    public struct Token: Sendable, Equatable {
        public let accessToken: String
        public let expiresAt: Date?

        public init(accessToken: String, expiresAt: Date?) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
        }
    }

    public enum KeychainRead: Sendable {
        case found(Data)
        case absent
        case failed(String)
    }

    public enum Resolution: Sendable {
        case found(Token)
        case absent
        case unavailable(String)
    }

    private struct Root: Decodable { let claudeAiOauth: OAuth? }
    private struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?  // milliseconds since epoch, not seconds
    }

    // The blob both the file and the Keychain item hold: `{"claudeAiOauth": {...}}`. `expiresAt` is
    // in MILLISECONDS; read as seconds every token dates to 1970 and reads as permanently expired.
    public static func parse(_ data: Data) -> Token? {
        guard let oauth = try? JSONDecoder().decode(Root.self, from: data).claudeAiOauth,
            let access = oauth.accessToken, !access.isEmpty
        else { return nil }
        return Token(accessToken: access, expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    private struct State: Decodable { let oauthAccount: StateAccount? }
    private struct StateAccount: Decodable {
        let accountUuid: String?
        let organizationUuid: String?
        let displayName: String?
        let fullName: String?
        let emailAddress: String?
        let organizationType: String?
        let organizationRateLimitTier: String?
    }

    public struct Account: Sendable, Equatable {
        /// Account and org together: plans are org-scoped, so one person's personal and team logins are
        /// two accounts.
        public let id: String
        public let name: String?
        public let email: String?
        public let plan: String?
        public let identityComplete: Bool
    }

    // Who is signed in to a profile, from its state file. Claude Code rewrites `oauthAccount` on every
    // login, so a change here is an account switch even while the previous account's token is still
    // accepted. nil when logged out or unreadable.
    public static func account(stateFile: URL) -> Account? {
        guard let data = FileManager.default.contents(atPath: stateFile.path),
            let account = try? JSONDecoder().decode(State.self, from: data).oauthAccount,
            let uuid = account.accountUuid, !uuid.isEmpty
        else { return nil }
        let name = nonEmpty(account.displayName) ?? nonEmpty(account.fullName)
        let email = account.emailAddress.flatMap { $0.isEmpty ? nil : $0 }
        let organizationID = account.organizationUuid.flatMap(nonEmpty)
        return Account(
            id: [uuid, organizationID].compactMap { $0 }.joined(separator: "/"), name: name,
            email: email,
            plan: planLabel(tier: account.organizationRateLimitTier, organizationType: account.organizationType),
            identityComplete: organizationID != nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // The rate tier is more specific (`default_claude_max_5x`), while organization type covers
    // plans whose tier does not carry a multiplier. Unknown values remain visible.
    static func planLabel(tier: String?, organizationType: String?) -> String? {
        planDisplayName(tier) ?? planDisplayName(organizationType)
    }

    static func planDisplayName(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let normalized = value.lowercased()
        if normalized.hasSuffix("max_20x") { return "Max 20x" }
        if normalized.hasSuffix("max_5x") { return "Max 5x" }
        switch normalized {
        case "max", "claude_max", "default_claude_max": return "Max"
        case "pro", "claude_pro", "default_claude_pro": return "Pro"
        case "team", "claude_team", "default_claude_team", "default_claude_team_5x": return "Team"
        case "enterprise", "claude_enterprise", "default_claude_enterprise": return "Enterprise"
        default: return fallbackPlanDisplayName(value)
        }
    }

    public static func resolve(
        home: URL,
        env: [String: String] = ProcessInfo.processInfo.environment,
        runSecurity: (@Sendable (String) async -> KeychainRead)? = nil
    ) async -> Resolution {
        await resolve(profile: .standard(home: home), env: env, runSecurity: runSecurity)
    }

    public static func resolve(
        profile: ClaudeProfile,
        env: [String: String] = ProcessInfo.processInfo.environment,
        runSecurity: (@Sendable (String) async -> KeychainRead)? = nil
    ) async -> Resolution {
        // The variable is how a CI box or a shell hands one token over; it has no folder, so it can only
        // speak for the default login.
        if profile.name == nil, let raw = env["CLAUDE_CODE_OAUTH_TOKEN"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .found(Token(accessToken: trimmed, expiresAt: nil)) }
        }
        if let data = FileManager.default.contents(atPath: profile.credentialsFile.path), let token = parse(data) {
            return .found(token)
        }
        guard let runSecurity else { return .absent }
        // A missing spelling is answered without a dialog, so trying the next one costs one spawn. A failed
        // read is remembered rather than returned at once: a later spelling may still hold the token.
        var failure: String?
        for service in profile.keychainServices {
            switch await runSecurity(service) {
            case .found(let data):
                guard let token = parse(data) else { return .unavailable("Claude Keychain credentials are unreadable") }
                return .found(token)
            case .absent:
                continue
            case .failed(let reason):
                failure = failure ?? reason
            }
        }
        return failure.map(Resolution.unavailable) ?? .absent
    }

    // The default Keychain reader: `/usr/bin/security` as a subprocess rather than SecItemCopyMatching.
    // The CLI holds a stable, user-grantable ACL entry on the item that survives Harness Monitor being
    // re-signed, where an in-process read re-prompts on every signature change. Capped so a dialog the
    // user leaves open cannot pin the caller: the process is terminated at the deadline.
    public static func securityCLIReader(timeout: Duration = .milliseconds(1500))
        -> @Sendable (String) async -> KeychainRead
    {
        { service in
            await withCheckedContinuation { (continuation: CheckedContinuation<KeychainRead, Never>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", service, "-w"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                let resumed = LockedFlag()
                let output = LockedData()
                let readerFinished = DispatchGroup()
                readerFinished.enter()
                let finish: @Sendable (KeychainRead) -> Void = { value in
                    guard resumed.claim() else { return }
                    continuation.resume(returning: value)
                }

                process.terminationHandler = { proc in
                    readerFinished.wait()
                    let data = output.value
                    if proc.terminationStatus == 44 {
                        finish(.absent)
                    } else if proc.terminationStatus != 0 {
                        finish(.failed("Keychain lookup failed (security exit \(proc.terminationStatus))"))
                    } else {
                        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if text.isEmpty {
                            finish(.absent)
                        } else {
                            finish(.found(Data(text.utf8)))
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    readerFinished.leave()
                    finish(.failed("Could not start Keychain lookup: \(error.localizedDescription)"))
                    return
                }

                // Read while `security` runs. Waiting for termination before draining the pipe can
                // deadlock when the child writes more than the pipe buffer.
                DispatchQueue.global(qos: .utility).async {
                    output.replace((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                    readerFinished.leave()
                }

                Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning { process.terminate() }
                    finish(.failed("Keychain lookup timed out"))
                }
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data { lock.withLock { data } }

    func replace(_ value: Data) {
        lock.withLock { data = value }
    }
}

// A one-shot claim, so a continuation with two possible resume paths (process exit, timeout) resumes
// exactly once. `NSLock` rather than an actor: the termination handler is a synchronous callback on an
// arbitrary thread and cannot await.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
