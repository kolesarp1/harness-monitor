import Foundation

// Runs a probe script on another machine over SSH.
//
// Deliberately thin, and deliberately not a general remote-execution facility. It uses the system
// `ssh` with the user's own `~/.ssh/config`, so the alias, the key, the jump host and the tailnet
// address are all configuration the user already owns and the app never parses. `BatchMode=yes` is
// the load-bearing flag: a host that would prompt for a passphrase or an unknown host key FAILS
// rather than hanging a background refresh on a dialog nobody is looking at.
//
// The script arrives on stdin (`bash -s`), never as an argument, so nothing about it is visible in
// the remote `ps` output.
public struct RemoteShell: Sendable {
    public enum Outcome: Sendable, Equatable {
        case ok(String)  // the script's stdout
        case failed(String)  // a reason fit to put in a provider note
    }

    public let alias: String
    public let connectTimeout: Int
    public let deadline: Duration

    public init(alias: String, connectTimeout: Int = 10, deadline: Duration = .seconds(45)) {
        self.alias = alias
        self.connectTimeout = connectTimeout
        self.deadline = deadline
    }

    // ssh's own exit codes are ambiguous — 255 is "ssh itself failed", anything else is the remote
    // command's status — so the message names which half gave up. Anything the remote script wants to
    // say for itself it says on stdout as an `ERR` line, which the caller parses.
    public func run(_ script: String) async -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
            alias, "bash -s",
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let collected = LockedBox<(out: Data, err: Data)>((Data(), Data()))
        let drained = DispatchGroup()

        do {
            try process.run()
        } catch {
            return .failed("could not start ssh: \(error.localizedDescription)")
        }

        // Write the script and close stdin so the remote `bash -s` reaches EOF and runs.
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Drain both pipes while ssh runs: waiting on termination first deadlocks as soon as the
        // child writes more than a pipe buffer, and a usage payload comfortably can.
        for (pipe, isOut) in [(stdout, true), (stderr, false)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                collected.mutate {
                    if isOut {
                        $0.out += data
                    } else {
                        $0.err += data
                    }
                }
                drained.leave()
            }
        }

        // A remote box that accepts the connection and then goes silent must not pin the refresh.
        let watchdog = Task {
            try? await Task.sleep(for: deadline)
            if process.isRunning { process.terminate() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                drained.wait()
                continuation.resume()
            }
        }
        watchdog.cancel()

        let value = collected.value
        let out = String(decoding: value.out, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let err =
                String(decoding: value.err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            if process.terminationStatus == 255 {
                return .failed(err.isEmpty ? "could not reach \(alias) over ssh" : "\(alias): \(err)")
            }
            // Non-255 means the remote shell ran and failed. Its stdout may still hold the `ERR` line
            // the script meant us to read, so hand it back rather than discarding it for a status.
            return out.isEmpty ? .failed(err.isEmpty ? "\(alias): remote command failed" : "\(alias): \(err)") : .ok(out)
        }
        return .ok(out)
    }
}

// A lock-protected box for the two pipe readers. `NSLock` rather than an actor: these run on
// arbitrary GCD queues and cannot await.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}
