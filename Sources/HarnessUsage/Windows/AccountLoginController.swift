import AppKit
import HarnessUsageCore

protocol OAuthCallbackListening: AnyObject {
    func start(redirectURL: URL, expectedState: String, onCallback: @escaping @Sendable (URL) -> Void) throws
    func stop()
}

extension OAuthCallbackListener: OAuthCallbackListening {}

protocol SubscriptionAccountServing: Sendable {
    func beginLogin(for integration: Integration, reconnecting accountID: String?) async throws -> SubscriptionLogin
    func completeLogin(_ loginID: UUID, callbackURL: URL) async throws -> UsageAccount
    func cancelLogin(_ loginID: UUID) async
    func removeConnection(for integration: Integration, accountID: String) async throws
    func accountSnapshots() async -> [SubscriptionAccountSnapshot]
    func availableIntegrations() async -> Set<Integration>
}

extension SubscriptionAccountStore: SubscriptionAccountServing {}

@MainActor @Observable final class AccountLoginController {
    enum State: Equatable {
        case idle
        case waiting(Integration)
        case failed(Integration, String)
    }

    private(set) var state: State = .idle
    private(set) var snapshots: [SubscriptionAccountSnapshot] = []
    private(set) var accountIntegrations: Set<Integration> = []

    private let accounts: (any SubscriptionAccountServing)?
    private let onChanged: (() -> Void)?
    private let openBrowser: @MainActor (URL) -> Bool
    private let makeListener: @MainActor () -> any OAuthCallbackListening
    private var listener: (any OAuthCallbackListening)?
    private var loginID: UUID?
    private var loginIntegration: Integration?
    private var operationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var reloadGeneration: UInt64 = 0

    init(
        accounts: SubscriptionAccountStore?, onChanged: (() -> Void)? = nil,
        openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        makeListener: @escaping @MainActor () -> any OAuthCallbackListening = { OAuthCallbackListener() }
    ) {
        self.accounts = accounts
        self.onChanged = onChanged
        self.openBrowser = openBrowser
        self.makeListener = makeListener
    }

    init(
        accountService: (any SubscriptionAccountServing)?, onChanged: (() -> Void)? = nil,
        openBrowser: @escaping @MainActor (URL) -> Bool,
        makeListener: @escaping @MainActor () -> any OAuthCallbackListening
    ) {
        self.accounts = accountService
        self.onChanged = onChanged
        self.openBrowser = openBrowser
        self.makeListener = makeListener
    }

    var canStartLogin: Bool {
        guard accounts != nil else { return false }
        switch state {
        case .idle, .failed: return true
        case .waiting: return false
        }
    }

    func reload() async {
        guard let accounts else { return }
        reloadGeneration &+= 1
        let request = reloadGeneration
        let rows = await accounts.accountSnapshots()
        guard request == reloadGeneration else { return }
        snapshots = rows
        accountIntegrations = Set(rows.map(\.integration))
    }

    func snapshot(integration: Integration, accountID: String) -> SubscriptionAccountSnapshot? {
        snapshots.first { $0.integration == integration && $0.account.id == accountID }
    }

    func beginLogin(_ integration: Integration, reconnecting accountID: String? = nil) {
        guard let accounts, canStartLogin else { return }
        operationTask?.cancel()
        generation &+= 1
        let operation = generation
        state = .waiting(integration)
        loginIntegration = integration
        operationTask = Task { [weak self] in
            do {
                let login = try await accounts.beginLogin(for: integration, reconnecting: accountID)
                guard let self, !Task.isCancelled, self.generation == operation else {
                    await accounts.cancelLogin(login.id)
                    return
                }
                guard let expectedState = Self.authorizationState(login.authorizationURL) else {
                    await accounts.cancelLogin(login.id)
                    throw SubscriptionAccountError.invalidCallback
                }
                let listener = self.makeListener()
                self.listener = listener
                self.loginID = login.id
                try listener.start(redirectURL: login.redirectURL, expectedState: expectedState) { [weak self] callback in
                    Task { @MainActor in self?.received(callback, operation: operation) }
                }
                guard !Task.isCancelled, self.generation == operation else {
                    listener.stop()
                    await accounts.cancelLogin(login.id)
                    return
                }
                guard self.openBrowser(login.authorizationURL) else {
                    throw AccountLoginControllerError.browserFailed(
                        "Could not open the browser. The login listener is already closed.")
                }
            } catch {
                guard let self, self.generation == operation else { return }
                await self.abandon(operation: operation)
                guard self.generation == operation else { return }
                self.state = .failed(integration, Self.message(for: error))
            }
        }
    }

    func reconnect(_ integration: Integration, accountID: String) {
        beginLogin(integration, reconnecting: accountID)
    }

    func cancel() async {
        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        let id = loginID
        loginID = nil
        loginIntegration = nil
        listener?.stop()
        listener = nil
        if let accounts, let id { await accounts.cancelLogin(id) }
        state = .idle
        onChanged?()
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    private func received(_ callback: URL, operation: UInt64) {
        guard generation == operation, loginID != nil else { return }
        operationTask?.cancel()
        generation &+= 1
        let completion = generation
        operationTask = Task { [weak self] in await self?.finish(callback, operation: completion) }
    }

    private func finish(_ callback: URL, operation: UInt64) async {
        guard let accounts, let id = loginID, let integration = loginIntegration,
            generation == operation, !Task.isCancelled
        else { return }
        listener?.stop()
        listener = nil
        do {
            _ = try await accounts.completeLogin(id, callbackURL: callback)
            guard generation == operation, !Task.isCancelled else { return }
            loginID = nil
            loginIntegration = nil
            state = .idle
            await reload()
        } catch {
            guard generation == operation else { return }
            await abandon(operation: operation)
            guard generation == operation else { return }
            state = .failed(integration, Self.message(for: error))
        }
        guard generation == operation else { return }
        operationTask = nil
        onChanged?()
    }

    private func abandon(operation: UInt64) async {
        guard generation == operation else { return }
        listener?.stop()
        listener = nil
        let id = loginID
        loginID = nil
        loginIntegration = nil
        if let accounts, let id { await accounts.cancelLogin(id) }
    }

    func remove(_ integration: Integration, accountID: String) async {
        guard let accounts else { return }
        do {
            try await accounts.removeConnection(for: integration, accountID: accountID)
            await reload()
        } catch {
            state = .failed(integration, Self.message(for: error))
        }
        onChanged?()
    }

    static func message(for error: Error) -> String {
        if let listenerError = error as? OAuthCallbackListenerError {
            return listenerError.errorDescription ?? "The local login callback failed."
        }
        if let controllerError = error as? AccountLoginControllerError {
            return controllerError.errorDescription ?? "The login could not start."
        }
        if let accountError = error as? SubscriptionAccountError {
            return accountError.errorDescription ?? "The login could not finish."
        }
        return "The login could not finish. Try again."
    }

    private static func authorizationState(_ url: URL) -> String? {
        let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, let value = states[0].value, !value.isEmpty else { return nil }
        return value
    }
}

enum AccountLoginControllerError: LocalizedError, Equatable {
    case browserFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserFailed(let message): message
        }
    }
}
