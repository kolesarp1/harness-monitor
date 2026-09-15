import Darwin
import Foundation
import Testing

@testable import HarnessUsageCore

private actor SyntheticOAuthState {
    var identity = SubscriptionOAuthIdentity(
        id: "account-1", email: "same@example.com", name: "Personal", plan: "unfamiliar_plan", verified: true)
    var exchangeExpiry = Date.distantFuture
    var exchangeAccess = "access"
    var exchanges = 0
    var refreshes = 0
    var fetches = 0
    var usageAccessTokens: [String] = []
    var usageValue = 37.0
    var rateLimitUntil: Date?
    var identityIsUnavailable = false
    var refreshIsAmbiguous = false
    var blockExchange = false
    var blockRefresh = false
    private var exchangeStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var exchangeRelease: CheckedContinuation<Void, Never>?
    private var refreshStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshRelease: CheckedContinuation<Void, Never>?

    func exchangeCredential() async -> SubscriptionOAuthCredential {
        exchanges += 1
        for waiter in exchangeStartedWaiters { waiter.resume() }
        exchangeStartedWaiters = []
        if blockExchange { await withCheckedContinuation { exchangeRelease = $0 } }
        return SubscriptionOAuthCredential(accessToken: exchangeAccess, refreshToken: "refresh", expiresAt: exchangeExpiry)
    }

    func waitForExchangeStart() async {
        if exchanges > 0 { return }
        await withCheckedContinuation { exchangeStartedWaiters.append($0) }
    }

    func releaseExchange() {
        blockExchange = false
        exchangeRelease?.resume()
        exchangeRelease = nil
    }

    func refreshedCredential() async throws -> SubscriptionOAuthCredential {
        refreshes += 1
        if refreshIsAmbiguous { throw SubscriptionOAuthTransportError.ambiguous }
        for waiter in refreshStartedWaiters { waiter.resume() }
        refreshStartedWaiters = []
        if blockRefresh {
            await withCheckedContinuation { refreshRelease = $0 }
        } else {
            await Task.yield()
        }
        return SubscriptionOAuthCredential(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: .distantFuture)
    }

    func waitForRefreshStart() async {
        if refreshes > 0 { return }
        await withCheckedContinuation { refreshStartedWaiters.append($0) }
    }

    func releaseRefresh() {
        blockRefresh = false
        refreshRelease?.resume()
        refreshRelease = nil
    }

    func resolvedIdentity() throws -> SubscriptionOAuthIdentity {
        if identityIsUnavailable { throw SubscriptionAccountError.identityUnavailable }
        return identity
    }

    func usage(accessToken: String, now: Date) -> SubscriptionOAuthUsageOutcome {
        fetches += 1
        usageAccessTokens.append(accessToken)
        if let rateLimitUntil { return .rateLimited(until: rateLimitUntil) }
        return .success(
            snapshot: UsageSnapshot(
                windows: [UsageWindow(id: "5h", title: "Session", utilization: usageValue, kind: .account)],
                localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth, lastUpdated: now),
            identity: identity)
    }
}

private struct SyntheticOAuthProvider: SubscriptionOAuthProvider {
    let integration: Integration
    let state: SyntheticOAuthState

    func authorization(verifier: String, challenge: String, state: String) throws -> SubscriptionOAuthAuthorization {
        let redirect = URL(string: integration == .claude ? "http://localhost:53692/callback" : "http://localhost:1455/auth/callback")!
        var components = URLComponents(string: "https://example.test/authorize")!
        components.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge)]
        return SubscriptionOAuthAuthorization(authorizationURL: components.url!, redirectURL: redirect)
    }

    func exchange(code: String, verifier: String, state: String, redirectURL: URL) async throws -> SubscriptionOAuthCredential {
        await self.state.exchangeCredential()
    }

    func refresh(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthCredential {
        try await state.refreshedCredential()
    }

    func identify(_ credential: SubscriptionOAuthCredential) async throws -> SubscriptionOAuthIdentity { try await state.resolvedIdentity() }

    func usage(
        _ credential: SubscriptionOAuthCredential, identity: SubscriptionOAuthIdentity, now: Date
    ) async -> SubscriptionOAuthUsageOutcome { await state.usage(accessToken: credential.accessToken, now: now) }
}

private actor EmptyDetectedMonitor: IntegrationMonitor {
    private(set) var reloads = 0
    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? { nil }
    func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot] {
        reloads += 1
        return [:]
    }
}

private actor BackoffAwareDetectedMonitor: IntegrationMonitor {
    private(set) var networkAttempts = 0
    private var holds: [String: Date] = [:]
    private var reportedHolds: [String: Date] = [:]

    func applyAccountBackoffs(_ holds: [String: Date]) { self.holds = holds }
    func accountBackoffs() -> [String: Date] { reportedHolds }
    func setReportedHolds(_ value: [String: Date]) { reportedHolds = value }
    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? { nil }
    func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot] {
        if holds["account-1"] == nil { networkAttempts += 1 }
        let defaultLogin: String? = nil
        return [
            defaultLogin: UsageSnapshot(
                windows: [UsageWindow(id: "5h", title: "Session", utilization: 18, kind: .account)],
                localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth,
                lastUpdated: Date(timeIntervalSince1970: 100), account: accountForBackoff())
        ]
    }

    private nonisolated func accountForBackoff() -> UsageAccount {
        UsageAccount(
            id: "account-1", email: "same@example.com", plan: nil,
            location: "~/.claude", suggestedName: "Personal")
    }
}

private final class StoreClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
}

private func disposableHome(_ name: String = "accounts") throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hu-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func callback(for login: SubscriptionLogin) throws -> URL {
    let state = try #require(URLComponents(url: login.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
    return try #require(URL(string: "\(login.redirectURL.absoluteString)?code=approved&state=\(state)"))
}

private final class PersistenceSignal: @unchecked Sendable {
    let stream: AsyncStream<UUID>
    private let continuation: AsyncStream<UUID>.Continuation

    init() {
        var continuation: AsyncStream<UUID>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func send(_ id: UUID) { continuation.yield(id) }
}

private final class SupersedeSignal: @unchecked Sendable {
    let stream: AsyncStream<Set<UUID>>
    private let continuation: AsyncStream<Set<UUID>>.Continuation

    init() {
        var continuation: AsyncStream<Set<UUID>>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func send(_ ids: Set<UUID>) { continuation.yield(ids) }
}

private final class HeldAccountFileLock {
    private var descriptor: Int32

    init(home: URL) throws {
        let path = home.appendingPathComponent(".harness-usage/accounts/.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw SubscriptionAccountError.persistenceFailed
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

@Suite struct SubscriptionAccountStoreTests {
    // Defect: reporting login success before the private credential file is atomically saved, or losing
    // the account identity and retained reading on the next process launch.
    @Test func exchangeRefreshSaveReloadAndRemoveUseTheRealStore() async throws {
        let home = try disposableHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setExchangeExpiry(.distantPast)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })

        let login = try await store.beginLogin(for: .claude)
        let account = try await store.completeLogin(login.id, callbackURL: callback(for: login))
        #expect(account.id == "account-1")
        let reading = await store.reload(integration: .claude, detected: [:])
        #expect(reading["account-1"]?.windows.first?.utilization == 37)
        #expect(reading["account-1"]?.activeAccountSource == .owned)
        #expect(await state.refreshes == 1)

        let accountDirectory = home.appendingPathComponent(".harness-usage/accounts")
        let files = try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restarted = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 101) })
        let restored = await restarted.accountSnapshots()
        #expect(restored.map(\.account.id) == ["account-1"])
        #expect(restored.first?.lastReading?.windows.first?.utilization == 37)

        try await restarted.removeConnection(for: .claude, accountID: "account-1")
        #expect(await restarted.accountSnapshots().isEmpty)
    }

    // Defect: selected detected metadata being overwritten by the record's older account value, then
    // persisting that obsolete name/email/plan across restart.
    @MainActor @Test func detectedMetadataUpdatesForStableIdentityAndPersists() async throws {
        let home = try disposableHome("detected-metadata")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SubscriptionAccountStore(home: home, providers: [:])
        let suite = "detected-metadata-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var configured = settings.settings
        configured.accountNames["person/org"] = "My label"
        settings.update(configured)
        func reading(name: String, email: String, plan: String) -> UsageSnapshot {
            UsageSnapshot(
                windows: [UsageWindow(id: "5h", title: "Session", utilization: 20, kind: .account)],
                localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth,
                lastUpdated: Date(),
                account: UsageAccount(
                    id: "person/org", email: email, plan: plan,
                    location: "~/.claude", suggestedName: name))
        }
        _ = await store.resolve(
            integration: .claude,
            detected: [nil: reading(name: "Old", email: "old@example.com", plan: "old_plan")])
        let updated = await store.resolve(
            integration: .claude,
            detected: [nil: reading(name: "New", email: "new@example.com", plan: "future_plan")])
        let published = try #require(updated["person/org"]?.account)
        #expect(published.id == "person/org")
        #expect(published.suggestedName == "New")
        #expect(published.email == "new@example.com")
        #expect(published.plan == "future_plan")

        let restarted = SubscriptionAccountStore(home: home, providers: [:])
        let persisted = try #require(await restarted.accountSnapshots().first)
        #expect(persisted.key == UsageKey(.claude, profile: "person/org"))
        #expect(persisted.account == published)
        #expect(settings.settings.accountNames["person/org"] == "My label")
    }

    // Defect: current detected fallback metadata being replaced with stale owned metadata.
    @Test func selectedDetectedFallbackKeepsCurrentProviderMetadata() async throws {
        let home = try disposableHome("fallback-metadata")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setIdentity(
            SubscriptionOAuthIdentity(
                id: "account-1", email: "old@example.com", name: "Old", plan: "old_plan", verified: true))
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))
        await store.applyAccountBackoffs(["account-1": .distantFuture], integration: .claude)
        let detected = UsageSnapshot(
            windows: [UsageWindow(id: "5h", title: "Session", utilization: 30, kind: .account)],
            localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth,
            lastUpdated: Date(),
            account: UsageAccount(
                id: "account-1", email: "new@example.com", plan: "provider_future",
                location: "~/.claude", suggestedName: "New"))
        let resolved = await store.resolve(integration: .claude, detected: [nil: detected])
        let published = try #require(resolved["account-1"]?.account)
        #expect(published.suggestedName == "New")
        #expect(published.email == "new@example.com")
        #expect(published.plan == "provider_future")
        let restarted = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        #expect(await restarted.accountSnapshots().first?.account == published)
    }

    // Defect: cancellation after exchange/identity but during account-file lock acquisition allowing
    // the credential to be persisted after the login was canceled.
    @Test func cancelWhileWaitingForPersistenceLockCannotSaveLogin() async throws {
        let home = try disposableHome("cancel-persistence")
        defer { try? FileManager.default.removeItem(at: home) }
        let signal = PersistenceSignal()
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(
            home: home, providers: [.claude: provider],
            beforeLoginPersistence: { signal.send($0) })
        let login = try await store.beginLogin(for: .claude)
        let held = try HeldAccountFileLock(home: home)
        var events = signal.stream.makeAsyncIterator()
        let completion = Task { try await store.completeLogin(login.id, callbackURL: callback(for: login)) }
        #expect(await events.next() == login.id)
        await store.cancelLogin(login.id)
        held.release()

        await #expect(throws: SubscriptionAccountError.loginNotPending) { try await completion.value }
        #expect(await store.accountSnapshots().isEmpty)
        let restarted = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        #expect(await restarted.accountSnapshots().isEmpty)
    }

    // Defect: a superseding begin invalidating only callback/exchange work but not a completion that
    // is already waiting to persist its credential.
    @Test func supersedingBeginInvalidatesPersistenceStage() async throws {
        let home = try disposableHome("supersede-persistence")
        defer { try? FileManager.default.removeItem(at: home) }
        let persistence = PersistenceSignal()
        let superseded = SupersedeSignal()
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(
            home: home, providers: [.claude: provider],
            beforeLoginPersistence: { persistence.send($0) },
            onLoginSuperseded: { superseded.send($0) })
        let firstLogin = try await store.beginLogin(for: .claude)
        let held = try HeldAccountFileLock(home: home)
        var persistenceEvents = persistence.stream.makeAsyncIterator()
        let firstCompletion = Task {
            try await store.completeLogin(firstLogin.id, callbackURL: callback(for: firstLogin))
        }
        #expect(await persistenceEvents.next() == firstLogin.id)

        var supersedeEvents = superseded.stream.makeAsyncIterator()
        let secondBegin = Task { try await store.beginLogin(for: .claude) }
        #expect(await supersedeEvents.next() == Set([firstLogin.id]))
        held.release()

        await #expect(throws: SubscriptionAccountError.loginNotPending) { try await firstCompletion.value }
        let secondLogin = try await secondBegin.value
        await store.cancelLogin(secondLogin.id)
        #expect(await store.accountSnapshots().isEmpty)
        #expect(await SubscriptionAccountStore(home: home, providers: [.claude: provider]).accountSnapshots().isEmpty)
    }

    // Defect: app-owned usage keeping a fixed five-minute floor after the global cadence changes, or
    // manual refresh failing to bypass that app floor.
    @Test func ownedUsageFollowsRuntimeCadenceAndManualBypass() async throws {
        let home = try disposableHome("owned-cadence")
        defer { try? FileManager.default.removeItem(at: home) }
        let clock = StoreClock(Date(timeIntervalSince1970: 100))
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(
            home: home, providers: [.claude: provider], now: { clock.now })
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))

        await store.prepareOwned(
            integration: .claude, policy: UsageReloadPolicy(interval: .oneMinute))
        #expect(await state.fetches == 1)
        clock.advance(59)
        await store.prepareOwned(
            integration: .claude, policy: UsageReloadPolicy(interval: .oneMinute))
        #expect(await state.fetches == 1)
        clock.advance(1)
        await store.prepareOwned(
            integration: .claude, policy: UsageReloadPolicy(interval: .oneMinute))
        #expect(await state.fetches == 2)

        clock.advance(1)
        await store.prepareOwned(
            integration: .claude, policy: UsageReloadPolicy(interval: .fifteenMinutes))
        #expect(await state.fetches == 2)
        await store.prepareOwned(
            integration: .claude,
            policy: UsageReloadPolicy(interval: .fifteenMinutes, bypassAppCadence: true))
        #expect(await state.fetches == 3)
    }

    // Defect: two overlapping engine reloads spending the same rotating refresh token twice.
    @Test func concurrentReloadsShareOneRefresh() async throws {
        let home = try disposableHome("refresh-serialization")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setExchangeExpiry(.distantPast)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))

        async let first = store.reload(integration: .claude, detected: [:])
        async let second = store.reload(integration: .claude, detected: [:])
        _ = await (first, second)
        #expect(await state.refreshes == 1)
    }

    // Defect: retrying an ambiguously completed rotating-token refresh with the stale refresh token.
    @Test func ambiguousRefreshRequiresReconnectAndIsNeverRepeated() async throws {
        let home = try disposableHome("ambiguous-refresh")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setExchangeExpiry(.distantPast)
        await state.setRefreshAmbiguous(true)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))

        _ = await store.reload(integration: .claude, detected: [:])
        let restarted = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 101) })
        _ = await restarted.reload(integration: .claude, detected: [:])
        #expect(await state.refreshes == 1)
        #expect(await restarted.accountSnapshots().first?.status == SubscriptionAccountError.reconnectRequired.localizedDescription)
    }

    // Defect: two app processes serializing on a lock but both refreshing from their stale in-memory
    // copy after the first process has already rotated and saved the token.
    @Test func separateStoreInstancesReloadUnderTheCrossProcessRefreshLock() async throws {
        let home = try disposableHome("cross-process-refresh")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setExchangeExpiry(.distantPast)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let firstStore = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await firstStore.beginLogin(for: .claude)
        _ = try await firstStore.completeLogin(login.id, callbackURL: callback(for: login))
        let secondStore = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })

        async let first = firstStore.reload(integration: .claude, detected: [:])
        async let second = secondStore.reload(integration: .claude, detected: [:])
        _ = await (first, second)
        #expect(await state.refreshes == 1)
    }

    // Defect: stale metadata resolution from a second process overwriting the refresh token rotated
    // and saved by the first process.
    @Test func staleStoreMetadataCannotOverwriteRotatedCredential() async throws {
        let home = try disposableHome("stale-metadata")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setExchangeExpiry(.distantPast)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let first = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await first.beginLogin(for: .claude)
        _ = try await first.completeLogin(login.id, callbackURL: callback(for: login))
        let stale = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        _ = await first.reload(integration: .claude, detected: [:])

        let detected = UsageSnapshot(
            windows: [], localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth,
            lastUpdated: Date(timeIntervalSince1970: 101),
            account: UsageAccount(id: "account-1", email: nil, plan: nil, location: "~/.claude", suggestedName: "Personal"))
        _ = await stale.resolve(integration: .claude, detected: [nil: detected])
        let restarted = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 102) })
        await restarted.invalidateThrottles(for: .claude)
        _ = await restarted.reload(integration: .claude, detected: [:])
        #expect(await state.usageAccessTokens.last == "new-access")
        #expect(await state.refreshes == 1)
    }

    // Defect: a canceled or superseded browser callback exchanging and saving a credential anyway.
    @Test func canceledAndWrongStateCallbacksAreRejected() async throws {
        let home = try disposableHome("cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = SyntheticOAuthProvider(integration: .claude, state: SyntheticOAuthState())
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        let canceled = try await store.beginLogin(for: .claude)
        await store.cancelLogin(canceled.id)
        await #expect(throws: SubscriptionAccountError.loginNotPending) {
            try await store.completeLogin(canceled.id, callbackURL: callback(for: canceled))
        }

        let active = try await store.beginLogin(for: .claude)
        let wrong = URL(string: "\(active.redirectURL.absoluteString)?code=approved&state=wrong")!
        await #expect(throws: SubscriptionAccountError.stateMismatch) {
            try await store.completeLogin(active.id, callbackURL: wrong)
        }
    }

    // Defect: duplicate callback values with nil payloads escaping count validation, or two valid
    // callbacks exchanging one authorization code concurrently.
    @Test func callbackValidationRejectsNilDuplicatesAndConsumesValidCodeOnce() async throws {
        let home = try disposableHome("callback-once")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setBlockExchange(true)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        let login = try await store.beginLogin(for: .claude)
        let valid = try callback(for: login)
        let csrf = try #require(URLComponents(url: valid, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        let duplicate = URL(string: "\(login.redirectURL.absoluteString)?code=approved&code&state=\(csrf)")!
        await #expect(throws: SubscriptionAccountError.invalidCallback) {
            try await store.completeLogin(login.id, callbackURL: duplicate)
        }

        let first = Task { try await store.completeLogin(login.id, callbackURL: valid) }
        await state.waitForExchangeStart()
        await #expect(throws: SubscriptionAccountError.loginNotPending) {
            try await store.completeLogin(login.id, callbackURL: valid)
        }
        await state.releaseExchange()
        _ = try await first.value
        #expect(await state.exchanges == 1)
    }

    // Defect: canceling after exchange starts still allowing that suspended completion to save.
    @Test func cancelDuringExchangeCannotSaveLogin() async throws {
        let home = try disposableHome("cancel-exchange")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setBlockExchange(true)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        let login = try await store.beginLogin(for: .claude)
        let completion = Task { try await store.completeLogin(login.id, callbackURL: callback(for: login)) }
        await state.waitForExchangeStart()
        await store.cancelLogin(login.id)
        await state.releaseExchange()
        await #expect(throws: SubscriptionAccountError.loginNotPending) { try await completion.value }
        #expect(await store.accountSnapshots().isEmpty)
    }

    // Defect: reconnecting account A with account B's consent and silently moving A's ring/name.
    @Test func reconnectCannotReplaceTheTargetWithAnotherIdentity() async throws {
        let home = try disposableHome("reconnect")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        let first = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(first.id, callbackURL: callback(for: first))
        await state.setIdentity(
            SubscriptionOAuthIdentity(id: "account-2", email: "same@example.com", name: nil, plan: nil, verified: true))
        let reconnect = try await store.beginLogin(for: .claude, reconnecting: "account-1")
        await #expect(throws: SubscriptionAccountError.reconnectIdentityMismatch) {
            try await store.completeLogin(reconnect.id, callbackURL: callback(for: reconnect))
        }
        #expect(await store.accountSnapshots().map(\.account.id) == ["account-1"])
    }

    // Defect: an in-flight refresh writing its old record after Remove and resurrecting the connection.
    @Test func removeRacingRefreshCannotResurrectTheAccount() async throws {
        let home = try disposableHome("remove-race")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setExchangeExpiry(.distantPast)
        await state.setBlockRefresh(true)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))

        let reload = Task { await store.reload(integration: .claude, detected: [:]) }
        await state.waitForRefreshStart()
        try await store.removeConnection(for: .claude, accountID: "account-1")
        await state.releaseRefresh()
        _ = await reload.value
        #expect(await store.accountSnapshots().isEmpty)
        let restarted = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        #expect(await restarted.accountSnapshots().isEmpty)
    }

    // Defect: an old refresh result replacing a newer reconnect credential after actor reentrancy.
    @Test func reconnectRacingRefreshKeepsTheReconnectCredential() async throws {
        let home = try disposableHome("reconnect-race")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setExchangeExpiry(.distantPast)
        await state.setBlockRefresh(true)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let first = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(first.id, callbackURL: callback(for: first))
        let reload = Task { await store.reload(integration: .claude, detected: [:]) }
        await state.waitForRefreshStart()

        await state.setExchangeAccess("reconnected-access")
        await state.setExchangeExpiry(.distantFuture)
        let reconnect = try await store.beginLogin(for: .claude, reconnecting: "account-1")
        _ = try await store.completeLogin(reconnect.id, callbackURL: callback(for: reconnect))
        await state.releaseRefresh()
        _ = await reload.value
        await store.invalidateThrottles(for: .claude)
        _ = await store.reload(integration: .claude, detected: [:])
        #expect(await state.usageAccessTokens.last == "reconnected-access")
        #expect(await store.accountSnapshots().map(\.account.id) == ["account-1"])
    }

    // Defect: a detected-only identity being transient, then disappearing after its folder switches
    // account or after process restart.
    @Test func detectedOnlyAccountsPersistLastReadingAndActualSourceHealth() async throws {
        let home = try disposableHome("detected-retention")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SubscriptionAccountStore(home: home, providers: [:])
        let old = UsageSnapshot(
            windows: [UsageWindow(id: "5h", title: "Session", utilization: 44, kind: .account)],
            localTokensToday: nil, localTokensWeek: nil, source: .claudeOAuth,
            lastUpdated: Date(timeIntervalSince1970: 10),
            account: UsageAccount(id: "old/org", email: nil, plan: nil, location: "~/.claude", suggestedName: "Old"))
        _ = await store.resolve(integration: .claude, detected: [nil: old])
        let restarted = SubscriptionAccountStore(home: home, providers: [:])
        #expect(await restarted.accountSnapshots().map(\.account.id) == ["old/org"])

        var disconnected = old
        disconnected.freshness = .disconnected
        _ = await restarted.resolve(integration: .claude, detected: [nil: disconnected])
        let unhealthy = try #require(await restarted.accountSnapshots().first)
        #expect(unhealthy.sources.first?.isAvailable == false)
        #expect(unhealthy.freshness == .disconnected)

        var replacement = old
        replacement.account = UsageAccount(id: "new/org", email: nil, plan: nil, location: "~/.claude", suggestedName: "New")
        let switched = await restarted.resolve(integration: .claude, detected: [nil: replacement])
        #expect(switched.keys.compactMap { $0 }.sorted() == ["new/org", "old/org"])
        #expect(switched["old/org"]?.freshness == .disconnected)
        #expect(switched["old/org"]?.accountSources.first?.reference == "~/.claude")
        #expect(switched["old/org"]?.accountSources.first?.isAvailable == false)
        let afterSwitchRestart = SubscriptionAccountStore(home: home, providers: [:])
        #expect(await afterSwitchRestart.accountSnapshots().map(\.account.id).sorted() == ["new/org", "old/org"])
    }

    // Defect: treating a provider Retry-After as source-specific and immediately retrying the same
    // subscription through its detected credential.
    @Test func ownedRetryAfterIsAppliedBeforeTheMatchingDetectedMonitorRuns() async throws {
        let home = try disposableHome("backoff")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setRateLimitUntil(Date(timeIntervalSince1970: 1_000))
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))
        let detected = BackoffAwareDetectedMonitor()
        let monitor = store.makeMonitor(for: .claude, detectedMonitor: detected)

        let readings = await monitor.reloadProfiles(wantUsageEstimate: false)
        #expect(await detected.networkAttempts == 0)
        #expect(readings["account-1"]?.activeAccountSource == .detected)
        #expect(readings["account-1"]?.freshness == .fallback)
    }

    // Defect: reconnect waking the engine by clearing a server-directed Retry-After.
    @Test func reconnectDoesNotWaiveAccountBackoff() async throws {
        let home = try disposableHome("reconnect-backoff")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setRateLimitUntil(Date(timeIntervalSince1970: 1_000))
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))
        _ = await store.reload(integration: .claude, detected: [:])
        let reconnect = try await store.beginLogin(for: .claude, reconnecting: "account-1")
        _ = try await store.completeLogin(reconnect.id, callbackURL: callback(for: reconnect))
        _ = await store.reload(integration: .claude, detected: [:])
        #expect(await state.fetches == 1)
    }

    // Defect: a detected-source Retry-After being ignored by owned on the following tick.
    @Test func detectedRetryAfterBlocksOwnedOnTheNextTick() async throws {
        let home = try disposableHome("reverse-backoff")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))
        let detected = BackoffAwareDetectedMonitor()
        await detected.setReportedHolds(["account-1": Date(timeIntervalSince1970: 1_000)])
        let monitor = store.makeMonitor(for: .claude, detectedMonitor: detected)

        _ = await monitor.reloadProfiles(wantUsageEstimate: false)
        #expect(await state.fetches == 0)
        #expect(await store.accountSnapshots().first?.freshness == .fallback)
    }

    // Defect: account availability causing an app-only provider to probe nonexistent local files or
    // Claude Keychain credentials.
    @Test func appOnlyReloadSkipsDetectedMonitor() async throws {
        let home = try disposableHome("app-only-skip")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        let login = try await store.beginLogin(for: .claude)
        _ = try await store.completeLogin(login.id, callbackURL: callback(for: login))
        let detected = EmptyDetectedMonitor()
        let monitor = store.makeMonitor(for: .claude, detectedMonitor: detected)

        _ = await monitor.reloadProfiles(wantUsageEstimate: false, includeDetected: false)
        #expect(await detected.reloads == 0)
    }

    // Defect: an unwritable account root being reported as a saved login.
    @Test func persistenceSetupFailureIsVisibleBeforeLoginStarts() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hu-account-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = SyntheticOAuthProvider(integration: .claude, state: SyntheticOAuthState())
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        await #expect(throws: SubscriptionAccountError.persistenceFailed) {
            try await store.beginLogin(for: .claude)
        }
    }

    // Defect: deduplicating an incomplete provider identity by email/token, or refusing to retain the
    // connection as an explicitly separate account.
    @Test func incompleteProviderIdentityIsRetainedAsSeparateAndExplained() async throws {
        let home = try disposableHome("unverified")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        await state.setIdentityUnavailable(true)
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let store = SubscriptionAccountStore(home: home, providers: [.claude: provider])
        let login = try await store.beginLogin(for: .claude)
        let account = try await store.completeLogin(login.id, callbackURL: callback(for: login))
        let snapshot = try #require(await store.accountSnapshots().first)
        #expect(account.id.hasPrefix("unverified:"))
        #expect(snapshot.status?.contains("cannot be deduplicated") == true)
    }

    // Defect: account-store wake signaling the loop without making its integration due, leaving a new
    // login unfetched until the next heartbeat.
    @MainActor @Test func accountUpdateMakesIntegrationImmediatelyDue() async throws {
        let home = try disposableHome("engine-due")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let accounts = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let detected = EmptyDetectedMonitor()
        let monitor = accounts.makeMonitor(for: .claude, detectedMonitor: detected)
        let suite = "SubscriptionDue-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = UsageStore()
        let engine = Engine(
            monitors: [.claude: monitor], usage: usage, settings: SettingsStore(defaults: defaults),
            integrations: IntegrationStore(home: home), accounts: accounts,
            now: { Date(timeIntervalSince1970: 100) })
        await Task.yield()
        await engine.tick()
        #expect(usage.readings.isEmpty)

        let login = try await accounts.beginLogin(for: .claude)
        _ = try await accounts.completeLogin(login.id, callbackURL: callback(for: login))
        await Task.yield()
        await engine.tick()
        #expect(usage.readings[UsageKey(.claude, profile: "account-1")] != nil)
        #expect(await detected.reloads == 0)
    }

    // Defect: an owned account remaining invisible until a CLI marker directory happens to exist.
    @MainActor @Test func enginePublishesOwnedAccountsWithoutFilesystemDetection() async throws {
        let home = try disposableHome("engine-account")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = SyntheticOAuthState()
        let provider = SyntheticOAuthProvider(integration: .claude, state: state)
        let accounts = SubscriptionAccountStore(home: home, providers: [.claude: provider], now: { Date(timeIntervalSince1970: 100) })
        let login = try await accounts.beginLogin(for: .claude)
        _ = try await accounts.completeLogin(login.id, callbackURL: callback(for: login))
        let monitor = accounts.makeMonitor(for: .claude, detectedMonitor: EmptyDetectedMonitor())
        let suite = "SubscriptionEngine-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = UsageStore()
        let engine = Engine(
            monitors: [.claude: monitor], usage: usage, settings: SettingsStore(defaults: defaults),
            integrations: IntegrationStore(home: home), accounts: accounts,
            now: { Date(timeIntervalSince1970: 100) })

        await engine.tick()
        #expect(usage.readings[UsageKey(.claude, profile: "account-1")]?.freshness == .fresh)
        #expect(usage.readings.count == 1)
    }
}

extension SyntheticOAuthState {
    func setExchangeExpiry(_ value: Date) { exchangeExpiry = value }
    func setExchangeAccess(_ value: String) { exchangeAccess = value }
    func setIdentity(_ value: SubscriptionOAuthIdentity) { identity = value }
    func setRateLimitUntil(_ value: Date?) { rateLimitUntil = value }
    func setIdentityUnavailable(_ value: Bool) { identityIsUnavailable = value }
    func setRefreshAmbiguous(_ value: Bool) { refreshIsAmbiguous = value }
    func setBlockExchange(_ value: Bool) { blockExchange = value }
    func setBlockRefresh(_ value: Bool) { blockRefresh = value }
}
