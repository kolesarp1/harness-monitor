import Foundation
import Testing

@testable import HarnessUsageCore

private final class SecurityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var calls: Int { lock.withLock { value } }

    func reader(_ result: ClaudeCredentials.KeychainRead) -> @Sendable (String) async -> ClaudeCredentials.KeychainRead {
        { [self] _ in
            lock.withLock { value += 1 }
            return result
        }
    }
}

@Test func transientKeychainFailureIsUnavailableAndRetried() async {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let counter = SecurityCounter()
    let reader = counter.reader(.failed("Keychain lookup timed out"))

    let first = await ClaudeCredentials.resolve(home: home, env: [:], runSecurity: reader)
    let second = await ClaudeCredentials.resolve(home: home, env: [:], runSecurity: reader)

    guard case .unavailable("Keychain lookup timed out") = first,
        case .unavailable("Keychain lookup timed out") = second
    else {
        Issue.record("A transient Keychain failure was not reported as unavailable")
        return
    }
    #expect(counter.calls == 2)
}

@Test func missingKeychainItemIsAbsent() async {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }

    let resolution = await ClaudeCredentials.resolve(
        home: home, env: [:], runSecurity: { _ in .absent })
    guard case .absent = resolution else {
        Issue.record("A missing Keychain item was not reported as absent")
        return
    }
}
