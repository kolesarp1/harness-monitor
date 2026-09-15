import Foundation
import HarnessUsageCore
import Testing

@testable import HarnessUsage

private actor LoginServiceStub: SubscriptionAccountServing {
    private var beginContinuation: CheckedContinuation<SubscriptionLogin, Never>?
    private var beginStartedContinuation: CheckedContinuation<Void, Never>?
    private var beginStarted = false
    private var completeContinuation: CheckedContinuation<UsageAccount, Never>?
    private var completeStartedContinuation: CheckedContinuation<Void, Never>?
    private var completeStarted = false
    private(set) var canceled: [UUID] = []
    var blockBegin = false
    var blockComplete = false
    private var sequence = 0

    func beginLogin(for integration: Integration, reconnecting accountID: String?) async throws -> SubscriptionLogin {
        sequence += 1
        beginStarted = true
        beginStartedContinuation?.resume()
        beginStartedContinuation = nil
        if blockBegin {
            return await withCheckedContinuation { beginContinuation = $0 }
        }
        return makeLogin(sequence)
    }

    func completeLogin(_ loginID: UUID, callbackURL: URL) async throws -> UsageAccount {
        completeStarted = true
        completeStartedContinuation?.resume()
        completeStartedContinuation = nil
        if blockComplete {
            return await withCheckedContinuation { completeContinuation = $0 }
        }
        return makeAccount()
    }

    func cancelLogin(_ loginID: UUID) { canceled.append(loginID) }
    func removeConnection(for integration: Integration, accountID: String) async throws {}
    func accountSnapshots() -> [SubscriptionAccountSnapshot] { [] }
    func availableIntegrations() -> Set<Integration> { [] }

    func waitForBegin() async {
        if beginStarted { return }
        await withCheckedContinuation { beginStartedContinuation = $0 }
    }

    func releaseBegin() {
        beginContinuation?.resume(returning: makeLogin(sequence))
        beginContinuation = nil
    }

    func waitForComplete() async {
        if completeStarted { return }
        await withCheckedContinuation { completeStartedContinuation = $0 }
    }

    func releaseComplete() {
        completeContinuation?.resume(returning: makeAccount())
        completeContinuation = nil
    }

    func setBlockBegin(_ value: Bool) { blockBegin = value }
    func setBlockComplete(_ value: Bool) { blockComplete = value }

    private func makeLogin(_ number: Int) -> SubscriptionLogin {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        return SubscriptionLogin(
            id: id,
            authorizationURL: URL(string: "https://example.test/authorize?state=state-\(number)")!,
            redirectURL: URL(string: "http://localhost:\(20_000 + number)/callback")!)
    }

    private func makeAccount() -> UsageAccount {
        UsageAccount(id: "account", email: nil, plan: nil, location: "Harness Monitor", suggestedName: "Account")
    }
}

private final class LoginListenerStub: OAuthCallbackListening {
    private(set) var stopped = false
    private var callback: (@Sendable (URL) -> Void)?
    func start(redirectURL: URL, expectedState: String, onCallback: @escaping @Sendable (URL) -> Void) throws {
        callback = onCallback
    }
    func stop() { stopped = true }
    func send(_ url: URL) { callback?(url) }
}

private final class BrowserRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func open(_ url: URL) -> Bool {
        lock.withLock { urls.append(url) }
        return true
    }
    var count: Int { lock.withLock { urls.count } }
}

@Suite("Account login controller", .serialized)
@MainActor
struct AccountLoginControllerTests {
    @Test("busy login cannot start an overlapping account flow")
    func busyLoginRejectsOverlap() async {
        let controller = AccountLoginController(
            accountService: LoginServiceStub(), openBrowser: { _ in true },
            makeListener: { LoginListenerStub() })

        controller.beginLogin(.claude)
        #expect(controller.canStartLogin == false)
        controller.beginLogin(.codex)
        #expect(controller.state == .waiting(.claude))
        await controller.cancel()
        #expect(controller.state == .idle)
    }

    @Test("cancel during begin prevents stale browser open")
    func cancelDuringBeginPreventsBrowserOpen() async {
        let service = LoginServiceStub()
        await service.setBlockBegin(true)
        let browser = BrowserRecorder()
        let listener = LoginListenerStub()
        let controller = AccountLoginController(
            accountService: service, openBrowser: { browser.open($0) }, makeListener: { listener })

        controller.beginLogin(.claude)
        await service.waitForBegin()
        await controller.cancel()
        await service.releaseBegin()
        for _ in 0..<100 { await Task.yield() }

        #expect(browser.count == 0)
        #expect(controller.state == .idle)
        #expect(listener.stopped == false)
    }

    @Test("stale completion cannot overwrite a newer login")
    func staleCompletionCannotOverwriteNewLogin() async {
        let service = LoginServiceStub()
        await service.setBlockComplete(true)
        let browser = BrowserRecorder()
        let firstListener = LoginListenerStub()
        let secondListener = LoginListenerStub()
        var listeners: [LoginListenerStub] = [firstListener, secondListener]
        let controller = AccountLoginController(
            accountService: service, openBrowser: { browser.open($0) },
            makeListener: { listeners.removeFirst() })

        controller.beginLogin(.claude)
        for _ in 0..<100 where browser.count == 0 { await Task.yield() }
        firstListener.send(URL(string: "http://localhost:20001/callback?code=a&state=state-1")!)
        await service.waitForComplete()
        await controller.cancel()
        await service.setBlockComplete(false)
        controller.beginLogin(.codex)
        for _ in 0..<100 where browser.count < 2 { await Task.yield() }
        await service.releaseComplete()
        for _ in 0..<100 { await Task.yield() }

        #expect(controller.state == .waiting(.codex))
        #expect(browser.count == 2)
        #expect(secondListener.stopped == false)
    }
}
