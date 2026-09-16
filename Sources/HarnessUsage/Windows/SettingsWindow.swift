import AppKit
import HarnessUsageCore
import SwiftUI

// The Settings window: the app's one glass (`glassChrome`) and its one `cs*` palette, in a
// macOS-preferences layout — a sidebar of panes over the version line, and a content area of grouped
// setting cards. Every control binds to `SettingsStore`.
@MainActor struct SettingsWindow: View {
    let settings: SettingsStore
    var integrations: IntegrationStore?
    var usage: UsageStore?
    var login: AccountLoginController?
    var onRenameAccount: (UsageSnapshot, Integration) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    /// Deep-link a pane for previews and tests ("general" or an integration raw value). Nil keeps
    /// the last-selected default.
    var initialPane: String? = nil

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
        .onAppear {
            if let initialPane { pane = Pane(id: initialPane) ?? .general }
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(Self.panes) { sidebarRow($0) }
            Spacer(minLength: 8)
            Text("Harness Monitor · \(Self.version)")
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
                case .provider(let integration):
                    // The provider's own mark in its own colors, selected or not — the accent tile is
                    // the selection signal; repainting the mark would only blur it. A selected tile is
                    // a light surface, so an adaptive mark inverts against the TILE, not the window.
                    BrandMark(
                        integration: integration, size: 20, tint: integration.descriptor.brandColor,
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
                case .provider(let integration):
                    ProviderPane(
                        settings: settings, integration: integration, integrations: integrations, usage: usage,
                        login: login, onRenameAccount: onRenameAccount)
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
        case provider(Integration)

        init?(id: String) {
            if id == "general" {
                self = .general
            } else if let integration = Integration(rawValue: id) {
                self = .provider(integration)
            } else {
                return nil
            }
        }

        var id: String {
            switch self {
            case .general: "general"
            case .provider(let integration): "provider-\(integration.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .general: "General"
            case .provider(let integration): integration.displayName
            }
        }
    }

    // Only supported integrations get a sidebar pane. Suspended cases keep their stored settings
    // but are never shown or initialized.
    private static var panes: [Pane] {
        [.general] + Integration.supportedCases.map(Pane.provider)
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
            SettingsGroup("Usage") {
                SettingsRow("Update every") {
                    PopupControl(
                        options: [
                            ("1 minute", UsageUpdateInterval.oneMinute),
                            ("5 minutes", .fiveMinutes),
                            ("15 minutes", .fifteenMinutes),
                        ],
                        selection: settings.bind(\.updateInterval), accessibilityLabel: "Update every")
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
                GlassDivider()
                SettingsRow(
                    "Hide inactive accounts",
                    subtitle: "Keep disconnected accounts in Settings but hide their notch rings"
                ) {
                    SettingsToggle(isOn: settings.bind(\.hideInactiveAccounts))
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
    // setter, it then unregisters the item it has just registered.
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
    let integration: Integration
    var integrations: IntegrationStore?
    var usage: UsageStore?
    var login: AccountLoginController?
    var onRenameAccount: (UsageSnapshot, Integration) -> Void = { _, _ in }

    private func detected(_ i: Integration) -> Bool { integrations?.detected.contains(i) ?? true }

    private var providerSnapshots: [UsageSnapshot] {
        (usage?.keys(for: integration) ?? []).compactMap { usage?[$0] }
    }

    private var providerAvailable: Bool {
        ProviderPaneLogic.isAvailable(
            detected: detected(integration), snapshots: providerSnapshots,
            accountRemembered: login?.accountIntegrations.contains(integration) == true)
    }

    private func hint(_: Integration) -> String? {
        ProviderPaneLogic.hint(available: providerAvailable, snapshots: providerSnapshots)
    }

    private var accountsFooter: String {
        let folder = "~/\(integration.descriptor.homeRelativePath)"
        return "Detected from \(folder) and \(folder)-* folders, or add an account by signing in."
    }

    private var supportsTokens: Bool { integration.descriptor.reportsTokens }

    private var tokenSubtitle: String {
        supportsTokens
            ? "Today's tokens in, out, and total, counted from local sessions on this Mac"
            : "This agent doesn't report token counts"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let capNames = ProviderPaneLogic.modelCapNames(providerSnapshots)
            let keys = usage?.keys(for: integration) ?? []
            // One row per login the engine publishes — a deduplicated subscription is one row even
            // when both an owned connection and a detected folder stand behind it. The Add row is
            // reachable whether or not a CLI folder exists: the gate is the supported list (only
            // login-capable providers are supported), not filesystem detection.
            if !keys.isEmpty || login != nil {
                SettingsGroup("Accounts", footer: accountsFooter) {
                    ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                        if index > 0 { GlassDivider() }
                        if let snapshot = usage?[key] {
                            AccountRow(
                                snapshot: snapshot, names: settings.settings.accountNames,
                                owned: ownership(of: snapshot), login: login,
                                integration: integration,
                                onRename: snapshot.account.map { _ in { onRenameAccount(snapshot, integration) } }
                            )
                        }
                    }
                    if let login {
                        if !keys.isEmpty { GlassDivider() }
                        addAccountRow(login)
                        if loginStatusVisible(login) {
                            GlassDivider()
                            LoginStatusView(integration: integration, controller: login)
                        }
                    }
                }
            }
            // Split by what the switch reaches, not by surface: Extra changes the ring, the "Notch
            // shows" options and the card's rows alike, so it sits with the provider-wide switches.
            SettingsGroup("Provider") {
                // Detection and read failures are the row's subtitle, which is how a tier that
                // silently never fires names itself. Detection is also the gate: a harness that is not
                // on this Mac has nothing to enable, so the switch is dead rather than storing a
                // preference the filesystem overrules.
                SettingsRow("Enabled", subtitle: hint(integration)) {
                    SettingsToggle(isOn: settings.providerBind(integration, \.visible))
                        .disabled(!providerAvailable)
                        .opacity(providerAvailable ? 1 : 0.5)
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
            SettingsGroup("Card") {
                SettingsRow("Show token estimate", subtitle: tokenSubtitle) {
                    SettingsToggle(isOn: settings.providerBind(integration, \.showTokenEstimate))
                        .disabled(!supportsTokens)
                        .opacity(supportsTokens ? 1 : 0.5)
                }
            }
        }
    }

    // Whether this reading stands on an app-owned connection, and the sources behind it. Read off
    // the controller's secret-free snapshots by exact account id — never inferred from note prose.
    private func ownership(of snapshot: UsageSnapshot) -> SubscriptionAccountSnapshot? {
        guard let id = snapshot.account?.id else { return nil }
        return login?.snapshot(integration: integration, accountID: id)
    }

    private func loginStatusVisible(_ login: AccountLoginController) -> Bool {
        LoginStatusView(integration: integration, controller: login).isVisible
    }

    // Reachable with or without a CLI folder. The quiet full-width row disables itself while any
    // login is active, and the existing status row below still owns waiting, cancel, and errors.
    @ViewBuilder private func addAccountRow(_ login: AccountLoginController) -> some View {
        AddAccountRow(enabled: login.canStartLogin) {
            login.beginLogin(integration)
        }
    }

    // Which of this provider's meters its ring quotes.
    @ViewBuilder private var notchShowsRow: some View {
        SettingsRow("Notch shows") {
            let snapshots = providerSnapshots
            let includingExtras = settings.settings.provider(for: integration).showExtraCaps
            let options = UsageSelection.scopeOptions(snapshots, includingExtras: includingExtras)
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
                let shown = snapshots.compactMap {
                    UsageSelection.resolved($0, scope: stored, includingExtras: includingExtras)
                }.first
                let fallback = shown.flatMap { window in
                    options.first { option in
                        if case .window(let id) = option.scope { return id == window.id }
                        return false
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

enum ProviderPaneLogic {
    static func isAvailable(
        detected: Bool, snapshots: [UsageSnapshot], accountRemembered: Bool
    ) -> Bool {
        detected || !snapshots.isEmpty || accountRemembered
    }

    static func hint(available: Bool, snapshots: [UsageSnapshot]) -> String? {
        snapshots.compactMap(\.note).first ?? (available ? nil : "Not detected on this Mac")
    }

    static func modelCapNames(_ snapshots: [UsageSnapshot]) -> [String] {
        var seen: Set<String> = []
        return snapshots.flatMap(\.windows).compactMap(\.kind.modelName)
            .filter { seen.insert($0).inserted }
    }
}

// One login in a provider's Accounts group: its letter, its name, where it lives, which sources
// stand behind it, and rename/reconnect/remove. A deduplicated subscription names both sources on
// one row; removing the owned connection leaves the detected fallback in place (the Core keeps the
// record while a detected source matches).
struct AccountRow: View {
    let snapshot: UsageSnapshot
    let names: [String: String]
    var owned: SubscriptionAccountSnapshot? = nil
    var login: AccountLoginController? = nil
    var integration: Integration = .claude
    var onRename: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if let account = snapshot.account {
                AccountTile(
                    letter: AccountLabel.letter(account, names: names), size: 28,
                    muted: isDisconnected)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isDisconnected ? Color.csLabel : Color.csTitle)
                        .lineLimit(1)
                    if let plan = snapshot.account.flatMap({ integration.planDisplayName($0.plan) }) {
                        PlanChip(plan: plan)
                    }
                }
                details
            }
            Spacer(minLength: 8)
            if canReconnect {
                DialogButton(title: "Reconnect", action: reconnect)
                    .disabled(login?.canStartLogin == false)
            }
            if let onRename {
                AccountActionsMenu(
                    accountName: title, onRename: onRename,
                    showReconnect: canReconnect,
                    reconnectEnabled: login?.canStartLogin != false,
                    removalLabel: removalLabel, onReconnect: reconnect, onRemove: remove)
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: 56)
    }

    private var title: String {
        guard let account = snapshot.account else { return integration.displayName }
        return AccountLabel.title(account, names: names)
    }

    private var metadata: [String] {
        guard let account = snapshot.account else { return [] }
        return AccountMetadata.settingsItems(
            account: account, title: title, sources: sources,
            lastReadingAt: isDisconnected ? snapshot.lastUpdated : nil)
    }

    private var problem: AccountProblem? { AccountMetadata.problem(snapshot: snapshot) }
    private var isDisconnected: Bool { snapshot.freshness == .disconnected }
    private var lastReadingContext: String? {
        guard isDisconnected else { return nil }
        return "Last reading \(AccountAge.text(since: snapshot.lastUpdated))"
    }

    private var metadataAccessibilityLabel: String {
        (Array(metadata.dropLast()) + [lastReadingContext].compactMap { $0 })
            .joined(separator: ", ")
    }

    @ViewBuilder private var details: some View {
        if isDisconnected {
            if !metadata.isEmpty {
                MetadataRow(
                    items: metadata.map { Optional($0) }, font: .system(size: 10.5),
                    keepLastItemVisible: true
                )
                .accessibilityLabel(metadataAccessibilityLabel)
                .help(lastReadingContext ?? "")
            }
            if let problem { problemText(problem) }
        } else if let problem {
            problemText(problem)
        } else if !metadata.isEmpty {
            MetadataRow(items: metadata.map { Optional($0) }, font: .system(size: 10.5))
        }
    }

    private func problemText(_ problem: AccountProblem) -> some View {
        Text(problem.text)
            .font(.system(size: 10.5))
            .foregroundStyle(problemColor(problem.tone))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problemColor(_ tone: AccountProblemTone) -> Color {
        switch tone {
        case .warning, .fallback, .disconnectedWarning: .csAmber
        case .disconnected: .csFaint
        }
    }

    private var sources: [UsageAccountSource] {
        if !snapshot.accountSources.isEmpty { return snapshot.accountSources }
        return owned?.sources ?? []
    }

    /// Reconnect targets only an owned connection with a current problem. Local-only rows never offer it.
    private var canReconnect: Bool {
        guard login != nil, snapshot.account != nil else { return false }
        return AccountActionPolicy.canReconnect(
            hasOwnedConnection: owned?.hasOwnedConnection == true, ownedStatus: owned?.status)
    }

    /// An active local source remains detection-owned and cannot be forgotten. A historical local
    /// reference does not keep a disconnected row permanent; without an available source, removal
    /// forgets the account and any app-owned credential together.
    private var removalLabel: String? {
        guard login != nil else { return nil }
        return AccountActionPolicy.removalLabel(
            hasOwnedConnection: owned?.hasOwnedConnection == true, sources: sources)
    }

    private func reconnect() {
        guard let id = snapshot.account?.id else { return }
        login?.reconnect(integration, accountID: id)
    }

    private func remove() {
        guard let id = snapshot.account?.id else { return }
        Task { await login?.remove(integration, accountID: id) }
    }
}

// Variant A's single native menu. Borderless style and a custom label keep the trigger neutral and
// chevron-free while preserving standard keyboard and accessibility behavior.
private struct AccountActionsMenu: View {
    let accountName: String
    let onRename: () -> Void
    let showReconnect: Bool
    let reconnectEnabled: Bool
    let removalLabel: String?
    let onReconnect: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            Button(action: onRename) {
                Label("Rename…", systemImage: "pencil")
            }
            if showReconnect {
                Button(action: onReconnect) {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .disabled(!reconnectEnabled)
            }
            if let removalLabel {
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label(removalLabel, systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Color.csTitle : Color.csLabel)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.csControlHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerOnHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Actions for \(accountName)")
        .help("Actions for \(accountName)")
    }
}

private struct AddAccountRow: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.csLabel)
                    .frame(width: 28, height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                Color.csBorder,
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    .accessibilityHidden(true)
                Text("Add account")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering && enabled ? Color.csControlHover.opacity(0.35) : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .pointerOnHover { hovering = $0 }
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
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(_ caption: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.caption = caption
        self.footer = footer
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
            if let footer {
                Text(footer)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.csFaint)
                    .fixedSize(horizontal: false, vertical: true)
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
