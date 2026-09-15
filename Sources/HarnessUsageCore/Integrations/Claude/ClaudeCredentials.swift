import CryptoKit
import Foundation

// Resolves Claude Code's OAuth access token, READ-ONLY. Nothing here writes or deletes a credential:
// there is no refresh path and no file write. An expired or rejected token falls through to the next
// usage tier and the real `claude` CLI refreshes it on its own schedule.
//
// Three sources, first non-empty wins: the CLAUDE_CODE_OAUTH_TOKEN environment variable, the
// credentials file, then the macOS Keychain. On macOS the file usually does NOT exist — Claude Code
// stores the blob in the Keychain — so the Keychain branch is the one that normally runs, and it is
// the branch that can raise a system prompt. The caller gates it.
//
// Each config directory has its OWN credential, which is what lets one Mac hold several Claude
// accounts at once: `~/.claude` and `CLAUDE_CONFIG_DIR=~/.claude-work` are separate logins with
// separate Keychain items. `keychainService(for:)` reproduces the CLI's own naming for those.
public enum ClaudeCredentials {
    public static let keychainService = "Claude Code-credentials"

    // Claude Code names the Keychain item for a non-default config directory by appending the first
    // 8 hex digits of the SHA-256 of the directory PATH, NFC-normalized:
    //
    //     `Claude Code-credentials`             the default ~/.claude
    //     `Claude Code-credentials-a1b2c3d4`    any CLAUDE_CONFIG_DIR
    //
    // It hashes the env var's value as the user set it, so a trailing slash or a relative spelling
    // hashes differently. `candidateServices` tries the plausible spellings rather than one.
    public static func keychainService(forConfigDir path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(keychainService)-\(hex)"
    }

    /// The Keychain services that could hold this config directory's credential, best first.
    ///
    /// `configDir` nil, or the default `~/.claude`, is the unsuffixed item — the CLI only suffixes
    /// when CLAUDE_CONFIG_DIR is actually set. For anything else we cannot know the exact string the
    /// user exported, so both the bare path and its trailing-slash spelling are tried; a miss costs
    /// one `security` call that returns "absent".
    public static func candidateServices(configDir: URL?, home: URL) -> [String] {
        guard let configDir else { return [keychainService] }
        let path = configDir.standardizedFileURL.path
        if path == home.appendingPathComponent(".claude").standardizedFileURL.path {
            return [keychainService]
        }
        return [keychainService(forConfigDir: path), keychainService(forConfigDir: path + "/")]
    }

    public struct Token: Sendable, Equatable {
        public let accessToken: String
        public let expiresAt: Date?
        public let accountEmail: String?

        public init(accessToken: String, expiresAt: Date?, accountEmail: String? = nil) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
            self.accountEmail = accountEmail
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
        let email: String?
    }

    // The blob both the file and the Keychain item hold: `{"claudeAiOauth": {...}}`. `expiresAt` is
    // in MILLISECONDS; read as seconds every token dates to 1970 and reads as permanently expired.
    public static func parse(_ data: Data) -> Token? {
        guard let oauth = try? JSONDecoder().decode(Root.self, from: data).claudeAiOauth,
            let access = oauth.accessToken, !access.isEmpty
        else { return nil }
        return Token(
            accessToken: access, expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            accountEmail: oauth.email ?? AccountIdentity.email(fromJWT: access))
    }

    // `configDir` is the account's Claude config directory; nil means this Mac's default `~/.claude`.
    //
    // CLAUDE_CODE_OAUTH_TOKEN is honoured for the DEFAULT account only. It is a single global
    // override with no notion of which login it belongs to, so letting it answer for every account
    // would give three rings one account's meters and quietly call them different.
    public static func resolve(
        home: URL,
        configDir: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        runSecurity: (@Sendable (String) async -> KeychainRead)? = nil
    ) async -> Resolution {
        if configDir == nil, let raw = env["CLAUDE_CODE_OAUTH_TOKEN"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .found(Token(accessToken: trimmed, expiresAt: nil)) }
        }
        let dir = configDir ?? home.appendingPathComponent(".claude")
        let file = dir.appendingPathComponent(".credentials.json")
        if let data = FileManager.default.contents(atPath: file.path), let token = parse(data) {
            return .found(token)
        }
        guard let runSecurity else { return .absent }

        // Each candidate spelling in turn. Only a definite answer stops the walk: an `absent` is just
        // "not under that name", and the next spelling may still hold the item. A failure is reported
        // rather than swallowed, since that is the branch a denied Keychain prompt lands in.
        var firstFailure: String?
        for service in candidateServices(configDir: configDir, home: home) {
            switch await runSecurity(service) {
            case .found(let data):
                guard let token = parse(data) else {
                    return .unavailable("Claude Keychain credentials are unreadable")
                }
                return .found(token)
            case .absent:
                continue
            case .failed(let reason):
                firstFailure = firstFailure ?? reason
            }
        }
        if let firstFailure { return .unavailable(firstFailure) }
        return .absent
    }

    // The default Keychain reader: `/usr/bin/security` as a subprocess rather than SecItemCopyMatching.
    // The CLI holds a stable, user-grantable ACL entry on the item that survives Harness Usage being
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
