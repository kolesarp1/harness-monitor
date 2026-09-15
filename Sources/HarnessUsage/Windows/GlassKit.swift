import AppKit
import SwiftUI

// Shared glass building blocks for every surface (the notch, its hover card, Settings): the frosted
// chrome, the header bar + its drag handle, ghost buttons and the hairline divider. One material and
// one palette (`cs*`) throughout — the app pins `darkAqua` at launch, so both hold their dark values
// as plain constants.

// MARK: - Chrome

// The one material the app is made of. Every surface takes the same vibrancy, the same tint and the
// same rim; only the shape masking them differs.
enum Glass {
    /// The tint over the vibrancy, and the one number that decides whether the surface reads as
    /// glass or as paint. At 0.74 the blur was invisible on a dark desktop — every surface read as flat
    /// black. 0.55 lets the frost through; the cost is on a white desktop, where an earlier sample put
    /// the point the ring track and grey labels start to wash out at about 0.6.
    ///
    /// Doubles as the white-flash guard on a Space switch: it sits inside the rounded clip over the
    /// effect view, so the glass can never render as pure white — at worst it shows this tint
    /// (corner-safe, unlike a non-clear window `backgroundColor`, which fills the frame's corners).
    static let tint = Color.black.opacity(0.55)
    /// The lit edge where the glass meets the screen. Faint on purpose: the notch has no shadow to
    /// separate it from the bezel, so the rim is the only thing giving it an edge.
    static let rim = Color.white.opacity(0.10)
    static let rimWidth: CGFloat = 1
}

extension View {
    // The glass in an arbitrary shape: vibrancy masked by the shape's own path, the tint over it, the
    // rim on top. The notch and its orb use this — a shape that has inverse flares and changes length
    // as it folds, which no mask image can describe.
    func notchGlass<S: Shape>(_ shape: S) -> some View {
        background {
            ShapeVibrancy(shape: shape)
                .overlay(shape.fill(Glass.tint))
                .overlay(shape.stroke(Glass.rim, lineWidth: Glass.rimWidth))
        }
    }

    // The same glass on a window. The only difference is how the vibrancy is masked: a window derives
    // its drop shadow from the effect view's own `maskImage`, so a layer path mask would leave a
    // rectangular shadow around the rounded glass.
    func glassChrome(radius: CGFloat = 15) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return
            self
            .background {
                RoundedVibrancy(radius: radius)
                    .overlay(shape.fill(Glass.tint))
                    .overlay(shape.stroke(Glass.rim, lineWidth: Glass.rimWidth))
            }
            .clipShape(shape)
    }
}

/// An `NSVisualEffectView` masked by a path derived from its own bounds.
final class MaskedEffectView: NSVisualEffectView {
    var pathProvider: ((CGRect) -> CGPath)?

    override func layout() {
        super.layout()
        guard let pathProvider else { return }
        let shape = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        // The fold animates this view's frame, so `layout` runs on every frame of it. Core Animation
        // would otherwise give `path` and `frame` their own implicit quarter-second animations, which
        // lag a frame behind the SwiftUI shape drawn on top and show as a bright rim along the edge
        // that is moving.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = pathProvider(bounds)
        layer?.mask = shape
        CATransaction.commit()
    }
}

/// Vibrancy clipped to an arbitrary `Shape`, remasked from the view's own bounds on every layout pass
/// so the material follows a silhouette that animates.
struct ShapeVibrancy<S: Shape>: NSViewRepresentable {
    let shape: S

    func makeNSView(context: Context) -> MaskedEffectView {
        let view = MaskedEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.pathProvider = { shape.path(in: $0).cgPath }
        return view
    }

    func updateNSView(_ view: MaskedEffectView, context: Context) {
        view.pathProvider = { shape.path(in: $0).cgPath }
        view.needsLayout = true
    }
}

/// Vibrancy clipped to a rounded rectangle by the effect view's own `maskImage`, which is what a
/// window's drop shadow is derived from.
struct RoundedVibrancy: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = Self.cornerMask(radius: radius)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.maskImage = Self.cornerMask(radius: radius)
        nsView.window?.invalidateShadow()  // the drop shadow follows the mask
    }

    // A resizable mask with equal corner radii; capInsets keep the corners fixed while the 1px middle
    // stretches to the window's actual size.
    private static func cornerMask(radius r: CGFloat) -> NSImage {
        let side = max(r, 0.5)
        let img = NSImage(size: NSSize(width: side * 2 + 1, height: side * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: side, bottom: r, right: side)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - Empty state

// The shared compact empty state: one muted line, so a card with nothing to report stays small
// instead of becoming a big stacked panel about its own emptiness.
struct CompactEmptyState: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.csLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
    }
}

// MARK: - Header

// The Settings window's header bar: a leading slot (its title), a Spacer that justifies trailing to the
// right, then the trailing slot (buttons). The whole bar IS the window's drag handle (behind
// everything); SwiftUI buttons sit on top so they stay clickable. The rest of the window is not
// draggable.
struct GlassHeader<Leading: View, Trailing: View>: View {
    let leading: () -> Leading
    let trailing: () -> Trailing

    init(@ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading()
                    .padding(.leading, 14)
                Spacer(minLength: 0)  // always pushes trailing right, even when leading is empty
                HStack(spacing: 5) { trailing() }
                    .padding(.trailing, 14)
            }
            .frame(height: 40)
            .background(WindowDragHandle())  // whole header strip drags; buttons on top stay clickable
            GlassDivider()
        }
    }
}

extension GlassHeader where Leading == AnyView {
    // Title-text convenience: the text is non-hit-testable so the whole leading strip drags the window.
    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(
            leading: {
                AnyView(
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.1)
                        .foregroundStyle(Color.csTitle)
                        .allowsHitTesting(false))
            }, trailing: trailing)
    }
}

// MARK: - Atoms

// Ghost icon button: subtle hover highlight, fires on click without activating the app.
struct GhostIconButton: View {
    let systemName: String
    var hoverTint: Color? = nil  // foreground (+ matching backdrop) while hovering; defaults to csTitle
    let action: () -> Void
    @State private var hovering = false

    // Hovering paints the translucent `csControlHover` chip the popup rows use, with the glyph lifted
    // to the title tone — the shared active-chip language, not a loud solid fill.
    private var foreground: Color { hovering ? (hoverTint ?? Color.csTitle) : Color.csLabel }
    private var fill: Color { hovering ? (hoverTint?.opacity(0.15) ?? Color.csControlHover) : .clear }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover highlight rides the same .activeAlways AppKit tracking as the cursor (SwiftUI's `.onHover`
        // is key-window-dependent — unreliable inside the non-activating panels).
        .pointerOnHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// The 1px divider used between the header and rows/meters and between setting rows.
struct GlassDivider: View {
    var body: some View { Rectangle().fill(Color.csDivider).frame(height: 1) }
}

// MARK: - Window drag handle

// A bare AppKit view that starts a window drag on mouse-down, used as the background of `GlassHeader`'s
// title strip so the window is draggable ONLY by its title (not by content rows or setting cards).
// `acceptsFirstMouse` lets the drag start on the click that brings the window forward, rather than
// swallowing that first click as activation.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)  // drag the window by its header
        }
    }
}

// MARK: - Cursor + hover tracking

// WindowServer silently drops `NSCursor.set()` from an app that isn't active — fatal for a product whose
// premise is hovering non-activating panels while the user's editor stays frontmost: every assertion in
// `CursorArbiter` would be discarded the moment another app has focus (event DELIVERY is fine — the
// `.activeAlways` tracking still fires and the hover highlights ride it — only the cursor writes are
// dropped). The private-but-stable CGS connection property "SetsCursorInBackground" (shipped by AltTab /
// Rectangle / DockDoor for years for exactly this case) opts our connection out of that rule. The symbols
// are resolved via `dlsym`, so a future macOS removing them degrades to active-app-only cursors — one
// stderr line, no crash, no link-time dependency on private frameworks.
@MainActor enum BackgroundCursor {
    static func enable() {
        typealias CGSMainConnectionID = @convention(c) () -> Int32
        typealias CGSSetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY),
            let mainID = dlsym(handle, "CGSMainConnectionID"),
            let setProperty = dlsym(handle, "CGSSetConnectionProperty")
        else {
            FileHandle.standardError.write(
                Data("HarnessUsage: CGS SetsCursorInBackground unavailable — cursor limited to active app\n".utf8))
            return
        }
        let cid = unsafeBitCast(mainID, to: CGSMainConnectionID.self)()
        _ = unsafeBitCast(setProperty, to: CGSSetConnectionProperty.self)(
            cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

// Region priorities for overlapping hover regions. Higher wins in `CursorArbiter`.
enum HoverPriority {
    static let control = 0
}

// The single owner of the on-screen cursor for every hover-tracked region. Regions report themselves on
// every enter AND every moved event (the re-assertion that beats the frontmost app's own cursor writes)
// and remove themselves on exit/teardown — but exit events are advisory, never load-bearing: a blocking
// drag loop (the width grips) suspends tracking-area delivery so a mid-drag exit is simply never sent, and
// an `.activeAlways` area fires geometrically even under an occluding window. Trusting exits once stranded
// a grip region and painted the resize cursor over every window until relaunch. So every assertion pass
// re-validates each (weakly-held) region against reality — still in a window, pointer inside its visible
// rect in screen coordinates, and that window is the one actually under the pointer per
// `NSWindow.windowNumber(at:)`, which sees other apps' windows too, so occlusion by Settings or anything
// else disqualifies — pruning failures and dropping their hover highlight via `hoverPruned`. The
// highest-priority surviving region's cursor is set; when none survive the arrow is restored ONCE, only if
// the arbiter was the last setter, and it then goes quiet instead of fighting other apps' cursor writes.
@MainActor final class CursorArbiter {
    static let shared = CursorArbiter()

    private struct Region {
        weak var view: HoverCursor.TrackingView?
        let priority: Int
        let cursor: NSCursor
    }
    private var regions: [ObjectIdentifier: Region] = [:]
    private var lastAsserted: NSCursor?  // non-nil while the arbiter owns the on-screen cursor

    // Register/refresh a region and run an assertion pass. Returns whether the region survived validation,
    // so the caller derives its hover state from the same pass instead of trusting the raw event.
    fileprivate func hover(_ view: HoverCursor.TrackingView, cursor: NSCursor, priority: Int) -> Bool {
        let key = ObjectIdentifier(view)
        regions[key] = Region(view: view, priority: priority, cursor: cursor)
        assertWinner()
        return regions[key] != nil
    }
    fileprivate func leave(_ view: HoverCursor.TrackingView) {
        guard regions.removeValue(forKey: ObjectIdentifier(view)) != nil else { return }
        assertWinner()
    }
    private func assertWinner() {
        var winner: Region?
        for (key, region) in regions {
            guard let view = region.view, Self.pointerIsOver(view) else {
                regions.removeValue(forKey: key)
                region.view?.hoverPruned()
                continue
            }
            if region.priority > (winner?.priority ?? .min) { winner = region }
        }
        if let winner {
            // Re-assert even when unchanged — from a non-frontmost app a single set() loses the race
            // against the frontmost app's own cursor writes (see HoverCursor). Safe: a winner exists only
            // while the pointer is verifiably over our own window. Never push/pop — a dropped exit would
            // imbalance the stack and strand a pushed cursor forever.
            winner.cursor.set()
            lastAsserted = winner.cursor
        } else if lastAsserted != nil {
            lastAsserted = nil
            NSCursor.arrow.set()  // restore once as the last setter, then go quiet
        }
    }

    // The live test that replaces trust in exit events: the pointer must sit inside the view's visible
    // rect (screen coords), and the view's window must be the window actually under the pointer.
    private static func pointerIsOver(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let mouse = NSEvent.mouseLocation
        guard NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return false }
        let rect = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        return NSMouseInRect(mouse, rect, false)
    }
}

extension View {
    // Pointing-hand cursor on hover that holds even while Harness Usage is NOT the frontmost app, optionally
    // reporting the hover state (for hover highlights — SwiftUI's `.onHover` is as unreliable as its cursor
    // in a non-activating panel, so highlights must ride the same AppKit tracking).
    func pointerOnHover(priority: Int = HoverPriority.control, onHover: ((Bool) -> Void)? = nil) -> some View {
        overlay(HoverCursor(cursor: .pointingHand, priority: priority, onHover: onHover).allowsHitTesting(false))
    }
}

// An overlaid AppKit tracking view that drives the cursor (via `CursorArbiter`) while the pointer is inside
// it. The widget panels are non-activating NSPanels, so SwiftUI's `pointerStyle`/`onHover` cursor and
// AppKit's `resetCursorRects`/`cursorUpdate` (each key-window-only) never fire inside them; an
// `.activeAlways` NSTrackingArea delivers enter/exit/MOVED regardless of activation. A single set-on-enter
// is NOT enough from a background app — the frontmost app's own cursor machinery (its mouseExited as the
// pointer crosses into our panel) races us and usually lands last, leaving the arrow showing with no further
// event to recover on. Re-asserting on every `.mouseMoved` while inside wins that race: our panel occludes
// the app beneath, so once inside we get all the moved events. Clicks pass straight through (hitTest → nil,
// plus SwiftUI hit-testing disabled at the call site) so the overlay only affects the cursor, never the
// control beneath it.
struct HoverCursor: NSViewRepresentable {
    let cursor: NSCursor
    var priority: Int = HoverPriority.control
    var onHover: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        TrackingView(cursor: cursor, priority: priority, onHover: onHover)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? TrackingView else { return }
        v.onHover = onHover
        v.cursor = cursor
    }

    fileprivate final class TrackingView: NSView {
        // Re-assert on change mid-hover (e.g. a runtime row flipping focusable → pointer style flips live).
        // Guarded on identity (the NSCursor class properties are singletons) so the every-update
        // `updateNSView` assignment doesn't run a redundant validation pass.
        var cursor: NSCursor {
            didSet { if inside, cursor !== oldValue { report() } }
        }
        let priority: Int
        var onHover: ((Bool) -> Void)?
        private var inside = false

        init(cursor: NSCursor, priority: Int, onHover: ((Bool) -> Void)?) {
            self.cursor = cursor
            self.priority = priority
            self.onHover = onHover
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                    owner: self))
        }
        override func mouseEntered(with event: NSEvent) { report() }
        // The frontmost app resets the cursor behind our back (see the type comment); win by re-asserting
        // on every moved event while the pointer is inside. Also our enter-recovery: a moved event with a
        // dropped/coalesced mouseEntered still registers the region.
        override func mouseMoved(with event: NSEvent) { report() }
        override func mouseExited(with event: NSEvent) { unreport() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }  // cursor only — pass clicks through
        // A panel rebuild can pull the view mid-hover without an exit event; withdraw from the arbiter so
        // this region can't hold the cursor forever. Only when the pointer is actually inside — the ~400 ms
        // store pumps rebuild sibling views constantly, and an unconditional withdraw from a torn-down
        // neighbor would fire a spurious onHover(false).
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, inside { unreport() }
        }

        private func report() {
            // Hover state derives from the arbiter's validation pass, not the raw event: an .activeAlways
            // tracking area fires geometrically even under an occluding window, so an enter proves nothing.
            let valid = CursorArbiter.shared.hover(self, cursor: cursor, priority: priority)
            if valid != inside {
                inside = valid
                onHover?(valid)
            }
        }
        private func unreport() {
            guard inside else { return }
            inside = false
            onHover?(false)
            CursorArbiter.shared.leave(self)
        }
        // The arbiter pruned this region (stale after a swallowed exit, occluded, or torn down): drop the
        // hover state without re-entering the arbiter — the region is already removed.
        func hoverPruned() {
            guard inside else { return }
            inside = false
            onHover?(false)
        }
    }
}

// MARK: - Palette

// One palette for every surface. The app pins `darkAqua` at launch, so these are the dark values as
// plain constants rather than colours that resolve per appearance.

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
    Color(red: r / 255, green: g / 255, blue: b / 255)
}
private func hex(_ v: Int) -> Color {
    rgb(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
}
extension Color {
    // Text / labels.
    static let csTitle = hex(0xF2F2_F5)  // primary text
    static let csLabel = hex(0xA6A6_B0)  // secondary labels, ghost glyphs, reset text
    static let csFaint = hex(0x7A7C_88)  // dimmest captions, periods, source note

    // Structure — borders, dividers, wells, cards, sidebar tiles.
    static let csBorder = Color.white.opacity(0.12)
    static let csDivider = Color.white.opacity(0.08)
    static let csWell = Color.white.opacity(0.08)  // meter track / control well
    static let csCard = Color.white.opacity(0.06)
    static let csSidebar = Color.white.opacity(0.03)
    static let csSidebarSel = Color.white.opacity(0.10)
    static let csTile = Color.white.opacity(0.07)
    static let csControlHover = Color.white.opacity(0.12)
    static let csRingTrack = hex(0x3030_30)  // the unburned part of a provider ring

    // Monochrome accent (segmented selection, slider fill, popup chevron) + its on-accent text. The
    // accent is a light surface, so anything drawn on it inverts against the tile rather than the window.
    static let csAccent = hex(0xF2F2_F5)
    static let csOnAccent = hex(0x1111_14)

    // Severity ramp + deeper gradient ends (constant fills — read on any glass).
    static let csOk = rgb(91, 208, 140)  // #5BD08C healthy
    static let csOkDeep = rgb(67, 185, 119)  // #43B977
    static let csAmber = rgb(240, 194, 90)  // #F0C25A warning / HITL
    static let csAmberDeep = rgb(216, 162, 60)  // #D8A23C
    static let csCrit = rgb(240, 122, 106)  // #F07A6A critical (usage)
    static let csCritDeep = rgb(217, 88, 63)  // #D9583F

    // Severity accent-text (reset line) — deep/legible on light glass, pastel on dark glass.
    static let csRed = rgb(235, 90, 82)  // #EB5A52 close button + Quit
}
