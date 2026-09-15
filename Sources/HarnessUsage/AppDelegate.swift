import AppKit
import HarnessUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private var windows: WindowManager?
    private var notch: NotchWindowController?
    // The tracked accounts, in `accounts.json` order — the list every surface draws from.
    private var accounts: [Integration] = []

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

        // The tracked accounts — one ring each — from `~/.harness-usage/accounts.json`, seeded on a
        // first launch with one local account per harness. Everything downstream is keyed by account,
        // so this list is the app's shape.
        if !isMock { AccountsFile.seedIfAbsent(at: Accounts.configuredURL) }
        let accounts = isMock ? AccountsFile.defaults : Accounts.configured

        let settings = SettingsStore(defaults: defaults, accounts: accounts.map(\.integration))
        let integrationStore = IntegrationStore(home: home, accounts: accounts)

        if !isMock {
            integrationStore.refresh()
            Self.ensureMeta(home: home)
        }

        // The monitor map is built generically off the per-harness descriptors — adding an agent
        // (a new case + folder + registry line) needs no change here, and neither does adding an
        // account. Mock mode swaps in MockMonitor.
        let monitors: [Integration: any IntegrationMonitor]
        if isMock {
            let mockDir = Self.mockDataDir()
            monitors = Dictionary(
                uniqueKeysWithValues:
                    accounts.map {
                        ($0.integration, MockMonitor(integration: $0.integration, mockDir: mockDir) as any IntegrationMonitor)
                    })
        } else {
            monitors = makeMonitors(accounts: accounts, home: home)
        }
        self.accounts = accounts.map(\.integration)

        // Mock passes integrations: nil so the Engine's 30s detection refresh never runs against the
        // real home directory. Every consumer of a nil store falls back to "all detected" — the Engine,
        // this delegate's `render()` and the Settings pane — which is what fakes the agents in.
        let engine = Engine(
            monitors: monitors,
            usage: UsageStore(),
            settings: settings,
            integrations: isMock ? nil : integrationStore)

        self.engine = engine
        let windows = WindowManager(
            usage: engine.usage, settings: engine.settings, integrations: engine.integrations,
            accounts: accounts,
            onAccountSourceChanged: { [weak engine] integration in
                guard let engine,
                    let account = AccountsFile.load(at: Accounts.configuredURL)?.first(where: {
                        $0.integration == integration
                    })
                else { return }
                let monitor = account.harness.descriptor.makeMonitor(home: home, account: account)
                await engine.replaceMonitor(monitor, for: integration)
            },
            onAddSubscription: { harness in
                guard AccountsFile.addSubscription(harness: harness, at: Accounts.configuredURL) != nil else { return }
                Self.relaunch()
            },
            onDeleteSubscription: { integration in
                guard AccountsFile.removeSubscription(integration, at: Accounts.configuredURL) else { return }
                Self.relaunch()
            })
        self.windows = windows
        let notch = NotchWindowController(
            usage: engine.usage, settings: engine.settings, accounts: self.accounts)
        notch.onOpenSettings = { windows.toggleSettings() }
        notch.onRefresh = { [weak engine] in await engine?.refreshNow() }
        self.notch = notch

        observe()
        render()
        engine.start()

        if CommandLine.arguments.contains("--show-settings") { windows.toggleSettings() }
    }

    private static func relaunch() {
        let launch = NSWorkspace.OpenConfiguration()
        launch.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: launch) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: notch

    // The notch is the app's only surface, so this is the whole render loop: watch the three stores it
    // draws from and hand it a fresh provider list on every change. Observation tracking is one-shot,
    // so each pass re-arms itself.
    private func observe() {
        withObservationTracking {
            _ = engine?.usage.byIntegration
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
    // has no ring. The data is handed over before the panel is shown, so it is sized for the list it
    // will actually draw rather than placed empty and resized a frame later.
    private func render() {
        guard let engine, let notch else { return }
        // Before the providers are built: the card's measured size and the notch's own geometry both
        // read this, and a stale value would size the panel for the previous setting.
        Design.multiplier = engine.settings.settings.notchScale
        // Mock mode passes `integrations: nil`, so nothing detects anything there — fake them all in.
        let detected = engine.integrations?.detected ?? Set(accounts)
        notch.apply(
            providers: NotchProvider.all(
                accounts, usage: engine.usage, settings: engine.settings, detected: detected))
        notch.show()
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
