import Darwin
import Foundation
import Testing

@testable import HarnessUsage

@Suite("OAuth callback listener", .serialized)
struct OAuthCallbackListenerTests {
    @Test("parser preserves the issued localhost redirect identity")
    func parserPreservesIssuedRedirect() throws {
        let redirect = try #require(URL(string: "http://localhost:53692/callback"))
        let url = OAuthCallbackListener.parse(
            request: "GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            redirectURL: redirect)
        #expect(url?.host == "localhost")
        #expect(url?.port == 53692)
        #expect(url?.path == "/callback")
        #expect(url?.query == "code=abc&state=xyz")
        #expect(OAuthCallbackListener.parse(request: "POST /callback HTTP/1.1", redirectURL: redirect) == nil)
        #expect(OAuthCallbackListener.parse(request: "GET /callback2 HTTP/1.1", redirectURL: redirect) == nil)
    }

    @Test("invalid state does not consume listener before valid callback")
    func invalidStateDoesNotConsumeListener() async throws {
        let port = try FreePort.next()
        let redirect = URL(string: "http://localhost:\(port)/callback")!
        let listener = OAuthCallbackListener()
        let received = LockedBox<URL?>(nil)
        try listener.start(redirectURL: redirect, expectedState: "right") { received.set($0) }
        defer { listener.stop() }

        let wrongPath = URL(string: "http://127.0.0.1:\(port)/other?code=a&state=right")!
        let (_, pathResponse) = try await URLSession.shared.data(from: wrongPath)
        #expect((pathResponse as? HTTPURLResponse)?.statusCode == 404)
        #expect(listener.isListening)

        let wrong = URL(string: "http://127.0.0.1:\(port)/callback?code=a&state=wrong")!
        let (_, wrongResponse) = try await URLSession.shared.data(from: wrong)
        #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 400)
        #expect(listener.isListening)
        #expect(received.get() == nil)

        let right = URL(string: "http://127.0.0.1:\(port)/callback?code=a&state=right")!
        let (_, rightResponse) = try await URLSession.shared.data(from: right)
        #expect((rightResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(received.get()?.host == "localhost")
    }

    @Test("idle accepted peer is canceled and port is reusable")
    func idlePeerCancelReleasesPort() throws {
        let port = try FreePort.next()
        let redirect = URL(string: "http://localhost:\(port)/callback")!
        let listener = OAuthCallbackListener()
        try listener.start(redirectURL: redirect, expectedState: "state") { _ in }
        let peer = try LoopbackPeer.connect(port: port)
        defer { close(peer) }
        try waitUntil { listener.hasAcceptedClient }

        listener.stop()
        try waitUntil { listener.hasAcceptedClient == false }
        let replacement = OAuthCallbackListener()
        try replacement.start(redirectURL: redirect, expectedState: "state") { _ in }
        replacement.stop()
    }

    @Test("disconnect before response does not terminate process")
    func disconnectBeforeResponseDoesNotCrash() throws {
        let port = try FreePort.next()
        let redirect = URL(string: "http://localhost:\(port)/callback")!
        let listener = OAuthCallbackListener()
        defer { listener.stop() }
        try listener.start(redirectURL: redirect, expectedState: "state") { _ in }
        let peer = try LoopbackPeer.connect(port: port)
        try waitUntil { listener.hasAcceptedClient }
        let request = "GET /callback?code=a&state=state HTTP/1.1\r\nHost: localhost\r\n\r\n"
        _ = request.withCString { send(peer, $0, strlen($0), 0) }
        _ = shutdown(peer, SHUT_RDWR)
        close(peer)
        try waitUntil { listener.hasAcceptedClient == false }
        #expect(listener.isListening || listener.hasAcceptedClient == false)
    }

    @Test("occupied port reports actionable error")
    func occupiedPortIsActionable() throws {
        let port = try FreePort.next()
        let redirect = URL(string: "http://localhost:\(port)/callback")!
        let first = OAuthCallbackListener()
        try first.start(redirectURL: redirect, expectedState: "state") { _ in }
        defer { first.stop() }
        let second = OAuthCallbackListener()
        #expect(throws: OAuthCallbackListenerError.self) {
            try second.start(redirectURL: redirect, expectedState: "state") { _ in }
        }
    }
}

private enum FreePort {
    static func next() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketTestError.failed }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard
            withUnsafePointer(
                to: &address,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }) == 0
        else { throw SocketTestError.failed }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard
            withUnsafeMutablePointer(
                to: &assigned,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }) == 0
        else { throw SocketTestError.failed }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}

private enum LoopbackPeer {
    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketTestError.failed }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard
            withUnsafePointer(
                to: &address,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }) == 0
        else {
            close(fd)
            throw SocketTestError.failed
        }
        return fd
    }
}

private func waitUntil(_ condition: () -> Bool) throws {
    for _ in 0..<100_000 where !condition() { sched_yield() }
    guard condition() else { throw SocketTestError.failed }
}

private enum SocketTestError: Error { case failed }

private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ next: T) { lock.withLock { value = next } }
    func get() -> T { lock.withLock { value } }
}
