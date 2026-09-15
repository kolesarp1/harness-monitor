import AppKit

/// Borderless, non-activating panel that floats over everything, including the
/// menu bar and full-screen apps. Non-activating matters: glancing at your
/// usage must never take focus off what you were actually doing.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu. Handled here rather than on the content
    /// view because `NSWindow.sendEvent` sees every event first — the hosting
    /// view's hit test resolves to a SwiftUI-owned subview, which has no menu
    /// of its own and may consume the click before it reaches us.
    var contextMenuProvider: (() -> NSMenu?)?
    /// A left click on the visible chrome. Handled here for the same reason the
    /// menu is: the hit test lands on a SwiftUI subview that may consume it.
    var onClick: (() -> Void)?
    /// A ⌘-click on a ring, which picks it up to reorder the stack — forwarded from here for that
    /// same reason, and only the *start* of the gesture: the pointer monitors the controller already
    /// runs carry it and end it, so a drag that AppKit routes somewhere other than this panel still
    /// moves and still lands. Returning true takes the click that would otherwise pin the notch.
    var onReorderBegan: (() -> Bool)?
    /// True for as long as the menu is on screen. `popUpContextMenu` runs a nested tracking loop and
    /// does not return until the menu is dismissed, and for that whole time the pointer is over the
    /// menu rather than over the notch — so the fold has to be told to sit this out.
    private(set) var isShowingContextMenu = false

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .rightMouseDown,
            let menu = contextMenuProvider?(),
            let view = contentView,
            // Only over the visible chrome; elsewhere the panel is a hole.
            view.hitTest(event.locationInWindow) != nil
        else { return super.sendEvent(event) }

        isShowingContextMenu = true
        defer { isShowingContextMenu = false }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    override func mouseDown(with event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.mouseDown(with: event)
        }
        if event.modifierFlags.contains(.command), onReorderBegan?() == true { return }
        onClick?()
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
