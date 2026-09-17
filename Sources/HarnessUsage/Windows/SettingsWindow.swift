import AppKit
import HarnessUsageCore
import SwiftUI
import UniformTypeIdentifiers

// The Settings window: the app's one glass (`glassChrome`) and its one `cs*` palette, in a
// macOS-preferences layout — a sidebar of panes over the version line, and a content area of grouped
// setting cards. Every control binds to `SettingsStore`.
@MainActor struct SettingsWindow: View {
    let settings: SettingsStore
    var integrations: IntegrationStore?
    var usage: UsageStore?
    /// The tracked accounts, in `accounts.json` order — one pane each, after General. Passed in
    /// rather than read from `Accounts`, so `--mock` shows the mock accounts.
    let accounts: [AccountConfig]
    let controllerAudit: ControllerAuditStore
    var onAccountsChanged: @MainActor () async -> Void = {}
    var onAddSubscription: @MainActor (Harness) -> Void = { _ in }
    var onDeleteSubscription: @MainActor (Integration) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var pane: Pane = .general

    // The window's one size, owned here because this view is what has to fit in it. `WindowManager`
    // reads it to pre-empt the hosting controller's asynchronous `preferredContentSize` before it
    // centres the window.
    static let contentSize = NSSize(width: 728, height: 690)

    var body: some View {
        let _ = settings.settings  // anchor @Observable tracking so the window re-renders on any change
        VStack(spacing: 0) {
            GlassHeader(title: "Settings") {
                GhostIconButton(systemName: "xmark", hoverTint: .csRed, action: onClose)
            }
            HStack(spacing: 0) {
                sidebar
                contentPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .glassChrome()
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(panes) { sidebarRow($0) }
            HStack(spacing: 5) {
                Button("+ Claude") { onAddSubscription(.claude) }
                Button("+ Codex") { onAddSubscription(.codex) }
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.csAccent)
            .padding(.top, 5)
            Spacer(minLength: 8)
            Text("Harness Usage · \(Self.version)")
                .font(.system(size: 10))
                .foregroundStyle(Color.csFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .padding(9)
        .frame(width: 166)
        .frame(maxHeight: .infinity)  // fill height so the Spacer pins the version line to the bottom
        .background(Color.csSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.csDivider).frame(width: 1)
        }
    }

    private func sidebarRow(_ item: Pane) -> some View {
        let selected = item == pane
        return Button {
            pane = item
        } label: {
            HStack(spacing: 8) {
                iconTile(item, selected: selected)
                Text(item.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.csTitle : Color.csLabel)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.csSidebarSel : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private func iconTile(_ item: Pane, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.csAccent : Color.csTile)
            .frame(width: 23, height: 23)
            .overlay {
                switch item {
                case .general:
                    Image(systemName: "house.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.csOnAccent : Color.csLabel)
                case .provider(let account):
                    // The provider's own mark in its own colors, selected or not — the accent tile is
                    // the selection signal; repainting the mark would only blur it. A selected tile is
                    // a light surface, so an adaptive mark inverts against the TILE, not the window.
                    BrandMark(
                        integration: account.integration, size: 20, tint: account.integration.descriptor.brandColor,
                        colorSchemeOverride: selected ? .light : nil)
                }
            }
    }

    // "v1.2.3" from a real bundle; an unbundled dev build has no Info.plist, so it says so plainly
    // rather than rendering "vdev".
    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"
    }

    // MARK: content

    private var contentPane: some View {
        ScrollView {
            Group {
                switch pane {
                case .general:
                    GeneralPane(settings: settings)
                case .provider(let account):
                    ProviderPane(
                        settings: settings, account: account, accounts: accounts,
                        controllerAudit: controllerAudit,
                        integrations: integrations, usage: usage,
                        onAccountsChanged: onAccountsChanged,
                        canDelete: accounts.filter { $0.harness == account.harness }.count > 1,
                        onDeleteSubscription: onDeleteSubscription)
                }
            }
            .id(pane.id)
            .padding(.top, 15)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: panes

    private enum Pane: Equatable, Identifiable {
        case general
        case provider(AccountConfig)

        var id: String {
            switch self {
            case .general: "general"
            case .provider(let account): "provider-\(account.integration.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .general: "General"
            // `displayName` carries the account label once a harness has more than one, so two
            // Claude panes read "Claude · Personal" and "Claude · Work" rather than twice the same.
            case .provider(let account): account.integration.displayName
            }
        }
    }

    private var panes: [Pane] {
        [.general] + accounts.map(Pane.provider)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    let settings: SettingsStore
    // Seeded from SMAppService, which IS the store of record — there is no persisted copy to disagree
    // with it, so a login item removed in System Settings shows as off here on the next open.
    @State private var launchAtLogin = LoginItem.isRegistered
    @State private var loginRefused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Startup") {
                SettingsRow("Launch at login", subtitle: launchSubtitle) {
                    SettingsToggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                        .disabled(LoginItem.unavailableReason != nil)
                        .opacity(LoginItem.unavailableReason == nil ? 1 : 0.5)
                }
            }
            SettingsGroup("Notch") {
                SettingsRow("Size") {
                    SettingsSlider(
                        value: settings.bind(\.notchScale), range: Settings.notchScaleRange,
                        step: Settings.notchScaleStep,
                        label: { "\(Int(($0 * 100).rounded()))%" })
                }
                GlassDivider()
                SettingsRow("Show card") {
                    PopupControl(
                        options: [("On hover", CardTrigger.hover), ("On click", .click)],
                        selection: settings.bind(\.cardTrigger), accessibilityLabel: "Show card")
                }
            }
            SettingsGroup("Card") {
                SettingsRow("Layout") {
                    PopupControl(
                        options: [
                            ("Minimal", .simple), ("Linear", UsageLayout.linear),
                            ("Dot-matrix", .dotMatrix), ("Spotlight", .spotlight),
                        ],
                        selection: settings.bind(\.usageLayout), accessibilityLabel: "Layout")
                }
            }
            SettingsGroup("Alert thresholds") {
                SettingsRow("Warning at", subtitle: "Meter turns amber above this") {
                    SettingsSlider(
                        value: Binding(
                            get: { settings.settings.warningAt },
                            set: { v in
                                var s = settings.settings
                                s.warningAt = min(v, s.criticalAt - 1)  // keep warning strictly below critical
                                settings.update(s)
                            }), range: Settings.thresholdRange)
                }
                GlassDivider()
                SettingsRow("Critical at", subtitle: "Meter turns red above this") {
                    SettingsSlider(
                        value: Binding(
                            get: { settings.settings.criticalAt },
                            set: { v in
                                var s = settings.settings
                                s.criticalAt = max(v, s.warningAt + 1)  // keep critical strictly above warning
                                settings.update(s)
                            }), range: Settings.thresholdRange)
                }
            }
        }
        .onAppear { launchAtLogin = LoginItem.isRegistered }
    }

    private var launchSubtitle: String? {
        if let unavailable = LoginItem.unavailableReason { return unavailable }
        if loginRefused { return "macOS refused the change — check Login Items in System Settings." }
        return "Open automatically when you sign in"
    }

    // Reflects what was asked for, not a fresh `status` read: SMAppService settles its status
    // asynchronously, so re-reading here snaps the switch back — and because that write re-enters this
    // setter, it then unregisters the item it has just registered (mac-utils hit exactly this).
    private func setLaunchAtLogin(_ on: Bool) {
        guard LoginItem.setEnabled(on) else {
            loginRefused = true
            return
        }
        loginRefused = false
        launchAtLogin = on
    }

}

private struct ProviderPane: View {
    let settings: SettingsStore
    let account: AccountConfig
    let accounts: [AccountConfig]
    var integrations: IntegrationStore?
    var usage: UsageStore?
    var onAccountsChanged: @MainActor () async -> Void
    let canDelete: Bool
    var onDeleteSubscription: @MainActor (Integration) -> Void
    @State private var remote = false
    @State private var remoteServer = ""
    @State private var tokenLocation = ""
    @State private var remoteLogin = RemoteLogin()
    @State private var remoteLoginResponse = ""
    @State private var sourceSaved = false
    @State private var assignedSourceRaw = ""
    /// The controller flow — eligibility, preflight, confirmation and audit — lives in Core; this
    /// pane only presents it.
    @State private var controller: CredentialControllerSession

    private var integration: Integration { account.integration }

    init(
        settings: SettingsStore, account: AccountConfig, accounts: [AccountConfig],
        controllerAudit: ControllerAuditStore,
        integrations: IntegrationStore?, usage: UsageStore?,
        onAccountsChanged: @escaping @MainActor () async -> Void,
        canDelete: Bool, onDeleteSubscription: @escaping @MainActor (Integration) -> Void
    ) {
        self.settings = settings
        self.account = account
        self.accounts = accounts
        self.integrations = integrations
        self.usage = usage
        self.onAccountsChanged = onAccountsChanged
        self.canDelete = canDelete
        self.onDeleteSubscription = onDeleteSubscription
        _remote = State(initialValue: account.host.isRemote)
        _remoteServer = State(initialValue: account.host.sshAlias ?? "")
        _tokenLocation = State(initialValue: account.configDir ?? "~/\(account.harness.descriptor.homeRelativePath)")
        _assignedSourceRaw = State(initialValue: account.source(in: accounts).integration.rawValue)
        _controller = State(
            initialValue: CredentialControllerSession(
                account: account, accounts: accounts, audit: controllerAudit))
    }

    private func detected(_ i: Integration) -> Bool { integrations?.detected.contains(i) ?? true }

    // The row's second line, or nil for the ordinary case. An undetected harness says so; a detected
    // one speaks only when its last read failed (expired login, unreachable endpoint), which is how a
    // tier that silently never fires names itself.
    private func hint(_ i: Integration) -> String? {
        detected(i) ? usage?[i]?.note : "Not detected on this Mac"
    }

    private var supportsTokens: Bool { integration.descriptor.reportsTokens }

    private var tokenSubtitle: String {
        supportsTokens ? "Today's tokens in, out, and total below the meters" : "This agent doesn't report token counts"
    }

    private var loginProfiles: [AccountConfig] { accounts.filter { $0.harness == account.harness } }

    private var assignedSource: AccountConfig {
        loginProfiles.first { $0.integration.rawValue == assignedSourceRaw } ?? account
    }

    private func profileName(_ profile: AccountConfig) -> String {
        profile.label.isEmpty ? profile.harness.displayName : profile.label
    }

    private var remoteActionOptions: [(String, CredentialControllerSession.Action)] {
        [
            ("Exchange both", .exchange),
            ("Use \(profileName(account)) in both", .useOwnInBoth),
            ("Use \(controller.partner.map(profileName) ?? "other") in both", .usePartnerInBoth),
        ]
    }

    /// The confirmation copy for whatever the preflight staged.
    private var pendingActionTitle: String {
        guard let pending = controller.pending else { return "" }
        let other = profileName(pending.partner)
        if pending.restoring != nil { return "Restore the original remote logins?" }
        switch pending.action {
        case .exchange: return "Exchange \(profileName(account)) and \(other)?"
        case .useOwnInBoth: return "Use \(profileName(account)) in both remote profiles?"
        case .usePartnerInBoth: return "Use \(other) in both remote profiles?"
        }
    }

    private var pendingActionMessage: String {
        guard let pending = controller.pending else { return "" }
        if pending.restoring != nil {
            return "The saved credential files will be put back in their original profile directories. Restart the affected Claude sessions afterward."
        }
        return "Harness will back up both credentials and account metadata on \(account.host.sshAlias ?? "the SSH box"), then apply this action. Restart affected Claude sessions to use the new login."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let capNames = orderedUnique((usage?[integration]?.windows ?? []).compactMap { $0.kind.modelName })
            // Split by what the switch reaches, not by surface: Extra changes the ring, the "Notch
            // shows" options and the card's rows alike, so it sits with the provider-wide switches.
            SettingsGroup("Provider") {
                // Detection and read failures are the row's subtitle, which is how a tier that
                // silently never fires names itself. Detection is also the gate: a harness that is not
                // on this Mac has nothing to enable, so the switch is dead rather than storing a
                // preference the filesystem overrules.
                SettingsRow("Enabled", subtitle: hint(integration)) {
                    SettingsToggle(isOn: settings.providerBind(integration, \.visible))
                        .disabled(!detected(integration))
                        .opacity(detected(integration) ? 1 : 0.5)
                }
                if !capNames.isEmpty {
                    GlassDivider()
                    SettingsRow(capNames.count == 1 ? "Show \(capNames[0])" : "Show model limits") {
                        SettingsToggle(isOn: settings.providerBind(integration, \.showExtraCaps))
                    }
                }
                GlassDivider()
                notchShowsRow
            }
            SettingsGroup("Operational assignment") {
                SettingsRow(
                    "Assigned login",
                    subtitle: "Drag a login profile here, or choose one. This only changes monitored usage."
                ) {
                    LoginAssignmentTarget(label: profileName(assignedSource)) { source in
                        assign(source)
                    }
                }
                GlassDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Login profiles")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.csFaint)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(loginProfiles, id: \.integration) { profile in
                                LoginProfileChip(
                                    profile: profile, label: profileName(profile),
                                    selected: profile.integration == assignedSource.integration)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                GlassDivider()
                SettingsRow("Choose login", subtitle: "Keyboard-friendly alternative to drag and drop") {
                    PopupControl(
                        options: loginProfiles.map { (profileName($0), $0.integration) },
                        selection: Binding(get: { assignedSource.integration }, set: { assign($0) }),
                        accessibilityLabel: "Assigned login profile")
                }
            }
            if !controller.candidates.isEmpty {
                SettingsGroup("Remote login controller") {
                    SettingsRow(
                        "Change with",
                        subtitle: "Drag a profile here. Both original logins are backed up on the SSH box."
                    ) {
                        CredentialExchangeTarget(
                            label: controller.partner.map(profileName) ?? "Choose profile"
                        ) { source in
                            Task { await controller.prepare(with: source) }
                        }
                    }
                    GlassDivider()
                    SettingsRow("Other login") {
                        PopupControl(
                            options: controller.candidates.map { (profileName($0), $0.integration) },
                            selection: Binding(
                                get: { controller.partner?.integration ?? integration },
                                set: { controller.select($0) }),
                            accessibilityLabel: "Other remote login profile")
                    }
                    GlassDivider()
                    SettingsRow("Action") {
                        PopupControl(
                            options: remoteActionOptions,
                            selection: Binding(
                                get: { controller.action }, set: { controller.action = $0 }),
                            accessibilityLabel: "Remote credential action")
                    }
                    GlassDivider()
                    SettingsRow("Change remote logins", subtitle: "Affects the profile directories after Claude restarts.") {
                        Button(controller.isRunning ? "Working…" : "Prepare change") {
                            Task { await controller.prepare() }
                        }
                        .disabled(controller.isRunning || controller.partner == nil)
                    }
                    if controller.restorableBackup != nil {
                        GlassDivider()
                        SettingsRow("Recover originals", subtitle: "Restore the last change from its remote backup.") {
                            Button("Prepare restore") { Task { await controller.prepareRestore() } }
                                .disabled(controller.isRunning)
                        }
                    }
                    if !controller.message.isEmpty {
                        GlassDivider()
                        Text(controller.message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.csLabel)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                }
            }
            SettingsGroup("Data source") {
                SettingsRow("This profile lives on", subtitle: remote ? "Connects over SSH and refreshes assigned slots." : "Reads this Mac's harness login when assigned.") {
                    PopupControl(
                        options: [("This Mac", false), ("Remote server", true)], selection: $remote,
                        accessibilityLabel: "Usage data source"
                    )
                    .onChange(of: remote) { _, isRemote in
                        if !isRemote { saveSource() }
                    }
                }
                if remote {
                    GlassDivider()
                    SettingsRow("Remote server", subtitle: sourceSaved ? "Saved and refreshed." : "SSH alias or IP address") {
                        TextField("sunny-new-direct or 100.112.44.46", text: $remoteServer)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                            .onSubmit { saveSource() }
                    }
                }
                GlassDivider()
                SettingsRow("Token location", subtitle: "Directory containing this login profile.") {
                    TextField("~/.claude-a", text: $tokenLocation)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .onSubmit { saveSource() }
                }
                GlassDivider()
                SettingsRow("", subtitle: remote ? "Uses the SSH user and keys configured on this Mac." : "Reads the login stored on this Mac.") {
                    Button("Save and refresh") { saveSource() }
                        .disabled(remote && remoteServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if remote && (account.harness == .claude || account.harness == .codex) {
                    GlassDivider()
                    SettingsRow("Sign in", subtitle: "Runs the provider's login on this remote server.") {
                        Button(remoteLogin.isRunning ? "Signing in…" : "Sign in on remote") {
                            remoteLogin.start(account: currentAccount)
                        }
                        .disabled(remoteLogin.isRunning)
                    }
                    if !remoteLogin.output.isEmpty {
                        GlassDivider()
                        VStack(alignment: .leading, spacing: 7) {
                            Text(remoteLogin.output)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.csLabel)
                                .textSelection(.enabled)
                                .lineLimit(8)
                            HStack {
                                if let url = remoteLogin.browserURL {
                                    Button("Open browser") { NSWorkspace.shared.open(url) }
                                }
                                if remoteLogin.isRunning { Button("Cancel") { remoteLogin.cancel() } }
                            }
                            if remoteLogin.isRunning {
                                HStack(spacing: 8) {
                                    TextField("Paste login code or token", text: $remoteLoginResponse)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { submitRemoteLoginResponse() }
                                    Button("Send") { submitRemoteLoginResponse() }
                                        .disabled(remoteLoginResponse.isEmpty)
                                    Button("Paste & send") {
                                        guard let value = NSPasteboard.general.string(forType: .string) else { return }
                                        remoteLogin.submit(value)
                                    }
                                }
                                Text("Sent directly to the remote CLI; it is not saved or shown in this transcript.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
            SettingsGroup("Card") {
                SettingsRow("Show token estimate", subtitle: tokenSubtitle) {
                    SettingsToggle(isOn: settings.providerBind(integration, \.showTokenEstimate))
                        .disabled(!supportsTokens)
                        .opacity(supportsTokens ? 1 : 0.5)
                }
            }
            if canDelete {
                Button("Delete subscription", role: .destructive) { onDeleteSubscription(integration) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.csRed)
            }
        }
        .confirmationDialog(
            pendingActionTitle,
            isPresented: Binding(
                get: { controller.pending != nil }, set: { if !$0 { controller.cancel() } })
        ) {
            Button(
                controller.pending?.restoring == nil ? "Change remote logins" : "Restore from remote backup",
                role: .destructive
            ) {
                Task {
                    // A remote login change moves which account each profile directory speaks for,
                    // so every ring reading those profiles has to be re-read.
                    if await controller.confirm() { await onAccountsChanged() }
                }
            }
        } message: {
            Text(pendingActionMessage)
        }
    }

    private func submitRemoteLoginResponse() {
        remoteLogin.submit(remoteLoginResponse)
        remoteLoginResponse = ""
    }

    private func saveSource() {
        let host = remote ? remoteServer : nil
        sourceSaved =
            AccountsFile.setHost(host, for: integration, at: Accounts.configuredURL)
            && AccountsFile.setConfigDir(tokenLocation, for: integration, at: Accounts.configuredURL)
        guard sourceSaved else { return }
        Task { await onAccountsChanged() }
    }

    private func assign(_ source: Integration) {
        guard source.harness == integration.harness,
            AccountsFile.setUsageSource(source, for: integration, at: Accounts.configuredURL)
        else { return }
        assignedSourceRaw = source.rawValue
        sourceSaved = false
        Task { await onAccountsChanged() }
    }

    private var currentAccount: AccountConfig {
        AccountConfig(
            harness: account.harness, account: account.account, label: account.label,
            host: remote ? .ssh(remoteServer) : .local, configDir: tokenLocation)
    }

    private func orderedUnique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    // Which of this provider's meters its ring quotes.
    @ViewBuilder private var notchShowsRow: some View {
        SettingsRow("Notch shows") {
            let snapshot = usage?[integration]
            let includingExtras = settings.settings.provider(for: integration).showExtraCaps
            let options = UsageSelection.scopeOptions(snapshot, includingExtras: includingExtras)
            let stored = settings.settings.provider(for: integration).scope
            if options.isEmpty {
                PopupControl(
                    options: [("—", UsageScope.primary)],
                    selection: settings.providerBind(integration, \.scope), accessibilityLabel: "Notch shows"
                )
                .disabled(true)
                .opacity(0.5)
            } else {
                // The stored scope need not be in the list — a default `.primary` on a plan
                // with no 5h window, or a cap the provider stopped reporting. The chip then
                // names the option that renders the same window it fell back to, so the chip
                // and the list it opens agree instead of reading "Weekly" over "Weekly · 7d".
                let shown = snapshot.flatMap {
                    UsageSelection.resolved($0, scope: stored, includingExtras: includingExtras)
                }
                let fallback = snapshot.flatMap { snap in
                    options.first {
                        UsageSelection.resolved(snap, scope: $0.scope, includingExtras: includingExtras) == shown
                    }?.label
                }
                PopupControl(
                    options: options.map { ($0.label, $0.scope) },
                    fallbackLabel: fallback ?? shown?.title,
                    selection: settings.providerBind(integration, \.scope), accessibilityLabel: "Notch shows")
            }
        }
    }
}

// MARK: - Operational login assignment

/// A profile is a draggable reference to an already-configured login location. The drag payload is
/// only an Integration key; no path or credential is placed on the pasteboard.
private struct LoginProfileChip: View {
    let profile: AccountConfig
    let label: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            BrandMark(
                integration: profile.integration, size: 14,
                tint: profile.integration.descriptor.brandColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                Text(profile.host.sshAlias ?? "This Mac")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.csFaint)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.csSidebarSel : Color.csWell))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.csAccent.opacity(0.65) : Color.csBorder, lineWidth: 1)
        }
        .onDrag { NSItemProvider(object: profile.integration.rawValue as NSString) }
        .pointerOnHover()
        .accessibilityLabel("Drag \(label) login profile")
    }
}

private struct LoginAssignmentTarget: View {
    let label: String
    let assign: (Integration) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "person.crop.circle")
                .foregroundStyle(targeted ? Color.csAccent : Color.csFaint)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.csTitle)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(targeted ? Color.csControlHover : Color.csWell))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(targeted ? Color.csAccent : Color.csBorder, lineWidth: 1)
        }
        .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let raw = object as? String, let source = Integration(rawValue: raw) else { return }
                Task { @MainActor in assign(source) }
            }
            return true
        }
        .accessibilityLabel("Drop login profile to assign it")
    }
}

private struct CredentialExchangeTarget: View {
    let label: String
    let prepare: (Integration) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.left.arrow.right")
                .foregroundStyle(targeted ? Color.csAccent : Color.csFaint)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.csTitle)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(targeted ? Color.csControlHover : Color.csWell))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(targeted ? Color.csAccent : Color.csBorder, lineWidth: 1)
        }
        .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let raw = object as? String, let profile = Integration(rawValue: raw) else { return }
                Task { @MainActor in prepare(profile) }
            }
            return true
        }
        .accessibilityLabel("Drop login profile to prepare credential exchange")
    }
}

extension SettingsStore {
    // Two-way binding into the private(set) store: read the value, write back a mutated copy that persists.
    fileprivate func bind<V>(_ kp: WritableKeyPath<HarnessUsageCore.Settings, V>) -> Binding<V> {
        Binding(
            get: { self.settings[keyPath: kp] },
            set: {
                var s = self.settings
                s[keyPath: kp] = $0
                self.update(s)
            })
    }

    // Same, into one provider's configuration. Reading through `provider(for:)` means the first edit
    // to a provider the user has never touched starts from the defaults rather than from nothing.
    fileprivate func providerBind<V>(_ i: Integration, _ kp: WritableKeyPath<ProviderConfig, V>) -> Binding<V> {
        Binding(
            get: { self.settings.provider(for: i)[keyPath: kp] },
            set: {
                var s = self.settings
                var cfg = s.provider(for: i)
                cfg[keyPath: kp] = $0
                s.providers[i] = cfg
                self.update(s)
            })
    }
}

// MARK: - Grouped cards

// The uppercase caption that names a section.
private struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.csFaint)
    }
}

// An uppercase caption above a clipped, bordered glass card; rows go inside, separated by
// `GlassDivider`. The caption is optional, for a card whose rows already name themselves.
private struct SettingsGroup<Content: View>: View {
    let caption: String?
    @ViewBuilder var content: () -> Content

    init(_ caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption { SettingsCaption(caption) }
            VStack(spacing: 0) { content() }
                .background(Color.csCard)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.csBorder, lineWidth: 1)
                }
        }
    }
}

// One setting row: a label (+ optional subtitle) on the left, its control on the right.
private struct SettingsRow<Control: View>: View {
    let label: String
    var subtitle: String?
    @ViewBuilder var control: () -> Control

    init(_ label: String, subtitle: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.csFaint)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .accessibilityElement(children: .contain)
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }
}

// MARK: - Controls

// A native macOS switch. No `.tint` override, so the on-state uses the user's chosen system accent color
// (System Settings → Appearance → Accent color).
private struct SettingsToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            // The switch at its regular size overpowers a 12.5pt row label, and more so since the
            // system grew its controls. It is the only stock AppKit control in these panes — every
            // other one is drawn at an explicit point size — so it is the only thing that grew.
            .controlSize(.small)
            .pointerOnHover()
    }
}

// A chip that opens a popover list. A popover (not a SwiftUI `Menu`) so the chip's layout is fully ours:
// the selected value, then a trailing chevron — no native disclosure indicator sneaking in before it.
private struct PopupControl<Value: Hashable>: View {
    let options: [(String, Value)]
    /// Shown when `selection` is not in `options` — the window actually on screen after the
    /// resolution fell back. `nil` keeps the old behaviour of naming the first option.
    var fallbackLabel: String? = nil
    @Binding var selection: Value
    var accessibilityLabel: String = ""
    @State private var open = false

    private var currentLabel: String {
        options.first { $0.1 == selection }?.0 ?? fallbackLabel ?? options.first?.0 ?? ""
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(currentLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.csAccent)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.csWell))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.csBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    PopupOptionRow(label: option.0, selected: option.1 == selection) {
                        selection = option.1
                        open = false
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 150)
        }
    }
}

// One row of a `PopupControl`'s list. Hover wins over selected, so the row under the pointer is always
// the highlighted one — without it the list gives no feedback until the click lands.
private struct PopupOptionRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var fill: Color {
        if hovering { return .csControlHover }
        return selected ? .csWell : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12)).foregroundStyle(Color.csTitle)
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.csAccent)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Concentric with the popover it sits in: the list is inset by 6, so an inner radius of 9
            // stays parallel to the container's own corner instead of cutting across it.
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover { hovering = $0 }
    }
}

// A thin custom slider with a mono value readout. Width-bounded so it sits at the row's trailing edge.
private struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Snaps the drag onto this grid, measured from `range.lowerBound`. Free-running when nil.
    var step: Double? = nil
    var label: (Double) -> String = { "\(Int($0.rounded()))%" }

    var body: some View {
        HStack(spacing: 9) {
            GeometryReader { geo in
                let w = geo.size.width
                let span = range.upperBound - range.lowerBound
                let frac = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.csWell).frame(height: 4)
                    Capsule().fill(Color.csAccent).frame(width: max(0, min(w, frac * w)), height: 4)
                    Circle().fill(Color.csTitle).frame(width: 14, height: 14)
                        .overlay { Circle().strokeBorder(Color.csBorder, lineWidth: 1) }
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .offset(x: max(0, min(w - 14, frac * w - 7)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        let f = w > 0 ? max(0, min(1, g.location.x / w)) : 0
                        set(range.lowerBound + Double(f) * span)
                    }
                )
            }
            .frame(height: 14)
            Text(label(value))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.csLabel)
                .frame(width: 32, alignment: .trailing)
        }
        .frame(width: 150)
        .pointerOnHover()
    }

    /// On the step's grid and inside the range, and written only when it actually moves: most of a
    /// stepped drag lands back inside the cell the value is already in, and every write here
    /// re-renders the notch.
    private func set(_ raw: Double) {
        let onGrid = step.map { range.lowerBound + ((raw - range.lowerBound) / $0).rounded() * $0 } ?? raw
        let next = min(range.upperBound, max(range.lowerBound, onGrid))
        if next != value { value = next }
    }
}
