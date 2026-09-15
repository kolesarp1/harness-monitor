import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var snapshots: [NotchProvider] = []

    /// Which cell's card is showing. Set from the pointer when the card opens on hover; set by a
    /// click on a ring, and cleared by a second click or the fold, when it opens on click.
    ///
    /// The pointer's own position is deliberately NOT here: no view draws it, and publishing it
    /// invalidated the whole notch body on every crossing. It lives on the window controller.
    @Published var cardIndex: Int?
    /// Bumped each time the card goes from hidden to shown, and never when it moves between rings.
    /// It is the card's SwiftUI identity: a card still fading out from the last dismissal is the
    /// same structural view as the one about to appear, and without a fresh identity SwiftUI cancels
    /// the fade and slides it from the old ring to the new one. A new generation is a new view, so
    /// it gets the appearance while the old one finishes leaving; a move keeps the generation and
    /// glides.
    @Published var cardShowing = 0
    /// Whether the notch is open or folded away to its pill.
    @Published var isExpanded = false
    /// Clicked open, so it stays open until clicked shut again. A gesture,
    /// not a setting: it lasts as long as this session of looking at it.
    @Published var isPinned = false
    /// The settings handle is under the cursor.
    @Published var isHoveringSettings = false

    /// An "Update now" is running. Every ring presses in and turns once while it does — the rings are
    /// the readings being refetched, so the rings are what should move.
    @Published var isRefreshing = false

    /// The ring a ⌘-drag has picked up, and where its centre is along the stack right now — from the
    /// start of the shape, like `ringCenter(index:)`. The picked ring is drawn detached at that point,
    /// never in its slot: the slot stays in the stack as an invisible placeholder, so a swap animates
    /// the placeholder and the others around it while the ring simply follows the pointer. An offset
    /// from the slot would not do — the slot's position is mid-glide after every swap, and an offset
    /// measured from where it will end up drew the ring a whole cell behind the pointer until it got
    /// there. The pointer's own position still lives on the window controller; this is the one gesture
    /// where a view has to draw it.
    @Published var draggingIndex: Int?
    @Published var dragAlong: CGFloat = 0

    /// Which screen edge the notch is welded to. Everything geometric reads
    /// this through `NotchPlacement` rather than assuming an axis.
    @Published var edge: NotchEdge = .right

    /// Where the settings orb sits: concentric with the far flare, one radius in from the bezel and
    /// level with the end of the shape.
    var orbHandlePoint: CGPoint {
        CGPoint(x: shapeLength, y: NotchLayout.orbInsetFromEdge)
    }

    /// Whether a point in stack space is on the settings handle. A circle, not the box that contains
    /// it: the handle is a round thing on a screen edge, and a box takes in ground that is nowhere
    /// near it.
    func isOnOrbHandle(along: CGFloat, across: CGFloat) -> Bool {
        hypot(along - orbHandlePoint.x, across - orbHandlePoint.y) <= NotchLayout.orbHotZone / 2
    }

    /// Where the hover card starts, measured in from the bezel: just off the inner face of the shape.
    var cardInset: CGFloat {
        NotchLayout.bodyDepth(for: edge) + NotchLayout.cardGap
    }

    /// Distance along the stack to cell `index`'s ring centre.
    func ringCenter(index: Int) -> CGFloat {
        NotchLayout.ringCenter(index: index, edge: edge)
    }

    var cardSnapshot: NotchProvider? {
        guard let cardIndex, snapshots.indices.contains(cardIndex) else { return nil }
        return snapshots[cardIndex]
    }

    // MARK: - Sizing

    /// The panel is sized once for the whole stack, so it has to hold whichever
    /// card is biggest. Taken from the cards actually measured rather than from
    /// a ceiling guessed here: `UsageSection`'s height depends on the layout,
    /// the provider's window count and the token strip, and a card taller than
    /// the panel is not scrolled or grown — it is clipped, at the top.
    func cardSize(_ providers: [NotchProvider]) -> CGSize {
        CGSize(
            width: NotchCardMetrics.totalWidth,
            height: providers.map(\.cardSize.height).max() ?? NotchCardMetrics.minHeight)
    }

    var shapeLength: CGFloat { shapeLength(cellCount: snapshots.count) }
    var panelSize: CGSize { panelSize(for: snapshots) }
    var slack: CGFloat { slack(for: snapshots) }

    func slack(for providers: [NotchProvider]) -> CGFloat {
        NotchLayout.slack(for: edge, cardSize: cardSize(providers))
    }

    /// Sized from an explicit list rather than from `snapshots`.
    ///
    /// `@Published` notifies its subscribers in `willSet`, so anything reacting
    /// to a change in the provider list still sees the *old* array if it reads
    /// the model back. Taking the list as an argument is the only way to be
    /// sure the panel is sized for the list that caused the change.
    func shapeLength(cellCount: Int) -> CGFloat {
        NotchLayout.shapeLength(cellCount: cellCount, edge: edge)
    }

    func panelSize(for providers: [NotchProvider]) -> CGSize {
        let card = cardSize(providers)
        return NotchPlacement.panelSize(
            edge: edge,
            length: shapeLength(cellCount: providers.count)
                + 2 * NotchLayout.slack(for: edge, cardSize: card),
            depth: NotchLayout.cardDepth(for: edge, cardSize: card)
                + NotchLayout.bodyDepth(for: edge))
    }

    // MARK: - Folded state

    /// The drawn extent of the notch body right now, along the stack.
    var notchLength: CGFloat {
        isExpanded ? shapeLength : NotchLayout.pillHeight
    }

    /// And across it.
    var notchDepth: CGFloat {
        isExpanded ? NotchLayout.bodyDepth(for: edge) : NotchLayout.pillWidth
    }

    /// What the notch folds away to, whether or not it is open right now —
    /// the hit region has to know that while the notch is still open.
    var restingLength: CGFloat { NotchLayout.pillHeight }
    var restingDepth: CGFloat { NotchLayout.pillWidth }

    /// The drawn size of the notch body, in panel axes.
    var notchSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth)
    }

    /// Where the notch starts along the stack. Both states share a centre line,
    /// so folding away does not slide the notch along the edge as it shrinks.
    var notchLeadingInset: CGFloat {
        slack + (shapeLength - notchLength) / 2
    }
}
