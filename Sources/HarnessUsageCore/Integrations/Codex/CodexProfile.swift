import Foundation

// One Codex login on this Mac. Codex keeps both its login and its rollout files under CODEX_HOME,
// defaulting to `~/.codex`; a second account therefore needs a second home such as `~/.codex-work`.
public struct CodexProfile: Sendable, Equatable {
    /// nil for the default CODEX_HOME; "work" for `~/.codex-work`.
    public let name: String?
    public let directory: URL
    private let userHome: URL

    private static let folderPrefix = ".codex-"

    public var authFile: URL { directory.appendingPathComponent("auth.json") }
    public var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    /// Home-relative when possible, for display: "~/.codex-work".
    public var location: String {
        let homePath = userHome.standardizedFileURL.path
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~/" + String(path.dropFirst(homePath.count + 1))
    }

    public static func standard(
        home: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodexProfile {
        CodexProfile(name: nil, directory: defaultDirectory(home: home, environment: environment), userHome: home)
    }

    public static func named(_ name: String, home: URL) -> CodexProfile {
        CodexProfile(
            name: name, directory: home.appendingPathComponent(folderPrefix + name, isDirectory: true),
            userHome: home)
    }

    // The default home is always present so signed-out and local-rollout states still report why they
    // have no live meter. Extra homes need a readable login; otherwise scratch `.codex-*` directories
    // would each add a ring that can only say "No Codex login found".
    public static func discover(
        home: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [CodexProfile] {
        let standard = standard(home: home, environment: environment)
        let standardPath = standard.directory.standardizedFileURL.path
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let signedIn =
            entries
            .filter { $0.hasPrefix(folderPrefix) && $0.count > folderPrefix.count }
            .map { named(String($0.dropFirst(folderPrefix.count)), home: home) }
            .filter { $0.directory.standardizedFileURL.path != standardPath && CodexAuth.read(profile: $0) != nil }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        return [standard] + signedIn
    }

    // Kept in one place so the rollout and auth readers cannot disagree about CODEX_HOME. The first
    // comma-separated value preserves the app's existing resolver behavior.
    static func defaultDirectory(home: URL, environment: [String: String]) -> URL {
        if let raw = environment["CODEX_HOME"], let first = raw.split(separator: ",").first {
            let path = (first.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }
}
