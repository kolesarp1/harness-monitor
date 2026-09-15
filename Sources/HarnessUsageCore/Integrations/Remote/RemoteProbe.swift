import Foundation

// One harness's live-meter query, as a script to run on the machine the account is signed in on.
//
// The shape is the point: the credential is read, used and discarded ON THAT MACHINE, and only the
// endpoint's JSON comes back. A probe may additionally return the login email claim, but no token,
// refresh token or account id ever crosses the ssh channel.
public struct RemoteProbe: Sendable {
    /// POSIX sh, fed to the remote shell on stdin. Prints the response body, then a final line
    /// holding the HTTP status — the shape `RemoteResponse.parse` expects.
    public let script: String
    /// Turns a 200 body into a snapshot. The same decoder the local tier uses, so a remote account's
    /// windows are built by exactly the code that builds a local one's.
    public let parse: @Sendable (Data, Date) -> UsageSnapshot?

    public init(script: String, parse: @escaping @Sendable (Data, Date) -> UsageSnapshot?) {
        self.script = script
        self.parse = parse
    }
}

// The body-plus-status envelope every probe script prints, split back apart here.
public enum RemoteResponse {
    public struct Parsed: Sendable, Equatable {
        public let status: Int?  // nil when the script failed before reaching the endpoint
        public let body: Data
        public let message: String?  // the script's own explanation, when it never got that far
        public let accountEmail: String?

        public init(status: Int?, body: Data, message: String?, accountEmail: String? = nil) {
            self.status = status
            self.body = body
            self.message = message
            self.accountEmail = accountEmail
        }
    }

    // The last non-empty line is the status, or `ERR <message>` when the script gave up early. Split
    // from the transport so every failure shape is testable without an ssh binary.
    public static func parse(_ output: String) -> Parsed {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let lastIndex = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return Parsed(status: nil, body: Data(), message: "no output from the remote host") }

        let last = lines[lastIndex].trimmingCharacters(in: .whitespaces)
        let responseLines = lines[lines.startIndex..<lastIndex]
        let accountEmail = responseLines.compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("ACCOUNT ") else { return nil }
            let email = String(value.dropFirst("ACCOUNT ".count))
            return email.contains("@") ? email : nil
        }.first
        let body = Data(
            responseLines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ACCOUNT ") }
                .joined(separator: "\n").utf8)

        if last.hasPrefix("ERR ") {
            return Parsed(status: nil, body: body, message: String(last.dropFirst(4)), accountEmail: accountEmail)
        }
        guard let status = Int(last) else {
            return Parsed(status: nil, body: Data(output.utf8), message: "unexpected output from the remote host", accountEmail: nil)
        }
        return Parsed(status: status, body: body, message: nil, accountEmail: accountEmail)
    }
}

// Shell fragments the probe scripts share.
public enum RemoteScript {
    /// A single-quoted POSIX shell literal. Every `'` is closed, escaped and reopened, so no input can
    /// end the quoting and become shell syntax — the one rule that keeps a config directory from the
    /// file being executable text on the remote host.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A path for the REMOTE shell, with a leading `~` expanded and everything else quoted.
    ///
    /// `quote` alone would be wrong here: single quotes are exactly what stops the shell expanding a
    /// tilde, so `'~/.claude-a'` names a directory called `~` rather than the remote login's home.
    /// The `~` becomes `"$HOME"` — expanded, but still quoted, so a home directory with a space in it
    /// stays one argument — and the remainder keeps its literal quoting.
    public static func remotePath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        guard path.hasPrefix("~/") else { return quote(path) }
        return "\"$HOME\"/" + quote(String(path.dropFirst(2)))
    }

    /// Pulls one string field out of a flat JSON object using only `tr`/`sed`, so a box with no
    /// python3 or jq still answers. Whitespace is stripped first, so the pattern need not model the
    /// formatting the harness happened to write.
    public static func jsonField(_ key: String, file: String) -> String {
        "tr -d ' \\n\\t\\r' < \(file) | sed -n 's/.*\"\(key)\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -1"
    }

    /// POSIX-shell decoder for a JWT's `email` claim. The two base64 flags cover GNU (remote Linux)
    /// and BSD implementations. Its sole output is the non-secret email string, never the token.
    public static func jwtEmail(_ token: String) -> String {
        """
        jwt_email() {
          payload=${1#*.}; payload=${payload%%.*}
          [ "$payload" != "$1" ] || return 0
          payload=$(printf %s "$payload" | tr '_-' '/+')
          case $((${#payload} % 4)) in 2) payload="${payload}==" ;; 3) payload="${payload}=" ;; esac
          decoded=$(printf %s "$payload" | base64 -d 2>/dev/null || printf %s "$payload" | base64 -D 2>/dev/null) || return 0
          printf %s "$decoded" | sed -n 's/.*"email":"\\([^" ]*\\)".*/\\1/p' | head -1
        }
        jwt_email \(token)
        """
    }

    /// `curl` with the credential headers passed through a private config file rather than argv. An
    /// argument list is world-readable via `ps` on the remote box; a 0600 file in the login's own temp
    /// dir is not. The file is removed on every exit path, including a failure mid-request.
    ///
    /// `headers` are heredoc lines, so shell variables set earlier in the script (`$tok`) expand into
    /// them. Values come out of JSON string fields, which cannot themselves contain the `"` that
    /// delimits a curl config value.
    ///
    /// Emits the body, then a newline, then the HTTP status — the envelope `RemoteResponse` splits.
    public static func curlWithHeaders(url: String, headers: [String]) -> String {
        """
        umask 077
        cfg=$(mktemp) || { echo 'ERR could not create a temp file on the remote host'; exit 0; }
        trap 'rm -f "$cfg"' EXIT HUP INT TERM
        cat > "$cfg" <<CURLCFG_END
        \(headers.map { #"header = "\#($0)""# }.joined(separator: "\n"))
        header = "Accept: application/json"
        CURLCFG_END
        curl -sS -m 25 --config "$cfg" -w '\\n%{http_code}' \(quote(url)) \\
          || { echo; echo 'ERR could not reach the endpoint'; }
        """
    }
}
