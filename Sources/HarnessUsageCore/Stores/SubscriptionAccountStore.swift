import Darwin
import Foundation

public actor SubscriptionAccountStore {
    fileprivate struct DetectionGeneration: Sendable, Equatable {
        let integration: Integration
        let value: UInt64
    }

    private struct StoredDetectionGenerations: Codable {
        var values: [String: UInt64] = [:]
    }

    private enum DetectionCommitError: Error {
        case superseded
    }

    private struct PendingLogin: Sendable {
        let integration: Integration
        let verifier: String
        let state: String
        let redirectURL: URL
        let reconnectingAccountID: String?
    }

    private struct StoredRecord: Codable, Sendable, Equatable {
        var version: Int
        var fileID: UUID
        var integration: Integration
        var identity: SubscriptionOAuthIdentity
        var account: UsageAccount
        var canonicalKey: String
        var credential: SubscriptionOAuthCredential?
        var lastReading: UsageSnapshot?
        var status: String?
        var refreshUncertain: Bool
        var holdUntil: Date?
        var lastAttempt: Date?
        var ownedHealthy: Bool
        var detectedSources: [UsageAccountSource]
    }

    private enum RefreshPreparation: Sendable {
        case adopt(StoredRecord)
        case refresh(StoredRecord, SubscriptionOAuthCredential)
    }

    private let directory: URL
    private let providers: [Integration: any SubscriptionOAuthProvider]
    private let now: @Sendable () -> Date
    private let beforeLoginPersistence: (@Sendable (UUID) -> Void)?
    private let beforeDetectionPersistence: (@Sendable (Integration) async -> Void)?
    private let onLoginSuperseded: (@Sendable (Set<UUID>) -> Void)?
    private var records: [UUID: StoredRecord]
    private var pending: [UUID: PendingLogin] = [:]
    private var loginTasks: [UUID: Task<(SubscriptionOAuthCredential, SubscriptionOAuthIdentity), Error>] = [:]
    private var completingLogins: Set<UUID> = []
    private var canceledLogins: Set<UUID> = []
    private var refreshTasks: [UUID: Task<StoredRecord, Error>] = [:]
    private var updateHandler: (@Sendable (Integration) -> Void)?
    private var loadError: SubscriptionAccountError?
    private static let version = 1

    public init(home: URL) {
        self.init(
            home: home,
            providers: [
                .claude: ClaudeSubscriptionOAuth(),
                .codex: CodexSubscriptionOAuth(),
            ])
    }

    init(
        home: URL, providers: [Integration: any SubscriptionOAuthProvider],
        now: @escaping @Sendable () -> Date = { Date() },
        beforeLoginPersistence: (@Sendable (UUID) -> Void)? = nil,
        beforeDetectionPersistence: (@Sendable (Integration) async -> Void)? = nil,
        onLoginSuperseded: (@Sendable (Set<UUID>) -> Void)? = nil
    ) {
        self.directory = home.appendingPathComponent(".harness-usage/accounts", isDirectory: true)
        self.providers = providers
        self.now = now
        self.beforeLoginPersistence = beforeLoginPersistence
        self.beforeDetectionPersistence = beforeDetectionPersistence
        self.onLoginSuperseded = onLoginSuperseded
        do {
            try Self.prepareDirectory(directory)
            self.records = try Self.loadRecords(directory)
        } catch {
            self.records = [:]
            self.loadError = .persistenceFailed
        }
    }

    public nonisolated func makeMonitor(
        for integration: Integration, detectedMonitor: any IntegrationMonitor
    ) -> any IntegrationMonitor {
        SubscriptionAccountMonitor(integration: integration, detected: detectedMonitor, store: self)
    }

    public func setUpdateHandler(_ handler: (@Sendable (Integration) -> Void)?) {
        updateHandler = handler
    }

    public func availableIntegrations() -> Set<Integration> {
        Set(records.values.map(\.integration))
    }

    public func accountSnapshots() -> [SubscriptionAccountSnapshot] {
        records.values.map { record in
            let availableDetected = record.detectedSources.contains(where: \.isAvailable)
            let freshness: UsageFreshness =
                record.ownedHealthy
                ? .fresh
                : (availableDetected ? (record.credential == nil ? .fresh : .fallback) : .disconnected)
            let sources =
                (record.credential == nil
                    ? []
                    : [UsageAccountSource(kind: .owned, reference: "Harness Monitor", isAvailable: record.ownedHealthy)])
                + record.detectedSources
            return SubscriptionAccountSnapshot(
                integration: record.integration, account: record.account,
                key: UsageKey(record.integration, profile: record.canonicalKey),
                hasOwnedConnection: record.credential != nil, freshness: freshness,
                sources: sources, lastReading: record.lastReading, status: record.status)
        }.sorted { ($0.integration.rawValue, $0.account.suggestedName) < ($1.integration.rawValue, $1.account.suggestedName) }
    }

    public func beginLogin(
        for integration: Integration, reconnecting accountID: String? = nil
    ) async throws -> SubscriptionLogin {
        if let loadError { throw loadError }
        guard let provider = providers[integration], Integration.supportedCases.contains(integration) else {
            throw SubscriptionAccountError.unsupportedIntegration
        }
        let superseded = Set(pending.keys).union(completingLogins)
        if !superseded.isEmpty {
            canceledLogins.formUnion(completingLogins)
            for id in superseded { loginTasks[id]?.cancel() }
            pending = [:]
            onLoginSuperseded?(superseded)
        }
        try await synchronizeFromDisk()
        if let accountID,
            !records.values.contains(where: { $0.integration == integration && $0.account.id == accountID })
        {
            throw SubscriptionAccountError.accountNotFound
        }
        let id = UUID()
        let verifier = SubscriptionOAuthSecurity.randomToken()
        let state = SubscriptionOAuthSecurity.randomToken()
        let authorization = try provider.authorization(
            verifier: verifier, challenge: SubscriptionOAuthSecurity.challenge(for: verifier), state: state)
        pending[id] = PendingLogin(
            integration: integration, verifier: verifier, state: state,
            redirectURL: authorization.redirectURL, reconnectingAccountID: accountID)
        return SubscriptionLogin(id: id, authorizationURL: authorization.authorizationURL, redirectURL: authorization.redirectURL)
    }

    public func completeLogin(_ loginID: UUID, callbackURL: URL) async throws -> UsageAccount {
        guard let login = pending[loginID], let provider = providers[login.integration] else {
            throw SubscriptionAccountError.loginNotPending
        }
        let callback = try Self.validate(callbackURL, expectedRedirect: login.redirectURL, expectedState: login.state)
        // A structurally valid callback is single-use. Remove it before exchange so a replay cannot
        // start a second token request while the first request is suspended.
        pending[loginID] = nil
        completingLogins.insert(loginID)
        defer {
            completingLogins.remove(loginID)
            canceledLogins.remove(loginID)
            loginTasks[loginID] = nil
        }
        if callback.providerError { throw SubscriptionAccountError.providerRejectedLogin }
        guard let code = callback.code else { throw SubscriptionAccountError.invalidCallback }

        let task = Task {
            let credential = try await provider.exchange(
                code: code, verifier: login.verifier, state: login.state, redirectURL: login.redirectURL)
            do {
                return (credential, try await provider.identify(credential))
            } catch SubscriptionAccountError.identityUnavailable {
                return (
                    credential,
                    SubscriptionOAuthIdentity(
                        id: "unverified:\(loginID.uuidString.lowercased())", email: nil,
                        name: nil, plan: nil, verified: false)
                )
            }
        }
        loginTasks[loginID] = task
        let result: (SubscriptionOAuthCredential, SubscriptionOAuthIdentity)
        do { result = try await task.value } catch {
            if canceledLogins.contains(loginID) || Task.isCancelled {
                throw SubscriptionAccountError.loginNotPending
            }
            if let error = error as? SubscriptionAccountError { throw error }
            throw SubscriptionAccountError.tokenExchangeFailed
        }
        if canceledLogins.contains(loginID) { throw SubscriptionAccountError.loginNotPending }
        if let expected = login.reconnectingAccountID, expected != result.1.id {
            throw SubscriptionAccountError.reconnectIdentityMismatch
        }

        let account: UsageAccount
        do {
            beforeLoginPersistence?(loginID)
            let updated = try await withLockedRecords { latest -> (UsageAccount, UUID) in
                guard completingLogins.contains(loginID), !canceledLogins.contains(loginID) else {
                    throw SubscriptionAccountError.loginNotPending
                }
                if let expected = login.reconnectingAccountID,
                    !latest.values.contains(where: { $0.integration == login.integration && $0.account.id == expected })
                {
                    throw SubscriptionAccountError.accountNotFound
                }
                let existing = latest.values.first {
                    $0.integration == login.integration && $0.identity.id == result.1.id
                }
                let fileID = existing?.fileID ?? UUID()
                let account = UsageAccount(
                    id: result.1.id, email: result.1.email, plan: result.1.plan,
                    location: "Harness Monitor",
                    suggestedName: UsageAccount.automaticName(
                        reportedName: result.1.name, email: result.1.email,
                        fallback: existing?.account.suggestedName ?? login.integration.displayName))
                // Any completed account mutation supersedes detected work that began before it.
                // Persist this marker first so a failed invalidation cannot save a credential while
                // allowing an older detection pass to reconcile over it.
                try Self.advanceDetectionGeneration(for: login.integration, directory: directory)
                var record =
                    existing
                    ?? StoredRecord(
                        version: Self.version, fileID: fileID, integration: login.integration,
                        identity: result.1, account: account, canonicalKey: result.1.id,
                        credential: nil, lastReading: nil, status: nil, refreshUncertain: false,
                        holdUntil: nil, lastAttempt: nil, ownedHealthy: false, detectedSources: [])
                record.identity = result.1
                record.account = account
                record.credential = result.0
                record.refreshUncertain = false
                // Reconnect replaces credentials, not the provider's account-scoped Retry-After.
                // A newly created record has no hold; an existing identity keeps its server backoff.
                record.lastAttempt = nil
                record.status = result.1.verified ? nil : "Provider identity is incomplete; this connection cannot be deduplicated."
                record.ownedHealthy = false
                if record != existing { try Self.write(record, directory: directory) }
                latest[fileID] = record
                return (account, fileID)
            }
            account = updated.0
        } catch let error as SubscriptionAccountError {
            throw error
        } catch {
            throw SubscriptionAccountError.persistenceFailed
        }
        updateHandler?(login.integration)
        return account
    }

    public func cancelLogin(_ loginID: UUID) async {
        pending[loginID] = nil
        if completingLogins.contains(loginID) {
            canceledLogins.insert(loginID)
            loginTasks[loginID]?.cancel()
        }
    }

    public func removeConnection(for integration: Integration, accountID: String) async throws {
        let changed: Bool
        do {
            changed = try await withLockedRecords { latest -> Bool in
                guard var record = latest.values.first(where: { $0.integration == integration && $0.account.id == accountID }) else {
                    throw SubscriptionAccountError.accountNotFound
                }
                let hasAvailableDetectedSource = record.detectedSources.contains(where: \.isAvailable)
                // Detection remains authoritative for an active local-only account. When an owned login
                // also exists, removal drops only that app-owned credential and leaves the local source.
                guard record.credential != nil || !hasAvailableDetectedSource else {
                    throw SubscriptionAccountError.accountNotFound
                }
                try Self.advanceDetectionGeneration(for: integration, directory: directory)
                refreshTasks.removeValue(forKey: record.fileID)?.cancel()
                if hasAvailableDetectedSource {
                    record.credential = nil
                    record.ownedHealthy = false
                    record.refreshUncertain = false
                    record.status = nil
                    try Self.write(record, directory: directory)
                    latest[record.fileID] = record
                } else {
                    let url = Self.fileURL(record.fileID, directory: directory)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    latest[record.fileID] = nil
                }
                return true
            }
        } catch let error as SubscriptionAccountError {
            throw error
        } catch {
            throw SubscriptionAccountError.persistenceFailed
        }
        if changed { updateHandler?(integration) }
    }

    func invalidateThrottles(for integration: Integration) async {
        let changed = records.values.filter { $0.integration == integration }.reduce(into: false) { changed, record in
            guard record.lastAttempt != nil else { return }
            records[record.fileID]?.lastAttempt = nil
            changed = true
        }
        if changed {
            do { try await persistOwnedRuntime(for: integration) } catch { markPersistenceFailure(integration) }
        }
    }

    func applyAccountBackoffs(_ holds: [String: Date], integration: Integration) async {
        guard !holds.isEmpty else { return }
        var changed = false
        for id in records.keys {
            guard var record = records[id], record.integration == integration,
                let hold = holds[record.identity.id], hold > (record.holdUntil ?? .distantPast)
            else { continue }
            record.holdUntil = hold
            record.ownedHealthy = false
            record.status = "The provider is rate-limiting this account; retrying later."
            records[id] = record
            changed = true
        }
        if changed {
            do { try await persistOwnedRuntime(for: integration) } catch { markPersistenceFailure(integration) }
        }
    }

    func reload(
        integration: Integration, detected: [String?: UsageSnapshot]
    ) async -> [String?: UsageSnapshot] {
        await prepareOwned(
            integration: integration, policy: UsageReloadPolicy(interval: .fiveMinutes))
        return await resolve(integration: integration, detected: detected)
    }

    func prepareOwned(
        integration: Integration, policy: UsageReloadPolicy = UsageReloadPolicy(interval: .fiveMinutes)
    ) async {
        do { try await synchronizeFromDisk() } catch {
            markPersistenceFailure(integration)
            return
        }
        let ids = records.keys.filter { records[$0]?.integration == integration }
        for id in ids { await refreshOwned(id, policy: policy) }
    }

    func accountBackoffs(for integration: Integration) -> [String: Date] {
        let current = now()
        return Dictionary(
            uniqueKeysWithValues: records.values.compactMap { record in
                guard record.integration == integration, let hold = record.holdUntil, hold > current else { return nil }
                return (record.identity.id, hold)
            })
    }

    func resolve(
        integration: Integration, detected: [String?: UsageSnapshot]
    ) async -> [String?: UsageSnapshot] {
        guard let generation = await captureDetectionGeneration(for: integration) else {
            return retainedResolution(integration: integration)
        }
        return await resolve(integration: integration, detected: detected, generation: generation)
    }

    fileprivate func resolve(
        integration: Integration, detected: [String?: UsageSnapshot],
        generation: DetectionGeneration
    ) async -> [String?: UsageSnapshot] {
        do { try await synchronizeFromDisk() } catch { markPersistenceFailure(integration) }
        var detectedByIdentity: [String: [(String, UsageSnapshot)]] = [:]
        var unidentified: [String?: UsageSnapshot] = [:]
        for (profile, snapshot) in detected {
            let reference =
                snapshot.account?.location.isEmpty == false
                ? snapshot.account?.location ?? integration.rawValue
                : profile.map { "~/.\(integration.rawValue)-\($0)" } ?? "~/.\(integration.rawValue)"
            guard let account = snapshot.account else {
                var snapshot = snapshot
                snapshot.accountSources = [
                    UsageAccountSource(
                        kind: .detected, reference: reference,
                        isAvailable: snapshot.freshness != .disconnected)
                ]
                unidentified[profile] = snapshot
                continue
            }
            detectedByIdentity[account.id, default: []].append((reference, snapshot))
        }

        var proposed = records
        for (identity, matches) in detectedByIdentity
        where !proposed.values.contains(where: { $0.integration == integration && $0.identity.id == identity }) {
            guard let first = matches.first, let account = first.1.account else { continue }
            let id = UUID()
            proposed[id] = StoredRecord(
                version: Self.version, fileID: id, integration: integration,
                identity: SubscriptionOAuthIdentity(
                    id: identity, email: account.email, name: account.suggestedName,
                    plan: account.plan, verified: true),
                account: account, canonicalKey: identity, credential: nil,
                lastReading: first.1, status: nil, refreshUncertain: false,
                holdUntil: nil, lastAttempt: nil, ownedHealthy: false, detectedSources: [])
        }

        var usageRecords: [AccountUsageRecord] = []
        for id in proposed.keys where proposed[id]?.integration == integration {
            guard var record = proposed[id] else { continue }
            let matches = detectedByIdentity[record.identity.id] ?? []
            var sources = Dictionary(
                uniqueKeysWithValues: record.detectedSources.map {
                    ($0.reference, UsageAccountSource(kind: .detected, reference: $0.reference, isAvailable: false))
                })
            for match in matches {
                sources[match.0] = UsageAccountSource(
                    kind: .detected, reference: match.0,
                    isAvailable: match.1.freshness != .disconnected)
            }
            record.detectedSources = sources.values.sorted { $0.reference < $1.reference }
            let owned = record.ownedHealthy ? record.lastReading : nil
            let usageRecord = AccountUsageRecord(
                integration: integration, account: record.account,
                canonicalKey: record.canonicalKey, hasOwnedCredential: record.credential != nil,
                ownedAvailable: record.ownedHealthy, ownedSnapshot: owned,
                ownedStatus: record.status, detected: matches,
                rememberedDetectedSources: record.detectedSources,
                lastReading: record.lastReading)
            usageRecords.append(usageRecord)
            proposed[id] = record
        }

        var resolved = AccountUsageResolver.resolve(
            integration: integration, records: usageRecords, unidentifiedDetected: unidentified)
        for (profile, snapshot) in resolved {
            guard snapshot.activeAccountSource != .retained,
                let id = proposed.values.first(where: { $0.integration == integration && $0.canonicalKey == profile })?.fileID
            else { continue }
            guard var record = proposed[id] else { continue }
            record.lastReading = snapshot
            record.account = snapshot.account ?? record.account
            proposed[id] = record
        }

        let changed = proposed.filter { records[$0.key] != $0.value }
        do {
            records = try await persistDetectionChanges(changed, generation: generation)
        } catch DetectionCommitError.superseded {
            // A removal or login completed after this pass began. Its mutation owns the account
            // directory now; publishing this old detector result would resurrect or misattribute it.
            do { try await synchronizeFromDisk() } catch { markPersistenceFailure(integration) }
            return retainedResolution(integration: integration)
        } catch {
            markPersistenceFailure(integration)
            for key in resolved.keys where resolved[key]?.account != nil {
                resolved[key]?.note = SubscriptionAccountError.persistenceFailed.localizedDescription
            }
        }
        return resolved
    }

    private func refreshOwned(_ id: UUID, policy: UsageReloadPolicy) async {
        guard var record = records[id], let credential = record.credential,
            let provider = providers[record.integration]
        else { return }
        if record.refreshUncertain {
            record.ownedHealthy = false
            record.status = SubscriptionAccountError.reconnectRequired.localizedDescription
            records[id] = record
            return
        }
        if let hold = record.holdUntil, now() < hold {
            record.ownedHealthy = false
            record.status = "The provider is rate-limiting this account; retrying later."
            records[id] = record
            return
        }
        if !policy.bypassAppCadence, let attempted = record.lastAttempt,
            now().timeIntervalSince(attempted) < policy.interval.seconds
        {
            return
        }

        var usable = credential
        if credential.expiresAt <= now() {
            do { usable = try await refreshedRecord(id: id, provider: provider).credential ?? credential } catch {
                guard var current = records[id] else { return }
                current.ownedHealthy = false
                current.refreshUncertain = true
                current.status = SubscriptionAccountError.reconnectRequired.localizedDescription
                records[id] = current
                return
            }
            guard let current = records[id], current.credential == usable else { return }
            record = current
        }
        record.lastAttempt = now()
        records[id] = record
        switch await provider.usage(usable, identity: record.identity, now: now()) {
        case .success(var snapshot, let identity):
            guard identity.id == record.identity.id, var current = records[id], current.credential == usable else { return }
            current.identity = identity
            current.account = UsageAccount(
                id: identity.id, email: identity.email ?? current.account.email,
                plan: identity.plan ?? current.account.plan, location: "Harness Monitor",
                suggestedName: UsageAccount.automaticName(
                    reportedName: identity.name, email: identity.email,
                    fallback: current.account.suggestedName))
            snapshot.account = current.account
            current.lastReading = snapshot
            current.status = identity.verified ? nil : "Provider identity is incomplete; this connection cannot be deduplicated."
            current.ownedHealthy = true
            current.holdUntil = nil
            records[id] = current
        case .unauthorized:
            records[id]?.ownedHealthy = false
            records[id]?.status = SubscriptionAccountError.reconnectRequired.localizedDescription
        case .rateLimited(let until):
            records[id]?.ownedHealthy = false
            records[id]?.status = "The provider is rate-limiting this account; retrying later."
            records[id]?.holdUntil = until ?? now().addingTimeInterval(max(300, policy.interval.seconds))
        case .failed:
            records[id]?.ownedHealthy = false
            records[id]?.status = "Could not reach the provider usage endpoint."
        }
        do { try await persistOwnedState(id: id, expectedCredential: usable) } catch { markPersistenceFailure(record.integration) }
    }

    private func refreshedRecord(
        id: UUID, provider: any SubscriptionOAuthProvider
    ) async throws -> StoredRecord {
        if let task = refreshTasks[id] { return try await task.value }
        let directory = directory
        let refreshNow = now()
        let task = Task { () throws -> StoredRecord in
            let preparation = try await Self.prepareRefresh(id: id, directory: directory, now: refreshNow)
            switch preparation {
            case .adopt(let record): return record
            case .refresh(let record, let credential):
                let refreshed = try await provider.refresh(credential)
                let identity = try await provider.identify(refreshed)
                guard identity.id == record.identity.id else {
                    throw SubscriptionAccountError.reconnectIdentityMismatch
                }
                return try await Self.finishRefresh(
                    id: id, original: credential, refreshed: refreshed,
                    identity: identity, directory: directory)
            }
        }
        refreshTasks[id] = task
        defer { refreshTasks[id] = nil }
        let refreshed = try await task.value
        records = try await Self.readLocked(directory: directory)
        return records[id] ?? refreshed
    }

    private func persistOwnedState(id: UUID, expectedCredential: SubscriptionOAuthCredential) async throws {
        guard let proposed = records[id] else { return }
        try await withLockedRecords { latest in
            guard var current = latest[id], current.credential == expectedCredential else { return }
            current.identity = proposed.identity
            current.account = proposed.account
            current.lastReading = proposed.lastReading
            current.status = proposed.status
            current.holdUntil = proposed.holdUntil
            current.lastAttempt = proposed.lastAttempt
            current.ownedHealthy = proposed.ownedHealthy
            current.detectedSources = proposed.detectedSources
            if current != latest[id] { try Self.write(current, directory: directory) }
            latest[id] = current
        }
    }

    private func persistOwnedRuntime(for integration: Integration) async throws {
        let proposed = records
        try await withLockedRecords { latest in
            for id in latest.keys where latest[id]?.integration == integration {
                guard var current = latest[id], let source = proposed[id], current.credential == source.credential else { continue }
                current.status = source.status
                current.holdUntil = max(current.holdUntil ?? .distantPast, source.holdUntil ?? .distantPast)
                current.lastAttempt = source.lastAttempt
                current.ownedHealthy = source.ownedHealthy
                if current != latest[id] { try Self.write(current, directory: directory) }
                latest[id] = current
            }
        }
    }

    fileprivate func captureDetectionGeneration(for integration: Integration) async -> DetectionGeneration? {
        do {
            let lock = try await AsyncFileLock.acquire(directory: directory)
            defer { lock.unlock() }
            return DetectionGeneration(
                integration: integration,
                value: try Self.loadDetectionGenerations(directory)[integration.rawValue] ?? 0)
        } catch {
            markPersistenceFailure(integration)
            return nil
        }
    }

    fileprivate func disposition(
        for result: IntegrationReloadResult, integration: Integration
    ) async -> IntegrationReloadDisposition {
        guard let token = result.accountValidationToken,
            token.integration == integration, let generation = token.generation
        else {
            // Capture already built a marked retained view. Reuse it rather than immediately making
            // another lock/read attempt for the same failed reload.
            return .validationFailed(current: result.readings)
        }
        do {
            let lock = try await AsyncFileLock.acquire(directory: directory)
            defer { lock.unlock() }
            let currentGeneration = try Self.loadDetectionGenerations(directory)[integration.rawValue] ?? 0
            guard currentGeneration != generation else { return .accepted }
            records = try Self.loadRecords(directory)
            return .superseded(current: retainedResolution(integration: integration))
        } catch {
            return .validationFailed(
                current: await persistenceFailureResolution(integration: integration))
        }
    }

    fileprivate func persistenceFailureResolution(
        integration: Integration
    ) async -> [String?: UsageSnapshot] {
        // Reload account records independently from the broken generation marker whenever possible.
        // That preserves retained rows without reviving an identity another process already deleted.
        if let latest = try? await Self.readLocked(directory: directory) { records = latest }
        markPersistenceFailure(integration)
        var current = retainedResolution(integration: integration)
        for key in current.keys where current[key]?.account != nil {
            current[key]?.note = SubscriptionAccountError.persistenceFailed.localizedDescription
        }
        return current
    }

    private func persistDetectionChanges(
        _ changed: [UUID: StoredRecord], generation: DetectionGeneration
    ) async throws -> [UUID: StoredRecord] {
        if let beforeDetectionPersistence { await beforeDetectionPersistence(generation.integration) }
        return try await withLockedRecords { latest -> [UUID: StoredRecord] in
            let currentGeneration = try Self.loadDetectionGenerations(directory)[generation.integration.rawValue] ?? 0
            guard currentGeneration == generation.value else { throw DetectionCommitError.superseded }
            for (id, proposed) in changed {
                if var current = latest[id] {
                    current.detectedSources = proposed.detectedSources
                    if proposed.lastReading?.activeAccountSource != .retained { current.lastReading = proposed.lastReading }
                    current.account = proposed.account
                    if current != latest[id] { try Self.write(current, directory: directory) }
                    latest[id] = current
                } else if proposed.credential == nil {
                    try Self.write(proposed, directory: directory)
                    latest[id] = proposed
                }
            }
            return latest
        }
    }

    fileprivate func retainedResolution(integration: Integration) -> [String?: UsageSnapshot] {
        let usageRecords = records.values.filter { $0.integration == integration }.map { record in
            AccountUsageRecord(
                integration: integration, account: record.account,
                canonicalKey: record.canonicalKey, hasOwnedCredential: record.credential != nil,
                ownedAvailable: record.ownedHealthy,
                ownedSnapshot: record.ownedHealthy ? record.lastReading : nil,
                ownedStatus: record.status, detected: [],
                rememberedDetectedSources: record.detectedSources,
                lastReading: record.lastReading)
        }
        return AccountUsageResolver.resolve(
            integration: integration, records: usageRecords, unidentifiedDetected: [:])
    }

    private func synchronizeFromDisk() async throws {
        records = try await Self.readLocked(directory: directory)
    }

    private func withLockedRecords<T: Sendable>(
        _ body: (inout [UUID: StoredRecord]) throws -> T
    ) async throws -> T {
        let lock = try await AsyncFileLock.acquire(directory: directory)
        defer { lock.unlock() }
        var latest = try Self.loadRecords(directory)
        let result = try body(&latest)
        records = latest
        return result
    }

    private static func readLocked(directory: URL) async throws -> [UUID: StoredRecord] {
        let lock = try await AsyncFileLock.acquire(directory: directory)
        defer { lock.unlock() }
        return try loadRecords(directory)
    }

    private static func prepareRefresh(
        id: UUID, directory: URL, now: Date
    ) async throws -> RefreshPreparation {
        let lock = try await AsyncFileLock.acquire(directory: directory)
        defer { lock.unlock() }
        guard var record = try loadRecords(directory)[id], let credential = record.credential else {
            throw SubscriptionAccountError.accountNotFound
        }
        if credential.expiresAt > now { return .adopt(record) }
        if record.refreshUncertain { throw SubscriptionAccountError.reconnectRequired }
        // Persist intent before the request. If the process dies after the provider consumes the
        // rotating token, restart sees this flag and requires reconnect instead of replaying it.
        record.refreshUncertain = true
        record.ownedHealthy = false
        record.status = SubscriptionAccountError.reconnectRequired.localizedDescription
        try write(record, directory: directory)
        return .refresh(record, credential)
    }

    private static func finishRefresh(
        id: UUID, original: SubscriptionOAuthCredential, refreshed: SubscriptionOAuthCredential,
        identity: SubscriptionOAuthIdentity, directory: URL
    ) async throws -> StoredRecord {
        let lock = try await AsyncFileLock.acquire(directory: directory)
        defer { lock.unlock() }
        guard var current = try loadRecords(directory)[id] else { throw SubscriptionAccountError.accountNotFound }
        // A remove or reconnect completed during the request. Its mutation owns the record now.
        guard current.credential == original, current.refreshUncertain else { return current }
        current.credential = refreshed
        current.identity = identity
        current.account = UsageAccount(
            id: identity.id, email: identity.email ?? current.account.email,
            plan: identity.plan ?? current.account.plan, location: "Harness Monitor",
            suggestedName: UsageAccount.automaticName(
                reportedName: identity.name, email: identity.email,
                fallback: current.account.suggestedName))
        current.refreshUncertain = false
        current.status = nil
        try write(current, directory: directory)
        return current
    }

    private func markPersistenceFailure(_ integration: Integration) {
        for id in records.keys where records[id]?.integration == integration {
            records[id]?.status = SubscriptionAccountError.persistenceFailed.localizedDescription
            records[id]?.ownedHealthy = false
        }
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, S_IRWXU) == 0 else { throw SubscriptionAccountError.persistenceFailed }
    }

    private static func loadRecords(_ directory: URL) throws -> [UUID: StoredRecord] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [UUID: StoredRecord] = [:]
        for file in files where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(StoredRecord.self, from: Data(contentsOf: file))
            guard record.version == version, record.fileID.uuidString.lowercased() == file.deletingPathExtension().lastPathComponent else { continue }
            result[record.fileID] = record
        }
        return result
    }

    private static func write(_ record: StoredRecord, directory: URL) throws {
        let url = fileURL(record.fileID, directory: directory)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw SubscriptionAccountError.persistenceFailed }
    }

    private static func fileURL(_ id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private static func detectionGenerationsURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(".detection-generations")
    }

    private static func loadDetectionGenerations(_ directory: URL) throws -> [String: UInt64] {
        let url = detectionGenerationsURL(directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode(
            StoredDetectionGenerations.self, from: Data(contentsOf: url)
        ).values
    }

    private static func advanceDetectionGeneration(
        for integration: Integration, directory: URL
    ) throws {
        var generations = try loadDetectionGenerations(directory)
        let current = generations[integration.rawValue] ?? 0
        guard current < UInt64.max else { throw SubscriptionAccountError.persistenceFailed }
        generations[integration.rawValue] = current + 1
        let url = detectionGenerationsURL(directory)
        try JSONEncoder().encode(StoredDetectionGenerations(values: generations))
            .write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw SubscriptionAccountError.persistenceFailed
        }
    }

    private static func validate(
        _ callbackURL: URL, expectedRedirect: URL, expectedState: String
    ) throws -> (code: String?, providerError: Bool) {
        guard callbackURL.scheme == expectedRedirect.scheme,
            callbackURL.host?.lowercased() == expectedRedirect.host?.lowercased(),
            callbackURL.port == expectedRedirect.port, callbackURL.path == expectedRedirect.path,
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        else { throw SubscriptionAccountError.invalidCallback }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else {
            throw states.count == 1 ? SubscriptionAccountError.stateMismatch : SubscriptionAccountError.invalidCallback
        }
        let codes = items.filter { $0.name == "code" }
        let errors = items.filter { $0.name == "error" }
        guard errors.count <= 1, codes.count <= 1, errors.isEmpty != codes.isEmpty else {
            throw SubscriptionAccountError.invalidCallback
        }
        if let code = codes.first {
            guard let value = code.value, !value.isEmpty else { throw SubscriptionAccountError.invalidCallback }
            return (value, false)
        }
        guard let error = errors.first, error.value?.isEmpty == false else {
            throw SubscriptionAccountError.invalidCallback
        }
        return (nil, true)
    }
}

private final class AsyncFileLock: @unchecked Sendable {
    // Policy: account mutations wait at most 30 seconds for another app instance and retry every
    // 10 ms without blocking a cooperative executor thread. Provider HTTP has its own 30-second cap.
    private static let waitLimit: Duration = .seconds(30)
    private static let retryDelay: Duration = .milliseconds(10)
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(directory: URL) async throws -> AsyncFileLock {
        try Task.checkCancellation()
        let path = directory.appendingPathComponent(".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SubscriptionAccountError.persistenceFailed }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN, ContinuousClock.now < deadline else {
                close(descriptor)
                throw SubscriptionAccountError.persistenceFailed
            }
            do { try await Task.sleep(for: retryDelay) } catch {
                close(descriptor)
                throw CancellationError()
            }
        }
        do { try Task.checkCancellation() } catch {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
        return AsyncFileLock(descriptor: descriptor)
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }
}

private struct SubscriptionAccountMonitor: IntegrationMonitor {
    let integration: Integration
    let detected: any IntegrationMonitor
    let store: SubscriptionAccountStore

    nonisolated var watchPaths: [URL] { detected.watchPaths }
    nonisolated var pollInterval: TimeInterval? { detected.pollInterval }

    func reload(wantUsageEstimate: Bool) async -> UsageSnapshot? {
        let defaultLogin: String? = nil
        return await reloadProfiles(wantUsageEstimate: wantUsageEstimate, includeDetected: true)[defaultLogin]
    }

    func reloadProfiles(wantUsageEstimate: Bool) async -> [String?: UsageSnapshot] {
        await reloadProfiles(wantUsageEstimate: wantUsageEstimate, includeDetected: true)
    }

    func reloadProfiles(wantUsageEstimate: Bool, includeDetected: Bool) async -> [String?: UsageSnapshot] {
        await reloadProfiles(
            wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
            policy: UsageReloadPolicy(interval: .fiveMinutes))
    }

    func reloadProfiles(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> [String?: UsageSnapshot] {
        await accountReload(
            wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
            policy: policy
        ).readings
    }

    func reloadForEngine(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> IntegrationReloadResult {
        await accountReload(
            wantUsageEstimate: wantUsageEstimate, includeDetected: includeDetected,
            policy: policy)
    }

    func disposition(for result: IntegrationReloadResult) async -> IntegrationReloadDisposition {
        await store.disposition(for: result, integration: integration)
    }

    private func accountReload(
        wantUsageEstimate: Bool, includeDetected: Bool, policy: UsageReloadPolicy
    ) async -> IntegrationReloadResult {
        // Carry server backoff in both directions. A detected 429 learned on the prior tick blocks
        // owned before it can request; an owned 429 blocks detected before this tick's local reload.
        await store.applyAccountBackoffs(await detected.accountBackoffs(), integration: integration)
        await store.prepareOwned(integration: integration, policy: policy)
        await detected.applyAccountBackoffs(await store.accountBackoffs(for: integration))
        guard let generation = await store.captureDetectionGeneration(for: integration) else {
            return IntegrationReloadResult(
                readings: await store.persistenceFailureResolution(integration: integration),
                accountValidationToken: AccountReloadValidationToken(
                    integration: integration, generation: nil))
        }
        let readings =
            includeDetected
            ? await detected.reloadProfiles(
                wantUsageEstimate: wantUsageEstimate, includeDetected: true, policy: policy)
            : [:]
        await store.applyAccountBackoffs(await detected.accountBackoffs(), integration: integration)
        let resolved = await store.resolve(
            integration: integration, detected: readings, generation: generation)
        return IntegrationReloadResult(
            readings: resolved,
            accountValidationToken: AccountReloadValidationToken(
                integration: integration, generation: generation.value))
    }

    func invalidateThrottles() async {
        await detected.invalidateThrottles()
        await store.invalidateThrottles(for: integration)
    }
}
