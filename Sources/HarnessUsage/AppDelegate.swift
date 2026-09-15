import AppKit
import HarnessUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private var windows: WindowManager?
    private var notch: NotchWindowController?
    private var accountNames: AccountNamePrompt?
    private var login: AccountLoginController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Every surface is dark glass, so the app is dark — pinned once here, before any window
        // exists, rather than per window. The old objection to a global override was that it cascaded
        // into the status bar buttons; there are none now.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // WindowServer drops NSCursor writes from a non-active app; opt this connection out up front
        // (before any panel exists) so hover cursors work while the user's editor stays frontmost.
        BackgroundCursor.enable()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let isMock = CommandLine.arguments.contains("--mock")

        // Mock mode backs the settings store with a throwaway UserDefaults suite, wiped at launch, so
        // faking every integration on never writes into the user's real preferences (.standard).
        let defaults = isMock ? Self.mockDefaults() : .standard
        let settings = SettingsStore(defaults: defaults)
        let integrationStore = IntegrationStore(home: home)

        if !isMock {
            integrationStore.refresh()
            Self.ensureMeta(home: home)
        }

        // One subscription store for the process, shared by the engine and Settings. Mock mode stays
        // isolated: no store, no account monitors, so a mock run never touches ~/.harness-usage.
        let accounts: SubscriptionAccountStore? = isMock ? nil : SubscriptionAccountStore(home: home)

        // The monitor map is built generically off the per-integration descriptors — adding an agent
        // (a new case + folder + registry line) needs no change here. Mock mode swaps in MockMonitor.
        // Only supported integrations are initialized: suspended cases keep their code and stored
        // settings but get no monitor, so the engine never reads their credentials. Real monitors
        // are wrapped so an app-owned connection is preferred over its matching detected folder.
        let monitors: [Integration: any IntegrationMonitor]
        if isMock {
            let mockDir = Self.mockDataDir()
            monitors = Dictionary(
                uniqueKeysWithValues:
                    Integration.supportedCases.map { ($0, MockMonitor(integration: $0, mockDir: mockDir) as any IntegrationMonitor) })
        } else {
            let store = accounts
            monitors = Dictionary(
                uniqueKeysWithValues: Integration.supportedCases.map {
                    let detected = $0.descriptor.makeMonitor(home: home)
                    // Non-nil outside mock: the store is created for every non-mock run above.
                    return ($0, store?.makeMonitor(for: $0, detectedMonitor: detected) ?? detected)
                })
        }

        // Mock passes integrations: nil so the Engine's 30s detection refresh never runs against the
        // real home directory. Every consumer of a nil store falls back to "all detected" — the Engine,
        // this delegate's `render()` and the Settings pane — which is what fakes the agents in.
        let engine = Engine(
            monitors: monitors,
            usage: UsageStore(),
            settings: settings,
            integrations: isMock ? nil : integrationStore,
            accounts: accounts)

        self.engine = engine
        // The login controller owns the browser/listener lifecycle and the snapshot list. Mutations
        // wake the engine through the store's own update handler; snapshot refresh rides the render
        // loop (cheap, eventually consistent) so this delegate never races the engine's handler.
        let login = AccountLoginController(accounts: accounts) { [weak self] in self?.render() }
        self.login = login
        if accounts != nil {
            Task { await login.reload() }
        }
        let accountNames = AccountNamePrompt(settings: engine.settings)
        self.accountNames = accountNames
        let windows = WindowManager(
            usage: engine.usage, settings: engine.settings, integrations: engine.integrations,
            login: login,
            onRenameAccount: { accountNames.rename($0, integration: $1) })
        self.windows = windows
        let notch = NotchWindowController(usage: engine.usage, settings: engine.settings)
        notch.onOpenSettings = { windows.toggleSettings() }
        notch.onRefresh = { [weak engine] in await engine?.refreshNow() }
        self.notch = notch

        observe()
        render()
        engine.start()

        if CommandLine.arguments.contains("--show-settings") { windows.toggleSettings() }
    }

    // MARK: notch

    // The notch is the app's only surface, so this is the whole render loop: watch the three stores it
    // draws from and hand it a fresh provider list on every change. Observation tracking is one-shot,
    // so each pass re-arms itself.
    private func observe() {
        withObservationTracking {
            _ = engine?.usage.readings
            _ = engine?.settings.settings
            _ = engine?.integrations?.detected
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observe()
            }
        }
    }

    // Detection is the gate, exactly as it is for the Settings panes: a harness that is not on this Mac
    // has no ring — unless a remembered subscription stands behind it, which is the account half of
    // the union. Account-only providers show their account rings with no phantom default.
    private func render() {
        guard let engine, let notch else { return }
        // Before the providers are built: the card's measured size and the notch's own geometry both
        // read this, and a stale value would size the panel for the previous setting.
        Design.multiplier = engine.settings.settings.notchScale
        // Mock mode passes `integrations: nil`, so nothing detects anything there — fake them all in.
        let detected = engine.integrations?.detected ?? Set(Integration.supportedCases)
        let accountAvailable = login?.accountIntegrations ?? []
        notch.apply(
            providers: NotchProvider.all(
                usage: engine.usage, settings: engine.settings, detected: detected,
                accountAvailable: accountAvailable))
        notch.show()
        accountNames?.review(engine.usage.readings)
        if let login {
            Task { await login.reload() }
        }
    }

    // An accessory app has no Dock icon and no windows of its own, so re-launching it (double-clicking
    // the .app, or opening it from Spotlight) would otherwise do nothing at all — the escape hatch if
    // the notch is ever not on screen. Return false: we present the window ourselves.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows?.toggleSettings()
        return false
    }

    // A throwaway UserDefaults suite for --mock, wiped at launch so a mock run never persists into the
    // user's real preferences. Falls back to .standard only if the suite can't be created — never in
    // practice, since the name is neither the bundle id nor a global domain.
    static func mockDefaults() -> UserDefaults {
        let suite = "harness-usage.mock"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // The MockData directory: bundled in the .app (Contents/Resources/MockData) for release, or the
    // repo's MockData/ for dev builds (resolved relative to the executable).
    static func mockDataDir() -> URL {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("MockData"),
            FileManager.default.fileExists(atPath: res.path)
        {
            return res
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("../../MockData").standardizedFileURL
    }

    // Ensure ~/.harness-usage/settings.json exists with a schema version stamp, for future migrations.
    // Written once (never overwritten) so a hand-edited or future-version file is left alone.
    private static func ensureMeta(home: URL) {
        let meta = home.appendingPathComponent(".harness-usage/settings.json")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: meta.path) else { return }
        try? fm.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = "{\"version\":1}\n"
        try? payload.data(using: .utf8)?.write(to: meta, options: .atomic)
    }
}
