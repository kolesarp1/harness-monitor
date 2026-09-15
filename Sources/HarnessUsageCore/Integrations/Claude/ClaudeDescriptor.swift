import Foundation

// Claude integration descriptor: everything intrinsic about Claude owned in its own folder. Usage comes
// from the OAuth endpoint, falling back to the local token estimate.
struct ClaudeDescriptor: IntegrationDescriptor {
    var displayName: String { "Claude" }
    var reportsTokens: Bool { true }
    var homeRelativePath: String { ".claude" }
    var brandSVG: String { BrandSVG.claude }
    var brandColor: BrandColor { .rgb(0xD9 / 255, 0x77 / 255, 0x57 / 255) }

    func makeMonitor(home: URL, account: AccountConfig) -> any IntegrationMonitor {
        if let alias = account.host.sshAlias {
            return RemoteMonitor(
                alias: alias,
                probe: remoteProbe(configDir: account.resolvedConfigDir(home: nil))!)
        }
        // Per account, so two logins cannot overwrite each other's usage cache or parse index.
        let base = home.appendingPathComponent(".harness-usage/\(account.cacheDirName)")
        let configDir = URL(fileURLWithPath: account.resolvedConfigDir(home: home), isDirectory: true)
        return ClaudeMonitor(
            claudeHome: configDir,
            cacheURL: base.appendingPathComponent("usage-cache.json"),
            home: home,
            // nil for the default account keeps `ClaudeCredentials` on its unsuffixed Keychain item
            // and its existing env-var override — the pre-accounts behaviour, bit for bit.
            configDir: account.account.isEmpty && account.configDir == nil ? nil : configDir,
            runSecurity: ClaudeCredentials.securityCLIReader())
    }

    // The same endpoint, beta header and user agent as `ClaudeOAuthUsage`, run on the account's own
    // machine. The token is read out of that machine's credentials file and never leaves it — on
    // Linux Claude Code keeps the blob in `<configDir>/.credentials.json`, which is why a remote
    // account needs no Keychain equivalent.
    func remoteProbe(configDir: String) -> RemoteProbe? {
        let dir = RemoteScript.remotePath(configDir)
        let script = """
            set -u
            f=\(dir)/.credentials.json
            [ -r "$f" ] || { echo "ERR no readable login at \(configDir)"; exit 0; }
            tok=$(\(RemoteScript.jsonField("accessToken", file: "\"$f\"")))
            [ -n "$tok" ] || { echo 'ERR the login on this host has no access token'; exit 0; }
            # Claude keeps account identity separately from the credentials, in the config root's
            # profile file. Return only the email, never the token or account UUID.
            profile=\(dir)/.claude.json
            if [ -r "$profile" ]; then
              email=$(\(RemoteScript.jsonField("emailAddress", file: "\"$profile\"")))
              [ -z "$email" ] || echo "ACCOUNT $email"
            fi
            email=$(\(RemoteScript.jwtEmail("\"$tok\"")))
            [ -z "$email" ] || echo "ACCOUNT $email"
            \(
                RemoteScript.curlWithHeaders(
                    url: ClaudeOAuthUsage.endpoint.absoluteString,
                    headers: [
                        "Authorization: Bearer $tok",
                        "anthropic-beta: \(ClaudeOAuthUsage.betaHeader)",
                        "User-Agent: \(ClaudeOAuthUsage.userAgent)",
                    ]))
            """
        return RemoteProbe(script: script) { data, now in
            ClaudeOAuthUsage.snapshot(fromResponseData: data, now: now)
        }
    }
}
