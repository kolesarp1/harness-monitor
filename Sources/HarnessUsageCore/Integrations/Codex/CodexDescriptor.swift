import Foundation

// Codex integration descriptor. Usage is the live ChatGPT backend meter when the CLI's
// stored login is readable and unexpired, falling back to the ~/.codex/sessions/**/*.jsonl rollout
// tail (which supplies today's token counts and cost either way).
struct CodexDescriptor: IntegrationDescriptor {
    var displayName: String { "Codex" }
    var reportsTokens: Bool { true }
    var homeRelativePath: String { ".codex" }
    var brandSVG: String { BrandSVG.codex }
    var brandColor: BrandColor { .rgb(0x54 / 255, 0x66 / 255, 0xFF / 255) }

    func makeMonitor(home: URL, account: AccountConfig) -> any IntegrationMonitor {
        if let alias = account.host.sshAlias {
            return RemoteMonitor(
                alias: alias,
                probe: remoteProbe(configDir: account.resolvedConfigDir(home: nil))!)
        }
        // nil for the default account leaves `CodexMonitor` reading $CODEX_HOME as it always has; a
        // named account pins its own root instead, because one CODEX_HOME cannot mean two logins.
        let root =
            account.account.isEmpty && account.configDir == nil
            ? nil
            : URL(fileURLWithPath: account.resolvedConfigDir(home: home), isDirectory: true)
        return CodexMonitor(home: home, codexRoot: root)
    }

    // The same endpoint and account header as `CodexUsageClient`, run on the account's own machine.
    // `ChatGPT-Account-Id` matters here as much as locally: without it the endpoint answers for the
    // token's default workspace, which for a login that belongs to several is the wrong meter.
    func remoteProbe(configDir: String) -> RemoteProbe? {
        let dir = RemoteScript.remotePath(configDir)
        let script = """
            set -u
            f=\(dir)/auth.json
            [ -r "$f" ] || { echo "ERR no readable login at \(configDir)"; exit 0; }
            tok=$(\(RemoteScript.jsonField("access_token", file: "\"$f\"")))
            acct=$(\(RemoteScript.jsonField("account_id", file: "\"$f\"")))
            idtok=$(\(RemoteScript.jsonField("id_token", file: "\"$f\"")))
            [ -n "$tok" ] || { echo 'ERR the login on this host has no access token'; exit 0; }
            email=$(\(RemoteScript.jwtEmail("\"$idtok\"")))
            [ -z "$email" ] || echo "ACCOUNT $email"
            \(
                RemoteScript.curlWithHeaders(
                    url: CodexUsageClient.endpoint.absoluteString,
                    headers: [
                        "Authorization: Bearer $tok",
                        "ChatGPT-Account-Id: $acct",
                        "User-Agent: HarnessUsage/remote",
                    ]))
            """
        return RemoteProbe(script: script) { data, now in
            CodexUsageClient.snapshot(fromResponseData: data, now: now)
        }
    }
}
