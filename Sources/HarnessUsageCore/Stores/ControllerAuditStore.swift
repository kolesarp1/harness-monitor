import Foundation

/// A local record of controller actions. Entries contain profile keys and remote backup IDs only;
/// the credential files themselves stay on the SSH host.
public struct ControllerAuditStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public enum Action: String, Codable, Sendable { case exchange, copy, restore }

    public struct Entry: Codable, Sendable, Equatable {
        public let date: Date
        public let action: Action
        public let host: String
        public let first: Integration
        public let second: Integration
        public let succeeded: Bool
        public let backupID: UUID?
        public let restoredFrom: UUID?

        public init(
            action: Action, host: String, first: Integration, second: Integration,
            succeeded: Bool, backupID: UUID? = nil, restoredFrom: UUID? = nil,
            date: Date = Date()
        ) {
            self.date = date
            self.action = action
            self.host = host
            self.first = first
            self.second = second
            self.succeeded = succeeded
            self.backupID = backupID
            self.restoredFrom = restoredFrom
        }
    }

    @discardableResult
    public func append(_ entry: Entry) -> Bool {
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
            return true
        } catch { return false }
    }

    public func latestRestorableBackup(host: String, first: Integration, second: Integration) -> UUID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let entries = data.split(separator: 10).compactMap {
            try? JSONDecoder().decode(Entry.self, from: Data($0))
        }
        let matching = entries.filter {
            $0.host == host && $0.first == first && $0.second == second
        }
        let restored = Set(
            matching.compactMap {
                $0.action == .restore && $0.succeeded ? $0.restoredFrom : nil
            })
        return matching.reversed().first {
            ($0.action == .exchange || $0.action == .copy)
                && $0.backupID.map { !restored.contains($0) } == true
        }?.backupID
    }
}
