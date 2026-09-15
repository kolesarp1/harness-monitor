import Darwin
import Foundation

// The loopback half of app-owned OAuth. RFC 8252 requires a loopback redirect and exact redirect-URI
// matching. Core still validates the complete callback; this listener preserves the issued URI's
// scheme/host/port/path while accepting the socket only on 127.0.0.1.
final class OAuthCallbackListener: @unchecked Sendable {
    // Security policy: OAuth redirects are header-only GETs. Cap headers at 32 KiB and the whole read
    // at 10 seconds. A 100 ms poll slice makes stop observable while an accepted peer sends nothing.
    // These are local denial-of-service bounds, not provider/network retry policy.
    private static let maxHeaderBytes = 32_768
    private static let readDeadline: TimeInterval = 10
    private static let pollMilliseconds: Int32 = 100

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var finished = false
    private var handler: (@Sendable (URL) -> Void)?

    var isListening: Bool { lock.withLock { listenFD >= 0 } }
    var hasAcceptedClient: Bool { lock.withLock { clientFD >= 0 } }

    func start(
        redirectURL: URL, expectedState: String,
        onCallback: @escaping @Sendable (URL) -> Void
    ) throws {
        guard redirectURL.scheme == "http", redirectURL.host?.lowercased() == "localhost",
            let port = redirectURL.port, (1...Int(UInt16.max)).contains(port),
            redirectURL.path.hasPrefix("/")
        else { throw OAuthCallbackListenerError.bindFailed("The provider returned an invalid local redirect URL.") }

        lock.withLock {
            handler = onCallback
            finished = false
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthCallbackListenerError.bindFailed("Could not open a local socket.") }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let occupied = errno == EADDRINUSE
            close(fd)
            throw OAuthCallbackListenerError.portOccupied(
                occupied
                    ? "Port \(port) is already in use — another login may be waiting. Close it and try again."
                    : "Could not listen on local port \(port).")
        }
        guard listen(fd, 5) == 0 else {
            close(fd)
            throw OAuthCallbackListenerError.bindFailed("Could not listen on local port \(port).")
        }
        lock.withLock { listenFD = fd }
        let thread = Thread { [weak self] in
            self?.acceptLoop(fd: fd, redirectURL: redirectURL, expectedState: expectedState)
        }
        thread.name = "harness-usage-oauth-callback"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        let sockets: (listen: Int32, client: Int32) = lock.withLock {
            finished = true
            handler = nil
            let sockets = (listenFD, clientFD)
            listenFD = -1
            return sockets
        }
        // The connection thread retains close ownership, preventing the descriptor number from being
        // reused under its pending poll/recv. shutdown wakes that work; release closes it once.
        if sockets.client >= 0 { _ = shutdown(sockets.client, SHUT_RDWR) }
        Self.closeSocket(sockets.listen)
    }

    private func acceptLoop(fd: Int32, redirectURL: URL, expectedState: String) {
        defer { stop() }
        while !lock.withLock({ finished }) {
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let connection = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &peerLen) }
            }
            if connection < 0 { return }
            guard register(connection) else {
                Self.closeSocket(connection)
                return
            }
            handleConnection(connection, redirectURL: redirectURL, expectedState: expectedState)
            release(connection)
        }
    }

    private func register(_ fd: Int32) -> Bool {
        lock.withLock {
            guard !finished else { return false }
            clientFD = fd
            return true
        }
    }

    private func release(_ fd: Int32) {
        let ownsSocket = lock.withLock {
            guard clientFD == fd else { return false }
            clientFD = -1
            return true
        }
        if ownsSocket { Self.closeSocket(fd) }
    }

    private func handleConnection(_ connection: Int32, redirectURL: URL, expectedState: String) {
        // Darwin's SO_NOSIGPIPE prevents a browser disconnect during the tiny response from killing
        // the process. poll bounds both idle reads and stop latency before recv is attempted.
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var raw = Data()
        raw.reserveCapacity(2048)
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(Self.readDeadline)
        while raw.count < Self.maxHeaderBytes, Date() < deadline, !lock.withLock({ finished }) {
            var descriptor = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            if descriptor.revents & Int16(POLLIN) == 0 { return }
            let count = buffer.withUnsafeMutableBytes { recv(connection, $0.baseAddress, $0.count, 0) }
            if count <= 0 { return }
            raw.append(contentsOf: buffer.prefix(count))
            if Self.headersComplete(raw) { break }
        }
        guard Self.headersComplete(raw), let request = String(data: raw, encoding: .utf8),
            let callback = Self.parse(request: request, redirectURL: redirectURL)
        else {
            Self.respond(connection, status: "404 Not Found", body: "Not found.")
            return
        }
        guard Self.hasExpectedState(callback, expected: expectedState) else {
            Self.respond(connection, status: "400 Bad Request", body: "Invalid login state.")
            return
        }

        Self.respond(
            connection, status: "200 OK",
            body: "<html><body style=\"font-family:-apple-system;background:#111;color:#eee\">"
                + "Login received — return to Harness Monitor.</body></html>")
        let next: (@Sendable (URL) -> Void)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let next = handler
            handler = nil
            return next
        }
        next?(callback)
    }

    private static func hasExpectedState(_ callback: URL, expected: String) -> Bool {
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let states = items.filter { $0.name == "state" }
        return states.count == 1 && states[0].value == expected
    }

    private static func headersComplete(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    private static func respond(_ connection: Int32, status: String, body: String) {
        let payload = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = send(connection, base, bytes.count, MSG_DONTWAIT)
        }
    }

    private static func closeSocket(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    /// Turns the request target into a callback using the exact redirect identity originally issued
    /// by Core. The listening address is intentionally not substituted for `localhost`.
    static func parse(request: String, redirectURL: URL) -> URL? {
        let requestLine = request.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(parts[1])
        guard let targetComponents = URLComponents(string: target),
            let issued = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
            targetComponents.percentEncodedPath == issued.percentEncodedPath,
            targetComponents.scheme == nil, targetComponents.host == nil
        else { return nil }
        var callback = issued
        callback.percentEncodedQuery = targetComponents.percentEncodedQuery
        callback.fragment = nil
        return callback.url
    }
}

enum OAuthCallbackListenerError: LocalizedError, Equatable {
    case bindFailed(String)
    case portOccupied(String)

    var errorDescription: String? {
        switch self {
        case .bindFailed(let message): message
        case .portOccupied(let message): message
        }
    }
}
