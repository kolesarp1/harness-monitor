import AppKit
import HarnessUsageCore
import SwiftUI

// Owns the Settings window — the app's one real window. (The usage card belongs to the notch; see
// `NotchUsageCard`.) Settings is a borderless glass NSWindow hosting SwiftUI via NSHostingController,
// created on first open and reused after that.
@MainActor final class WindowManager {
    private let usage: UsageStore
    private let settings: SettingsStore
    private let integrations: IntegrationStore?
    // The tracked accounts, in `accounts.json` order — one Settings pane each.
    private let accounts: [AccountConfig]
    private let onAccountSourceChanged: @MainActor (Integration) async -> Void
    private let onAddSubscription: @MainActor (Harness) -> Void
    private let onDeleteSubscription: @MainActor (Integration) -> Void

    private var settingsWindow: GlassWindow?

    init(
        usage: UsageStore, settings: SettingsStore, integrations: IntegrationStore? = nil,
        accounts: [AccountConfig],
        onAccountSourceChanged: @escaping @MainActor (Integration) async -> Void = { _ in },
        onAddSubscription: @escaping @MainActor (Harness) -> Void = { _ in },
        onDeleteSubscription: @escaping @MainActor (Integration) -> Void = { _ in }
    ) {
        self.usage = usage
        self.settings = settings
        self.integrations = integrations
        self.accounts = accounts
        self.onAccountSourceChanged = onAccountSourceChanged
        self.onAddSubscription = onAddSubscription
        self.onDeleteSubscription = onDeleteSubscription
    }

    // MARK: settings window

    func toggleSettings() {
        if let w = settingsWindow {
            present(w)  // already created — show + bring forward (the menu never closes it; that's the X)
            return
        }
        let w = GlassWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindow.contentSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear  // transparent rect; the rounded SwiftUI glass defines the visible shape
        w.hasShadow = true
        w.isMovableByWindowBackground = false  // drag only by the header strip (WindowDragHandle)
        w.isReleasedWhenClosed = false
        w.onCancel = { [weak self] in self?.closeSettings() }  // Escape is a close path like the header's X
        let host = NSHostingController(
            rootView: SettingsWindow(
                settings: settings, integrations: integrations, usage: usage, accounts: accounts,
                onAccountSourceChanged: onAccountSourceChanged,
                onAddSubscription: onAddSubscription,
                onDeleteSubscription: onDeleteSubscription,
                onClose: { [weak self] in self?.closeSettings() }))
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        settingsWindow = w
        host.view.layoutSubtreeIfNeeded()
        w.setContentSize(SettingsWindow.contentSize)  // fixed size before centering (auto-size is async)
        w.center()  // first open only; re-shows preserve the user's drag
        present(w)  // normal window level — not pinned
    }

    // Every close path routes here, because the activation policy has to come back down with the
    // window: leave it `.regular` and the app keeps a Dock icon for a window that is no longer on
    // screen.
    func closeSettings() {
        settingsWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // `activate(ignoringOtherApps:)` is deprecated on macOS 14 and the system frequently declines it for
    // a background accessory app, which left Settings opening BEHIND the frontmost window — fatal for a
    // window that is the app's escape hatch. `activate()` is the supported request, and
    // `orderFrontRegardless()` puts the window up even when the system withholds activation.
    //
    // `.regular` first, and only while Settings is up: an `.accessory` app is absent from ⌘-Tab and the
    // Dock, so the one window the user can actually reach could not be switched back to once anything
    // else took focus. The Dock icon that comes with it is the intended cost, and `closeSettings()`
    // takes both away again.
    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }
}

// A borderless glass window (normal, activating) for the Settings view: becomes key so its controls work,
// and closes on Escape. Auto-sizes to its SwiftUI content via the hosting controller.
final class GlassWindow: NSWindow {
    // Escape has to reach the owner rather than just ordering out here, so the one close path that
    // restores the activation policy cannot be bypassed.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
