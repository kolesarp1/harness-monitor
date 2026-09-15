import AppKit
import HarnessUsageCore
import SwiftUI

// Owns the notch panel: where it sits, which regions take the mouse, and when it folds open or shut.
//
// The panel is far larger than the notch — it reserves room for the tooltip — so everything outside
// the visible chrome is a hole that passes clicks through. `interactiveRects` is what keeps it that
// way, and every rect in this file is in stack space (`along`/`across`) before `NotchPlacement` maps
// it onto the screen edge the notch is welded to.
@MainActor
final class NotchWindowController {
    let model = NotchViewModel()

    /// Open the Settings window, asked for by clicking the orb or by the right-click menu.
    var onOpenSettings: (() -> Void)?

    /// Read every provider again, now — the right-click menu's "Update now". Returns when the
    /// readings have landed, which is what holds the rings' spin up for exactly as long as it took.
    var onRefresh: (() async -> Void)?

    private let usage: UsageStore
    private let settings: SettingsStore
    // The tracked accounts, in `accounts.json` order — the card's fallback provider is picked from
    // this list, so it has to be the app's real one and not a global read from inside a view.
    private let accounts: [Integration]
    /// Which provider the hover card shows. `UsageSection` reads it and the hover logic writes it, so
    /// the ring under the pointer is the provider the card is about.
    private let selection = ProviderSelection()

    init(usage: UsageStore, settings: SettingsStore, accounts: [Integration]) {
        self.accounts = accounts
        self.usage = usage
        self.settings = settings
    }

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<NotchRootView>?
    private var screenObserver: NSObjectProtocol?
    private var mouseMonitors: [Any] = []
    private var clearHoverWork: DispatchWorkItem?
    private var cursorTimer: Timer?
    /// One-way: the notch is the app's only surface, so once shown it is never hidden.
    private var isShown = false

    /// Hover in is quick; hover out waits, because the pointer has to cross the
    /// gap between the notch and the card without the card vanishing under it.
    private let hoverGrace: TimeInterval = 0.25
    /// Longer than the hover grace: folding shut is a bigger movement than
    /// dismissing a tooltip, and doing it the instant the pointer strays feels
    /// twitchy rather than responsive.
    private let foldGrace: TimeInterval = 0.45
    private var foldWork: DispatchWorkItem?
    /// Whether we were the last thing to write the cursor, so the arrow is restored exactly once.
    private var isLastCursorSetter = false
    /// Which cell the pointer is over, if any. Controller state, not the view model's: no view draws
    /// it, and publishing it invalidated the whole notch body on every crossing.
    private var hoveredIndex: Int?
    /// The usable area the panel was last placed against.
    ///
    /// The notch is pinned to `visibleFrame` so it rests on the Dock rather than
    /// under it — but an auto-hiding Dock revealing or concealing itself fires
    /// no screen-parameter notification, so nothing would tell us the space had
    /// come back. The cursor poll is already running; noticing there costs one
    /// rect comparison every 0.3s and needs no new machinery.
    private var lastVisibleFrame: CGRect?

    // MARK: - Lifecycle

    func show() {
        // The panel sits at `.statusBar` level with nothing above it, so once it is up there is
        // nothing to re-order it in front of — a second call is genuinely nothing to do.
        guard !isShown else { return }
        isShown = true
        relocate(providers: model.snapshots)
        startWatchingCursor()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate(providers: self?.model.snapshots ?? []) }
        }
    }

    // MARK: - Data

    /// The provider list changed. The notch is as long as that list and as deep
    /// as the busiest card in it, so this resizes the panel rather than only
    /// redrawing inside it.
    func apply(providers: [NotchProvider]) {
        // Judged against the frame AppKit actually gave the panel, so a change in the provider count,
        // in a card's measured size or in the Size setting all resize it, and nothing else does.
        let wanted = model.panelSize(for: providers)
        let wantedRounded = CGSize(width: wanted.width.rounded(.up), height: wanted.height.rounded(.up))
        let resized = panel.map { $0.frame.size != wantedRounded } ?? true
        model.snapshots = providers
        invalidateGeometry()
        if hoveredIndex.map({ !providers.indices.contains($0) }) ?? false { hoveredIndex = nil }
        if model.cardIndex.map({ !providers.indices.contains($0) }) ?? false { model.cardIndex = nil }
        // A card index that survives the change may now be a different provider — a ring above it
        // was switched off — and the card must follow the ring, not the index.
        if let index = model.cardIndex {
            syncSelection(to: providers[index].integration)
        }
        guard isShown else { return }
        if resized || panel == nil {
            relocate(providers: providers)
        } else {
            updateInteractiveRects()
        }
    }

    // MARK: - Placement

    func relocate(providers: [NotchProvider]) {
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens) else { return }
        let size = model.panelSize(for: providers)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: model.edge)
        lastVisibleFrame = screen.visibleFrame

        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = NotchPanel(contentRect: frame)
            let hosting = NotchHostingView(
                rootView: NotchRootView(
                    model: model, usage: usage, settings: settings, selection: selection,
                    accounts: accounts))
            panel.contextMenuProvider = { [weak self] in self?.contextMenu() }
            panel.onClick = { [weak self] in self?.handleClick() }
            panel.onReorderBegan = { [weak self] in self?.beginReorder() ?? false }

            // The hosting view goes *inside* a plain container rather than being
            // the content view itself. As the content view, SwiftUI gets a say in
            // the window's frame: it reports the content's ideal size, and this
            // view's root is a `GeometryReader`, whose ideal size is 10x10. A
            // container removes that channel instead of arguing with it — the
            // panel's size comes from `NotchGeometry` and from nowhere else,
            // which is what every hit region in this file already assumes.
            let container = NotchContainerView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            self.panel = panel
            self.hostingView = hosting
        }
        invalidateGeometry()  // the panel's real frame is what every hit region is measured against
        updateInteractiveRects()
    }

    // MARK: - Hit regions

    /// Every hit region, derived once per change rather than once per event.
    ///
    /// `cursorMoved` runs on every global mouse-moved event and on the 0.3s poll, and each of these
    /// rects walks the whole layout — `NotchLayout` is computed properties down to
    /// `percentLineHeight`, which builds an `NSFont`. Nothing feeding them moves between events: the
    /// panel's frame, the provider list, the fold state, the card index and `Design.multiplier` all
    /// change through a path that calls `invalidateGeometry()`.
    private struct Geometry {
        let placement: NotchPlacement
        let slack: CGFloat
        /// The notch itself, in panel coordinates with a top-left origin.
        let notchRect: CGRect
        /// The handle's bounding box, for deciding whether the panel takes events at all. Whether a
        /// point is actually *on* the handle is a finer question than a box can answer.
        let handleRect: CGRect
        /// The only region that takes the mouse. Everything else in the panel is a hole — which
        /// matters far more folded than open, since the point of folding away is to stop being in
        /// the way.
        let liveRect: CGRect
        /// The card currently showing, plus the gap between it and the notch — so sliding the
        /// pointer off a ring and onto the card never leaves the live region on the way.
        let cardRect: CGRect?
        /// Ring centres along the stack, in panel-relative stack coordinates.
        let ringCentres: [CGFloat]
        let cellPitch: CGFloat
        let orbHandlePoint: CGPoint
    }

    private var cachedGeometry: Geometry?

    private func invalidateGeometry() { cachedGeometry = nil }

    private var geometry: Geometry {
        if let cachedGeometry { return cachedGeometry }
        let built = makeGeometry()
        cachedGeometry = built
        return built
    }

    private func makeGeometry() -> Geometry {
        // The panel's REAL size, which AppKit may have rounded up from the one we asked for — and
        // which the flush edge depends on.
        let placement = NotchPlacement(edge: model.edge, panelSize: panel?.frame.size ?? model.panelSize)
        let slack = model.slack
        let notchRect = placement.rect(
            along: slack, across: 0, length: model.shapeLength, depth: model.notchDepth)

        let side = NotchLayout.orbHotZone
        let orbHandlePoint = model.orbHandlePoint
        let orbCentre = placement.point(along: slack + orbHandlePoint.x, across: orbHandlePoint.y)
        let handleRect = CGRect(
            x: orbCentre.x - side / 2, y: orbCentre.y - side / 2, width: side, height: side)

        let liveRect: CGRect
        if model.isExpanded {
            // The orb hangs past the end of the shape, so the live region is both together.
            liveRect = notchRect.union(handleRect)
        } else {
            // Deliberately larger than the pill it surrounds — a 10pt target on a screen edge is a
            // fiddly thing to hit, and the cost of being generous is only that it opens a little
            // eagerly.
            let length = max(model.restingLength, NotchLayout.pillHotZone)
            liveRect = placement.rect(
                along: slack + (model.shapeLength - length) / 2, across: 0, length: length,
                depth: model.restingDepth + NotchLayout.pillHotZone)
        }

        return Geometry(
            placement: placement,
            slack: slack,
            notchRect: notchRect,
            handleRect: handleRect,
            liveRect: liveRect,
            cardRect: model.cardIndex.flatMap { cardRect(index: $0, placement: placement, slack: slack) },
            ringCentres: model.snapshots.indices.map { slack + model.ringCenter(index: $0) },
            cellPitch: NotchLayout.cellPitch(for: model.edge),
            orbHandlePoint: orbHandlePoint)
    }

    /// The card carries a shadow ring on every side, which is transparent but is part of the measured
    /// size; including it here costs nothing (the panel is a hole either way) and keeps this rect and
    /// the drawn card the same object.
    private func cardRect(index: Int, placement: NotchPlacement, slack: CGFloat) -> CGRect? {
        guard model.snapshots.indices.contains(index) else { return nil }
        let size = model.snapshots[index].cardSize
        let across = model.edge.isVertical ? size.width : size.height
        let along = model.edge.isVertical ? size.height : size.width
        let centre = slack + model.ringCenter(index: index)
        return placement.rect(
            along: centre - along / 2,
            across: NotchLayout.bodyDepth(for: model.edge),
            length: along,
            depth: NotchLayout.cardGap + across)
    }

    /// Whether the pointer is on the handle itself rather than merely inside the box that contains it.
    private func isOverHandle(_ local: CGPoint) -> Bool {
        let g = geometry
        return model.isOnOrbHandle(
            along: g.placement.along(of: local) - g.slack, across: g.placement.across(of: local))
    }

    private func updateInteractiveRects() {
        let g = geometry
        var rects = [g.liveRect]
        if model.isExpanded, let card = g.cardRect { rects.append(card) }
        hostingView?.interactiveRects = rects
        if let panel {
            // A drag in flight keeps its events wherever the pointer has wandered to: the gesture
            // ends on mouse-up, and a panel that stopped taking events would never see one.
            panel.ignoresMouseEvents =
                reorder == nil && !rects.contains { $0.contains(localCursor(in: panel.frame)) }
        }
    }

    // MARK: - Cursor tracking

    /// A global monitor catches the outside-to-inside crossing while the panel
    /// is still ignoring events; a local one catches the way back out.
    ///
    /// A slow poll backs both of them up, because a cursor that never moves
    /// produces no events at all — so a notch that appears, resizes or is
    /// re-anchored underneath a parked pointer would otherwise sit there with
    /// stale hover state until the user jogged the mouse.
    private func startWatchingCursor() {
        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only on the poll, not on every mouse-moved event: this reads
                // the screen list, and doing that per event would be work at
                // 60Hz to answer a question that changes twice a minute.
                self?.followUsableAreaIfItMoved()
                self?.cursorMoved()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        cursorTimer = poll

        // On click, the card leaves the way a popover does: a click anywhere but the card or the
        // notch dismisses it. The panel is a hole outside its own chrome, so those clicks never reach
        // it — a global monitor sees them land in other apps, a local one sees them land on this
        // app's own windows. Both fire after the click has been delivered, so this only ever
        // dismisses; it never takes the click from whatever was clicked.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let dismiss: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissCardIfClickedOutside() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: dismiss) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: clicks,
            handler: { event in
                dismiss(event)
                return event
            })
        {
            mouseMonitors.append(local)
        }

        // Where a ⌘-drag ends, wherever the button happens to be let go. Watched here rather than on
        // the panel because a gesture that could only end on the panel could fail to end at all —
        // and an unfinished drag holds the notch open with a ring in mid-air.
        let releases: NSEvent.EventTypeMask = [.leftMouseUp]
        let release: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.endReorder() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: releases, handler: release) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: releases,
            handler: { event in
                release(event)
                return event
            })
        {
            mouseMonitors.append(local)
        }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: events,
            handler: { event in
                handler(event)
                return event
            })
        {
            mouseMonitors.append(local)
        }
    }

    private func dismissCardIfClickedOutside() {
        guard cardTrigger == .click, model.cardIndex != nil, let panel else { return }
        let local = localCursor(in: panel.frame)
        let g = geometry
        guard !(g.cardRect?.contains(local) ?? false), !g.notchRect.contains(local) else { return }
        setCardIndex(nil, animation: NotchMotion.dismiss)
        updateInteractiveRects()
    }

    private func localCursor(in frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    /// Has the Dock appeared, gone away, moved or resized since we last placed
    /// the panel? Nothing notifies us, so this is asked rather than told.
    private func followUsableAreaIfItMoved() {
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens) else { return }
        guard screen.visibleFrame != lastVisibleFrame else { return }
        relocate(providers: model.snapshots)
    }

    private func cursorMoved() {
        guard isShown, let panel else { return }
        // A ⌘-drag owns the pointer until it is let go: the ring in hand follows it, the notch does
        // not fold out from under it, and the card does not trail it through the stack.
        guard reorder == nil else { return continueReorder() }
        let local = localCursor(in: panel.frame)
        let onCard = model.isExpanded && (geometry.cardRect?.contains(local) ?? false)
        setExpanded(geometry.liveRect.contains(local) || onCard)

        // Re-read after `setExpanded`: opening changes every rect below.
        let g = geometry
        let inNotch = model.isExpanded && g.notchRect.contains(local)
        var target: Int?
        if inNotch {
            target = cellIndex(along: g.placement.along(of: local))
        } else if model.isExpanded, let current = model.cardIndex,
            g.cardRect?.contains(local) ?? false
        {
            target = current
        }

        // The rings are readings, not buttons — the one thing here you can click
        // for an action is the settings handle, so it is the one thing that says
        // so with the cursor.
        let overHandle = model.isExpanded && isOverHandle(local)
        if model.isHoveringSettings != overHandle { model.isHoveringSettings = overHandle }
        // A ring is a button only when the card opens on click.
        setPointing(overHandle || (inNotch && cardTrigger == .click && target != nil))

        if let target {
            clearHoverWork?.cancel()
            clearHoverWork = nil
            hoveredIndex = target
            // On hover the card follows the pointer; on click it waits for `handleClick`.
            if cardTrigger == .hover { showCard(at: target) }
        } else if hoveredIndex != nil, clearHoverWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearHoverWork = nil
                    self.hoveredIndex = nil
                    // A clicked card stays until its ring is clicked again or the notch folds.
                    if self.cardTrigger == .hover {
                        self.setCardIndex(nil, animation: NotchMotion.dismiss)
                    }
                }
            }
            clearHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverGrace, execute: work)
        }

        updateInteractiveRects()
    }

    /// The one writer of `cardIndex`, because the derived rects have to be rebuilt with it.
    private func setCardIndex(_ index: Int?, animation: Animation) {
        guard model.cardIndex != index else { return }
        withAnimation(animation) { model.cardIndex = index }
        invalidateGeometry()
    }

    /// Opens on contact, folds shut after a pause — unless it has been pinned
    /// open or its own right-click menu is up, in which cases the pointer is not what decides.
    private func setExpanded(_ wanted: Bool) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            invalidateGeometry()
            return
        }

        // The notch's own menu runs a nested tracking loop, and the pointer is over the menu rather
        // than the notch for its whole life — so without this the notch folded away underneath the
        // menu the user had just opened on it. Dismissing the menu resumes the normal fold grace,
        // because the poll asks again within 0.3s.
        guard model.isExpanded, !model.isPinned, !isShowingContextMenu, foldWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldWork = nil
                guard !self.model.isPinned, !self.isShowingContextMenu else { return }
                self.hoveredIndex = nil
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.cardIndex = nil
                }
                self.invalidateGeometry()
                self.setPointing(false)
                self.updateInteractiveRects()
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace, execute: work)
    }

    private var isShowingContextMenu: Bool { panel?.isShowingContextMenu ?? false }

    /// Re-asserted on every pointer event, never pushed.
    ///
    /// A single `set()` from a non-frontmost app loses the race against the frontmost app's own
    /// cursor writes — the failure `docs/glass-widgets.md` documents, and the reason `CursorArbiter`
    /// re-asserts on every mouse-move too. `push`/`pop` is worse: this panel's exits are advisory
    /// (the pointer can leave without an event landing here), and a dropped exit strands a pushed
    /// cursor on the stack forever. So: assert while over the target; on the way out restore the
    /// arrow ONCE, as the last setter, then go quiet rather than fighting other apps for a pointer
    /// that has left.
    private func setPointing(_ wanted: Bool) {
        if wanted {
            isLastCursorSetter = true
            NSCursor.pointingHand.set()
        } else if isLastCursorSetter {
            isLastCursorSetter = false
            NSCursor.arrow.set()
        }
    }

    // MARK: - Reordering

    /// Which ring a ⌘-drag picked up, and where in that ring the pointer grabbed it — measured from
    /// the ring's own centre, so the cell rides under the pointer instead of jumping to it.
    private var reorder: (index: Int, grab: CGFloat)?

    /// ⌘-drag on a ring, the gesture the menu bar teaches for the same job. Only on the open notch,
    /// and only with something to reorder; anything else leaves the click to `handleClick`.
    private func beginReorder() -> Bool {
        guard model.isExpanded, model.snapshots.count > 1, let panel else { return false }
        let g = geometry
        let local = localCursor(in: panel.frame)
        guard g.notchRect.contains(local), let index = cellIndex(along: g.placement.along(of: local))
        else { return false }

        // Rearranging is not reading: left open, the card would trail the pointer through the stack,
        // and its index names a different provider after every swap.
        setCardIndex(nil, animation: NotchMotion.dismiss)
        hoveredIndex = nil
        reorder = (index, g.placement.along(of: local) - g.ringCentres[index])
        model.draggingIndex = index
        model.dragAlong = model.ringCenter(index: index)
        updateInteractiveRects()
        return true
    }

    /// The pointer moved with a ring in hand: carry it, and swap it into whichever slot the pointer
    /// is now over — crossing a ring's centre is what moves it.
    private func continueReorder() {
        guard let picked = reorder, let panel else { return }
        let g = geometry
        // The stack can change under a drag — a harness switching off, or losing its detection — and
        // an index into a list that no longer has it is not something to keep carrying.
        guard g.ringCentres.indices.contains(picked.index), let first = g.ringCentres.first,
            let last = g.ringCentres.last
        else { return endReorder() }
        // Held between the end slots, as the menu bar holds its items: past the last ring the pointer
        // keeps going and the ring stops, rather than vanishing under the flare.
        let along = min(max(g.placement.along(of: localCursor(in: panel.frame)) - picked.grab, first), last)
        if let slot = g.ringCentres.firstIndex(where: { abs(along - $0) <= g.cellPitch / 2 }),
            slot != picked.index
        {
            var list = model.snapshots
            list.insert(list.remove(at: picked.index), at: slot)
            reorder = (slot, picked.grab)
            // One transaction: the placeholder is whichever cell holds the picked provider, and the
            // list is what says which cell that is.
            withAnimation(NotchMotion.glide) {
                model.snapshots = list
                model.draggingIndex = slot
            }
            // Written on every swap rather than on release: the engine rebuilds the provider list on
            // its own schedule, and a tick landing mid-drag would otherwise put the stack back as it
            // was. The list holds only what is on the notch — a provider switched off or absent from
            // this Mac rejoins at the end, which is where a newly detected one arrives too.
            var settings = self.settings.settings
            settings.providerOrder = list.map(\.integration)
            self.settings.update(settings)
            invalidateGeometry()
        }
        // After the swap's transaction, never inside it: the ring is under the pointer, not on its way.
        model.dragAlong = along - g.slack
    }

    private func endReorder() {
        guard let picked = reorder else { return }
        reorder = nil
        // The ring glides from wherever it was let go into its slot, and only then does the slot's
        // own cell take over: any earlier and it drops in on the frame the pointer let go of it. A
        // drag begun before that lands owns the state by then, and is left to it.
        withAnimation(NotchMotion.glide, completionCriteria: .logicallyComplete) {
            model.dragAlong = model.ringCenter(index: picked.index)
        } completion: { [weak self] in
            guard let self, self.reorder == nil else { return }
            self.model.draggingIndex = nil
        }
        updateInteractiveRects()
    }

    /// A click on the settings handle opens Settings; a click anywhere else on
    /// the open notch pins it, so it stays put while you read it.
    func handleClick() {
        // A new press means the last gesture is over, whether or not its release was ever seen — the
        // one place a missed mouse-up would otherwise leave a ring in mid-air.
        endReorder()
        guard let panel, model.isExpanded else {
            // Opens it, the same as the pointer arriving would — it must not also
            // pin it. The pill's hot zone is deliberately generous, so a click
            // aimed at something else nearby can land here without the notch ever
            // having been seen open.
            setExpanded(true)
            return
        }
        let local = localCursor(in: panel.frame)
        if isOverHandle(local) {
            onOpenSettings?()
            return
        }
        // The card is a readout, not a control. Falling through from here pinned the notch, which is
        // a gesture nobody aimed at when they clicked a number.
        if geometry.cardRect?.contains(local) ?? false { return }
        // On click, a ring is a button: it opens its card, and a second click on the same ring closes
        // it. Anywhere else on the open notch still pins it.
        let g = geometry
        if cardTrigger == .click, g.notchRect.contains(local),
            let index = cellIndex(along: g.placement.along(of: local))
        {
            if model.cardIndex == index {
                setCardIndex(nil, animation: NotchMotion.dismiss)
            } else {
                showCard(at: index)
            }
            updateInteractiveRects()
            return
        }
        togglePinned()
    }

    private var cardTrigger: CardTrigger { settings.settings.cardTrigger }

    /// Keyed on the provider, not the index: the same index can name a different provider after the
    /// list changes. The selection is set before the index, so the card already shows the right
    /// provider on the frame it appears — set after, it renders once with the previous one and swaps.
    private func showCard(at index: Int) {
        syncSelection(to: model.snapshots[index].integration)
        guard model.cardIndex != index else { return }
        // Appearing and moving are different movements. Both writes sit in one transaction so the
        // new identity and the new index land in the same frame.
        let appearing = model.cardIndex == nil
        withAnimation(appearing ? NotchMotion.cardOpen : NotchMotion.glide) {
            if appearing { model.cardShowing += 1 }
            model.cardIndex = index
        }
        invalidateGeometry()
    }

    func togglePinned() {
        model.isPinned.toggle()
        if model.isPinned {
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            invalidateGeometry()
        }
        updateInteractiveRects()
    }

    /// `ProviderSelection` is `@Observable`, so an unguarded write invalidates the card on every
    /// poll tick; only a real change goes through.
    private func syncSelection(to provider: Integration) {
        if selection.integration != provider { selection.integration = provider }
    }

    private func cellIndex(along: CGFloat) -> Int? {
        let g = geometry
        return g.ringCentres.firstIndex { abs(along - $0) <= g.cellPitch / 2 }
    }

    // MARK: - Odds and ends

    /// The rings turn once and hold pressed until the readings land, but never for less than one
    /// turn: a local rescan can finish in a few milliseconds, and a press that never renders reads as
    /// a menu item that did nothing.
    func refreshNow() {
        guard !model.isRefreshing else { return }
        model.isRefreshing = true
        Task {
            let turn = Task { try? await Task.sleep(for: .seconds(NotchMotion.refreshSpinSeconds)) }
            await onRefresh?()
            _ = await turn.value
            model.isRefreshing = false
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        // AppKit otherwise decides enablement itself and overrules the lines
        // below. Turning it off means every item has to say so for itself.
        menu.autoenablesItems = false

        let keepOpen = NSMenuItem(
            title: "Keep open", action: #selector(NotchMenuActions.togglePinned(_:)),
            keyEquivalent: "")
        keepOpen.target = menuActions
        keepOpen.state = model.isPinned ? .on : .off
        keepOpen.isEnabled = true
        menu.addItem(keepOpen)

        let update = NSMenuItem(
            title: "Update now", action: #selector(NotchMenuActions.refreshNow(_:)),
            keyEquivalent: "")
        update.target = menuActions
        // Disabled while one is running, which is also what the guard in `refreshNow` enforces: the
        // item saying so is the difference between a press that is refused and one that looks ignored.
        update.isEnabled = !model.isRefreshing
        menu.addItem(update)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(NotchMenuActions.openSettings(_:)),
            keyEquivalent: ",")
        settings.target = menuActions
        settings.isEnabled = true
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Harness Usage", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ).isEnabled = true
        return menu
    }

    private lazy var menuActions = NotchMenuActions(
        togglePinned: { [weak self] in self?.togglePinned() },
        refreshNow: { [weak self] in self?.refreshNow() },
        openSettings: { [weak self] in self?.onOpenSettings?() })
}

/// A menu item needs an Objective-C target, which a `@MainActor` Swift class with closures cannot be
/// directly.
final class NotchMenuActions: NSObject {
    private let pin: () -> Void
    private let refresh: () -> Void
    private let settings: () -> Void

    init(
        togglePinned: @escaping () -> Void, refreshNow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.pin = togglePinned
        self.refresh = refreshNow
        self.settings = openSettings
    }

    @objc func togglePinned(_ sender: Any?) { pin() }
    @objc func refreshNow(_ sender: Any?) { refresh() }
    @objc func openSettings(_ sender: Any?) { settings() }
}
