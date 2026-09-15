import AppKit
import Foundation
import HarnessUsageCore

// A user-initiated remote CLI login. Unlike usage probes this deliberately allocates a TTY: both
// vendors' login commands may print a device URL/code then wait for browser approval. Only stdout is
// shown; no credential material is parsed, persisted, or returned to the app.
@MainActor @Observable final class RemoteLogin {
    private var process: Process?
    private var outputHandle: FileHandle?
    private var inputHandle: FileHandle?
    var output = ""
    var isRunning = false

    func start(account: AccountConfig) {
        guard let host = account.host.sshAlias, !isRunning else { return }
        output = "Starting \(account.harness.descriptor.displayName) sign-in on \(host)…\n"
        isRunning = true

        let configDir = RemoteScript.remotePath(account.configDir ?? "~/\(account.harness.descriptor.homeRelativePath)")
        let command: String
        switch account.harness {
        case .claude:
            command = "export CLAUDE_CONFIG_DIR=\(configDir); exec claude auth login --claudeai"
        case .codex:
            command = "export CODEX_HOME=\(configDir); mkdir -p \"$CODEX_HOME\"; exec codex login --device-auth"
        default:
            output += "Remote sign-in is available for Claude and Codex only."
            isRunning = false
            return
        }
        let script = """
            set -u
            export PATH="$HOME/.nvm/versions/node/v22.23.2/bin:$HOME/.local/bin:$PATH"
            export TERM=dumb
            command -v \(account.harness == .claude ? "claude" : "codex") >/dev/null || { echo 'CLI not found on remote host'; exit 127; }
            \(command)
            """
        // With `ssh -tt`, remote stdin is a pseudo-terminal. Feeding the script through that
        // terminal leaves `bash source /dev/stdin` waiting for an EOF that never arrives. Pass a
        // base64-encoded script as an SSH command instead; `eval` retains the TTY as stdin for the
        // CLI's interactive device/browser login flow.
        let encodedScript = Data(script.utf8).base64EncodedString()
        let remoteCommand = "stty -echo; eval \"$(printf '%s' \(encodedScript) | base64 -d)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // A TTY is necessary for vendor login flows, but it would echo our stdin script back into
        // the Settings transcript. Disable echo before bash starts, and use a clean shell so a
        // server's interactive profile cannot attach a tmux/herdr session instead of the CLI.
        process.arguments = [
            "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, remoteCommand,
        ]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.output += text }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.outputHandle?.readabilityHandler = nil
                try? self?.inputHandle?.close()
                self?.output += "\nRemote login exited (\(process.terminationStatus))."
                self?.isRunning = false
                self?.process = nil
                self?.inputHandle = nil
            }
        }
        do {
            try process.run()
            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            outputHandle = outputPipe.fileHandleForReading
        } catch {
            output += "Could not start remote login: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func cancel() { process?.terminate() }

    /// Sends a response directly to the active remote CLI. The value is neither appended to the
    /// transcript nor stored in settings.
    func submit(_ response: String) {
        guard isRunning, !response.isEmpty else { return }
        do {
            try inputHandle?.write(contentsOf: Data((response + "\n").utf8))
        } catch {
            output += "\nCould not send response: \(error.localizedDescription)"
        }
    }

    var browserURL: URL? {
        let pattern = #"https?://[^\s<>\"]+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(output[range]))
    }
}
