import Foundation

// `~/.harness-usage/accounts.json` — the one file that says which accounts the app tracks.
//
// It is seeded once, on a first launch that finds no file, with one local default account per
// harness: exactly the shape the app had before accounts existed. The Settings window may update an
// existing entry's host; account creation and removal remain deliberately file-managed.
//
// Parsing is deliberately forgiving per ENTRY and strict per FILE: one malformed account is dropped
// with a note on stderr rather than taking its siblings with it, but an unreadable or entry-less file
// falls back to the defaults instead of leaving the app with no rings at all.
public enum AccountsFile {
    /// One local default account per harness — what a fresh install tracks, and the fallback whenever
    /// the file is missing or yields nothing usable.
    public static let defaults: [AccountConfig] = Harness.allCases.map { AccountConfig(harness: $0) }

    /// The default accounts as keys — one bare harness each, which is exactly what `Integration`
    /// enumerated before accounts existed. The hermetic default for anything that takes an account
    /// list, so a test or a preview never reads the user's own file.
    public static let defaultKeys: [Integration] = defaults.map(\.integration)

    private struct Root: Decodable {
        let accounts: [Entry]?
    }

    private struct Entry: Decodable {
        let harness: String
        let account: String?
        let label: String?
        let host: String?
        let configDir: String?
        let usageSource: String?
    }

    public static func load(at url: URL) -> [AccountConfig]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return parse(data, warn: { warn("\(url.path): \($0)") })
    }

    // Split from `load` so the tests drive every malformed shape without touching a real file.
    static func parse(_ data: Data, warn: (String) -> Void = { _ in }) -> [AccountConfig]? {
        guard let root = try? JSONDecoder().decode(Root.self, from: data), let entries = root.accounts
        else {
            warn("not a readable accounts file — falling back to the default accounts")
            return nil
        }

        var accounts: [AccountConfig] = []
        var seen = Set<Integration>()
        for entry in entries {
            guard let harness = Harness(rawValue: entry.harness) else {
                warn("unknown harness \"\(entry.harness)\" — entry ignored")
                continue
            }
            let slug = entry.account ?? ""
            guard slug.isEmpty || AccountConfig.isValidSlug(slug) else {
                warn("invalid account slug \"\(slug)\" for \(entry.harness) — entry ignored")
                continue
            }
            let host: AccountHost
            if let alias = entry.host?.trimmingCharacters(in: .whitespaces), !alias.isEmpty {
                // The alias reaches an `ssh` argument list. Anything outside an ssh_config host name
                // is either a mistake or an attempt to smuggle options in, and both are refused here
                // rather than handed to the shell.
                guard isValidSSHAlias(alias) else {
                    warn("invalid ssh host \"\(alias)\" for \(entry.harness) — entry ignored")
                    continue
                }
                host = .ssh(alias)
            } else {
                host = .local
            }
            let config = AccountConfig(
                harness: harness, account: slug, label: entry.label ?? "", host: host,
                configDir: entry.configDir?.isEmpty == true ? nil : entry.configDir,
                usageSource: entry.usageSource)
            // A repeated key would put two rings under one identity, which is not a state SwiftUI has
            // an answer for — the same rule `providerOrder` applies on the way in.
            guard seen.insert(config.integration).inserted else {
                warn("duplicate account \"\(config.integration.rawValue)\" — later entry ignored")
                continue
            }
            accounts.append(config)
        }
        // An assignment may only point at another configured profile of the same harness. It is
        // deliberately not followed recursively: every account remains a reusable login profile.
        for index in accounts.indices {
            guard let source = accounts[index].usageSource else { continue }
            let hasSource = accounts.contains { candidate in
                candidate.harness == accounts[index].harness && candidate.account == source
            }
            guard hasSource else {
                warn(
                    "unknown usage source \"\(source)\" for \(accounts[index].integration.rawValue) — using its own login")
                accounts[index].usageSource = nil
                continue
            }
        }
        guard !accounts.isEmpty else {
            warn("no usable accounts — falling back to the default accounts")
            return nil
        }
        return accounts
    }

    // An ssh_config alias: a host token, not a shell fragment and not an `-o` option smuggled in as a
    // name. Leading `-` is refused for that reason.
    static func isValidSSHAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 255, !alias.hasPrefix("-") else { return false }
        return alias.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Write the seed file if there isn't one. Never overwrites: a file the user has edited, or one a
    /// future schema wrote, is left exactly as it is.
    @discardableResult
    public static func seedIfAbsent(at url: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return false }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(seedDocument.utf8).write(to: url, options: .atomic)) != nil
    }

    /// Update only an existing account's source machine. `nil` makes it local; a non-nil value must
    /// be an ssh_config host token or an IP address (both are safe ssh arguments). The document is
    /// decoded generically so its version and explanatory comment fields survive the edit.
    @discardableResult
    public static func setHost(_ host: String?, for integration: Integration, at url: URL) -> Bool {
        let cleaned = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, !cleaned.isEmpty, !isValidSSHAlias(cleaned) { return false }
        guard let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var entries = root["accounts"] as? [[String: Any]]
        else { return false }

        guard
            let index = entries.firstIndex(where: {
                ($0["harness"] as? String) == integration.harness.rawValue
                    && ($0["account"] as? String ?? "") == integration.account
            })
        else { return false }

        if let cleaned, !cleaned.isEmpty {
            entries[index]["host"] = cleaned
        } else {
            entries[index].removeValue(forKey: "host")
        }
        root["accounts"] = entries
        guard JSONSerialization.isValidJSONObject(root),
            let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? output.write(to: url, options: .atomic)) != nil
    }

    /// Update an account's harness configuration directory. This path is interpreted on the selected
    /// machine, so one subscription can use `~/.claude-a` while another uses `~/.claude-b`.
    @discardableResult
    public static func setConfigDir(_ configDir: String?, for integration: Integration, at url: URL) -> Bool {
        let cleaned = configDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned?.contains("\n") != true,
            let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var entries = root["accounts"] as? [[String: Any]],
            let index = entries.firstIndex(where: {
                ($0["harness"] as? String) == integration.harness.rawValue
                    && ($0["account"] as? String ?? "") == integration.account
            })
        else { return false }
        if let cleaned, !cleaned.isEmpty {
            entries[index]["configDir"] = cleaned
        } else {
            entries[index].removeValue(forKey: "configDir")
        }
        root["accounts"] = entries
        guard JSONSerialization.isValidJSONObject(root),
            let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? output.write(to: url, options: .atomic)) != nil
    }

    /// Assign an operational ring to one of its harness's configured login profiles. Passing the
    /// ring's own account slug (or nil for the default ring) clears the assignment.
    @discardableResult
    public static func setUsageSource(
        _ source: Integration, for integration: Integration, at url: URL
    ) -> Bool {
        guard source.harness == integration.harness,
            let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var entries = root["accounts"] as? [[String: Any]],
            let targetIndex = entries.firstIndex(where: {
                ($0["harness"] as? String) == integration.harness.rawValue
                    && ($0["account"] as? String ?? "") == integration.account
            }),
            entries.contains(where: {
                ($0["harness"] as? String) == source.harness.rawValue
                    && ($0["account"] as? String ?? "") == source.account
            })
        else { return false }

        if source.account == integration.account {
            entries[targetIndex].removeValue(forKey: "usageSource")
        } else {
            entries[targetIndex]["usageSource"] = source.account
        }
        root["accounts"] = entries
        guard JSONSerialization.isValidJSONObject(root),
            let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? output.write(to: url, options: .atomic)) != nil
    }

    /// Append a new subscription with a stable, unused account slug. Its source starts local; the
    /// newly created Settings pane lets the user choose a remote host and token location.
    public static func addSubscription(harness: Harness, at url: URL) -> AccountConfig? {
        guard let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var entries = root["accounts"] as? [[String: Any]]
        else { return nil }
        let used = Set(
            entries.compactMap { entry -> String? in
                guard entry["harness"] as? String == harness.rawValue else { return nil }
                return entry["account"] as? String ?? ""
            })
        var number = 2
        var slug = "\(harness.rawValue)-\(number)"
        while used.contains(slug) {
            number += 1
            slug = "\(harness.rawValue)-\(number)"
        }
        let label = "\(harness.descriptor.displayName) \(number)"
        entries.append(["harness": harness.rawValue, "account": slug, "label": label])
        root["accounts"] = entries
        guard JSONSerialization.isValidJSONObject(root),
            let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
            (try? output.write(to: url, options: .atomic)) != nil
        else { return nil }
        return AccountConfig(harness: harness, account: slug, label: label)
    }

    /// Remove one configured subscription, preserving at least one entry for its harness so a
    /// mistaken click cannot leave a provider with no configuration at all.
    @discardableResult
    public static func removeSubscription(_ integration: Integration, at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var entries = root["accounts"] as? [[String: Any]],
            entries.filter({ ($0["harness"] as? String) == integration.harness.rawValue }).count > 1,
            let index = entries.firstIndex(where: {
                ($0["harness"] as? String) == integration.harness.rawValue
                    && ($0["account"] as? String ?? "") == integration.account
            })
        else { return false }
        entries.remove(at: index)
        // Slots assigned to a deleted profile safely resume monitoring their own login. Leaving a
        // dangling reference would make the JSON's intent differ from the live fallback behaviour.
        let dependents = entries.indices.filter { remainingIndex in
            (entries[remainingIndex]["harness"] as? String) == integration.harness.rawValue
                && (entries[remainingIndex]["usageSource"] as? String) == integration.account
        }
        for remainingIndex in dependents {
            entries[remainingIndex].removeValue(forKey: "usageSource")
        }
        root["accounts"] = entries
        guard JSONSerialization.isValidJSONObject(root),
            let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? output.write(to: url, options: .atomic)) != nil
    }

    // Commented so the file explains itself when opened — this is the whole UI for adding an account.
    static let seedDocument = """
        {
          "version": 1,

          "_comment": [
            "The accounts Harness Usage tracks. One entry = one ring on the notch.",
            "Edit this file and relaunch the app to add, remove or rename an account.",
            "",
            "  harness    claude | codex | cursor | opencode",
            "  account    stable slug, unique per harness. Omit for this Mac's default login.",
            "             Changing it resets that ring's settings, so pick one and keep it.",
            "  label      shown next to the brand mark, e.g. Claude \\u00b7 Work.",
            "             Ignored while a harness has only one account.",
            "  host       an alias from your ~/.ssh/config, for an account signed in on",
            "             another machine. Omit for this Mac.",
            "  configDir  the harness's config directory, e.g. ~/.claude-work. Omit for the",
            "             default (~/.claude, ~/.codex). ~ expands on the account's OWN machine.",
            "  usageSource account slug whose login this ring monitors; omit for its own login.",
            "",
            "A remote account reports its live meters only: the query runs over ssh ON that",
            "machine and only the resulting percentages come back, so the token never leaves it.",
            "Local token/cost estimates need the transcripts, which stay where they are."
          ],

          "accounts": [
            { "harness": "claude",   "label": "Personal" },
            { "harness": "codex",    "label": "Personal" },
            { "harness": "cursor"   },
            { "harness": "opencode" }
          ]
        }

        """

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("HarnessUsage: accounts — \(message)\n".utf8))
    }
}
