import CommonCrypto
import Foundation

// One Claude Code login on this Mac. Claude Code keeps its login inside a config folder — `~/.claude`,
// or whatever `CLAUDE_CONFIG_DIR` names — and `/login` replaces the one login a folder holds, so a second
// account can only be signed in at the same time from a second folder. A profile is that folder, and
// everything read for it follows from the folder:
//  - who is signed in: `oauthAccount` in `~/.claude.json` for the default folder, `<dir>/.claude.json` for
//    any other;
//  - the token: `<dir>/.credentials.json`, then the Keychain item Claude Code names after the folder.
public struct ClaudeProfile: Sendable, Equatable {
    /// nil for `~/.claude`; "work" for `~/.claude-work`. The profile a reading is published under.
    public let name: String?
    public let directory: URL
    public let stateFile: URL

    private static let folderPrefix = ".claude-"

    public var credentialsFile: URL { directory.appendingPathComponent(".credentials.json") }
    public var projectsDirectory: URL { directory.appendingPathComponent("projects") }
    /// Home-relative, for display: "~/.claude-work".
    public var location: String { "~/" + directory.lastPathComponent }

    // The default folder's item carries the bare service name. A folder passed through `CLAUDE_CONFIG_DIR`
    // gets "-" plus the first 8 hex digits of SHA-256 over the path as passed, NFC-normalised — read out
    // of Claude Code 2.1.270 itself. Claude Code hashes the string it was given, so the path is tried as
    // a shell hands it over: `~/.claude-work` and `"$HOME/.claude-work"` both arrive expanded, and a
    // trailing slash is the one variation typing leaves in.
    public var keychainServices: [String] {
        guard name != nil else { return [ClaudeCredentials.keychainService] }
        return [directory.path, directory.path + "/"].map { "\(ClaudeCredentials.keychainService)-\(Self.hashPrefix($0))" }
    }

    public static func standard(home: URL) -> ClaudeProfile {
        ClaudeProfile(
            name: nil, directory: home.appendingPathComponent(".claude"),
            stateFile: home.appendingPathComponent(".claude.json"))
    }

    public static func named(_ name: String, home: URL) -> ClaudeProfile {
        let directory = home.appendingPathComponent(folderPrefix + name)
        return ClaudeProfile(name: name, directory: directory, stateFile: directory.appendingPathComponent(".claude.json"))
    }

    // Every profile on this Mac: the default folder first, then each `~/.claude-<name>` folder that holds
    // a login, by name. The default is always listed — its folder is what detected Claude at all. Another
    // folder without an `oauthAccount` is not a profile: scratch config folders are common, and a ring for
    // one would only ever say there is no login.
    public static func discover(home: URL) -> [ClaudeProfile] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let signedIn =
            entries
            .filter { $0.hasPrefix(folderPrefix) && $0.count > folderPrefix.count }
            .map { ClaudeProfile.named(String($0.dropFirst(folderPrefix.count)), home: home) }
            .filter { ClaudeCredentials.account(stateFile: $0.stateFile) != nil }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        return [standard(home: home)] + signedIn
    }

    static func hashPrefix(_ path: String) -> String {
        let bytes = Array(path.precomposedStringWithCanonicalMapping.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
