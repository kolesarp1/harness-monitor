import AppKit
import HarnessUsageCore
import SwiftUI

// Assigns provider-derived names to new accounts and presents the manual rename window from Settings.
// The stored name feeds the notch chip, card header and Settings row.
@MainActor final class AccountNamePrompt {
    private struct Request {
        let account: UsageAccount
        let integration: Integration
        let sources: [UsageAccountSource]
    }

    private let settings: SettingsStore
    private var window: GlassWindow?
    private var showing: Request?
    private var pending: [Request] = []

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // Called on every readings change. Each unseen account is persisted under its automatic name at once;
    // no onboarding window interrupts the user's editor.
    func review(_ readings: [UsageKey: UsageSnapshot]) {
        var seen = Set<String>()
        let accounts = readings.sorted { $0.key.rawValue < $1.key.rawValue }
            .compactMap(\.value.account)
            .filter { seen.insert($0.id).inserted }
        var updated = settings.settings
        guard updated.assignAutomaticAccountNames(accounts) else { return }
        settings.update(updated)
    }

    func rename(_ snapshot: UsageSnapshot, integration: Integration) {
        guard let account = snapshot.account else { return }
        if showing?.account.id == account.id, let window {
            WindowManager.present(window)
            return
        }
        pending.append(Request(account: account, integration: integration, sources: snapshot.accountSources))
        showNext()
    }

    private func showNext() {
        guard showing == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        showing = request
        let stored = settings.settings.accountNames[request.account.id].flatMap { $0.isEmpty ? nil : $0 }
        let host = NSHostingController(
            rootView: AccountNameView(
                account: request.account, integration: request.integration, sources: request.sources,
                name: stored ?? request.account.suggestedName,
                onSave: { [weak self] in self?.finish(saving: $0) },
                onDismiss: { [weak self] in self?.finish(saving: nil) }))
        let window = self.window ?? makeWindow()
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        window.center()
        WindowManager.present(window)
    }

    private func finish(saving name: String?) {
        guard let request = showing else { return }
        showing = nil
        if let name {
            record(name, for: request.account)
        }
        if pending.isEmpty {
            window?.orderOut(nil)
            WindowManager.settleActivationPolicy()
        }
        showNext()
    }

    private func record(_ name: String, for account: UsageAccount) {
        var s = settings.settings
        s.accountNames[account.id] = name
        settings.update(s)
    }

    private func makeWindow() -> GlassWindow {
        let w = GlassWindow(
            contentRect: NSRect(x: 0, y: 0, width: AccountNameView.width, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        w.onCancel = { [weak self] in self?.finish(saving: nil) }
        window = w
        return w
    }
}

private struct AccountNameView: View {
    static let width: CGFloat = 340

    let account: UsageAccount
    let integration: Integration
    let sources: [UsageAccountSource]
    @State private var name: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void
    @FocusState private var fieldFocused: Bool

    init(
        account: UsageAccount, integration: Integration, sources: [UsageAccountSource],
        name: String, onSave: @escaping (String) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.account = account
        self.integration = integration
        self.sources = sources
        self._name = State(initialValue: name)
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var identity: String { account.email ?? account.location }
    private var metadata: [String] {
        AccountMetadata.renameItems(account: account, integration: integration, sources: sources)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader(title: "Rename account") {
                GhostIconButton(systemName: "xmark", hoverTint: .csRed, action: onDismiss)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    AccountTile(letter: AccountLabel.initial(of: trimmed.isEmpty ? identity : trimmed), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.csTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !metadata.isEmpty {
                            MetadataRow(items: metadata.map { Optional($0) })
                        }
                    }
                }
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.csTitle)
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.csWell))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.csBorder, lineWidth: 1)
                    }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    DialogButton(title: "Cancel", action: onDismiss)
                    DialogButton(title: "Save", isProminent: true, action: save)
                        .disabled(trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? 0.5 : 1)
                }
            }
            .padding(16)
        }
        .frame(width: Self.width)
        .glassChrome()
        .task { fieldFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
