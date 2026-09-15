import HarnessUsageCore
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    // The hover card is `UsageSection`, which reads the stores directly. The notch supplies only the
    // anchor: which provider (via `selection`, set from the hovered ring) and where the card sits.
    let usage: UsageStore
    let settings: SettingsStore
    let selection: ProviderSelection
    let accounts: [Integration]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Handed to every subview that measures off `Design`, because a global is not one of their
    /// inputs and SwiftUI would otherwise leave them drawn at the previous Size — see
    /// `Design.multiplier`.
    private var scale: CGFloat { Design.multiplier }

    var body: some View {
        // Measured rather than assumed: the panel's real size is whatever
        // AppKit settled on, and the notch has to sit flush against *that*
        // edge, not against the size we asked for.
        GeometryReader { proxy in
            let place = NotchPlacement(edge: model.edge, panelSize: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                notch(place)

                // Outside the notch and outside its clip: the orb hangs past
                // the end of the shape, tucked into the corner the far flare
                // makes. Drawn even with every ring switched off — it is the
                // way to Settings, and an empty notch needs that most.
                SettingsOrb(isHovered: model.isHoveringSettings, edge: model.edge, scale: scale)
                    .position(orbCentre(place))
                    // Outward, into the black — not inward to nothing.
                    .scaleEffect(model.isExpanded ? 1 : NotchLayout.orbMergeScale)
                    // Full strength the whole way in. The arc is buried in the
                    // notch before this reaches zero, so the fade is only there
                    // to guarantee nothing is left on screen once the notch has
                    // folded — it is never what the eye sees the arc leave by.
                    .opacity(model.isExpanded ? 1 : 0)
                    .animation(motion(orbMotion), value: model.isExpanded)

                if let provider = model.cardSnapshot, let index = model.cardIndex,
                    model.isExpanded
                {
                    NotchUsageCard(
                        usage: usage, settings: settings, selection: selection, scale: scale,
                        accounts: accounts
                    )
                    // Identity per showing, not per ring: between rings the card
                    // is one object that travels, which reads far better than
                    // one card leaving and another arriving; from hidden it is a
                    // new object, or a card still fading out would be cancelled
                    // and slid into place. See `NotchViewModel.cardShowing`.
                    .id(model.cardShowing)
                    .position(cardCentre(place, index: index, provider: provider))
                    .transition(
                        .opacity.combined(
                            with: .offset(
                                x: model.edge.outward.x * Design.px(24),
                                y: model.edge.outward.y * Design.px(24))))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(motion(NotchMotion.unfold), value: model.isExpanded)
    }

    /// Opening and closing are not mirror images. Appearing, the arc waits its
    /// turn behind the cells before it; hiding, any delay at all lets the notch
    /// start folding first, and the arc reads as going with the frame rather
    /// than into it.
    private var orbMotion: Animation {
        model.isExpanded ? NotchMotion.stagger(index: model.snapshots.count) : NotchMotion.merge
    }

    private func notch(_ place: NotchPlacement) -> some View {
        let shape = SideNotchShape(
            edge: model.edge, curlRadius: NotchLayout.curlRadius, cornerRadius: NotchLayout.cornerRadius)
        // Dark glass rather than flat black: the vibrancy is masked by this same shape, so the
        // desktop moves under the notch instead of being blanked out by it.
        return Color.clear
            .frame(width: model.notchSize.width, height: model.notchSize.height)
            .notchGlass(shape)
            // Aligned to the corner where the stack starts *and* the bezel is,
            // rather than centred: the stack's own padding is what positions it.
            .overlay(alignment: contentAlignment) { cells }
            // Above every cell, including the one it is being swapped with.
            .overlay { carried }
            // Masked by the notch itself, not by its bounding box. Without this
            // the cells simply sit on top of a shrinking shape and appear to
            // slide out of the end of it; clipped, they are swallowed by the
            // outline as it closes, which is what a notch should do.
            .clipShape(shape)
            .position(
                place.point(
                    along: model.notchLeadingInset + model.notchLength / 2,
                    across: model.notchDepth / 2))
    }

    /// The cells fade and lift into place a beat after the shape starts opening,
    /// each trailing the one before it. Folded shut they are not just hidden but
    /// pulled toward the edge, so the whole thing reads as one movement.
    @ViewBuilder
    private var cells: some View {
        let stack = ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, provider in
            ProviderCell(provider: provider, scale: scale, isRefreshing: model.isRefreshing)
                // Pinned to what the cell claims along the stack, or the drawn
                // rings stop lining up with the centres `ringCenter` hands to
                // the hover bands and the tooltip tails.
                .frame(width: model.edge.isVertical ? nil : NotchLayout.cellAlong(for: model.edge))
                .opacity(model.isExpanded ? 1 : 0)
                // A short slide toward the edge, no scaling: the clip is already
                // doing the concealing, and scaling on top of it reads as two
                // effects fighting.
                .offset(
                    x: model.isExpanded ? 0 : model.edge.outward.x * Design.px(28),
                    y: model.isExpanded ? 0 : model.edge.outward.y * Design.px(28)
                )
                .animation(motion(NotchMotion.stagger(index: index)), value: model.isExpanded)
                // A ⌘-dragged ring is drawn by `carried`, at the pointer. Its cell stays here as an
                // invisible placeholder: it keeps the slot, so the others glide around it on a swap.
                .opacity(model.draggingIndex == index ? 0 : 1)
        }

        Group {
            if model.edge.isVertical {
                VStack(spacing: NotchLayout.cellSpacing) { stack }
                    .padding(.top, leadIn)
                    // The contents keep the expanded layout while folding, so the
                    // stack does not reflow on its way out; the shape clips it.
                    .frame(width: NotchLayout.bodyDepth(for: model.edge))
            } else {
                HStack(spacing: NotchLayout.cellSpacing) { stack }
                    .padding(.leading, leadIn)
                    .frame(height: NotchLayout.bodyDepth(for: model.edge))
            }
        }
        .allowsHitTesting(model.isExpanded)
    }

    /// The ring a ⌘-drag is carrying, drawn over the stack at the pointer rather than in its slot —
    /// see `NotchViewModel.draggingIndex`. `position` takes the cell's centre, and the cell is longer
    /// than its ring down a side edge, where the label follows the ring along the stack.
    @ViewBuilder
    private var carried: some View {
        if let index = model.draggingIndex, model.snapshots.indices.contains(index) {
            let inNotch = NotchPlacement(edge: model.edge, panelSize: model.notchSize)
            ProviderCell(provider: model.snapshots[index], scale: scale, isRefreshing: model.isRefreshing)
                .frame(width: model.edge.isVertical ? nil : NotchLayout.cellAlong(for: model.edge))
                .position(
                    inNotch.point(
                        along: model.dragAlong
                            + (NotchLayout.cellAlong(for: model.edge) - NotchLayout.ringDiameter) / 2,
                        across: NotchLayout.bodyDepth(for: model.edge) / 2)
                )
                // It replaces a cell that is already drawn, pixel for pixel, and is replaced by one:
                // a fade at either end would show the ring dipping.
                .transition(.identity)
        }
    }

    /// The corner of the shape's own frame where the stack starts and the
    /// bezel is — the origin everything inside it is measured from.
    private var contentAlignment: Alignment {
        switch model.edge {
        case .right: return .topTrailing
        case .left: return .topLeading
        case .top: return .topLeading
        case .bottom: return .bottomLeading
        }
    }

    /// Which side of that frame faces the bezel.
    private var bezelSide: Edge.Set {
        switch model.edge {
        case .right: return .trailing
        case .left: return .leading
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    /// Distance from the start of the shape to the first cell.
    private var leadIn: CGFloat {
        NotchLayout.curlRadius + NotchLayout.padStart(for: model.edge)
    }

    private func motion(_ animation: Animation) -> Animation? {
        NotchMotion.respectingReduceMotion(animation, reduceMotion)
    }

    /// The orb sits on the flare's own centre of curvature, one radius in from
    /// the bezel and level with the far end of the shape.
    private func orbCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(along: model.slack + model.orbHandlePoint.x, across: model.orbHandlePoint.y)
    }

    /// The card is centred on the ring it belongs to, so its tail's tip lands on
    /// that ring, `cardGap` in from the notch's inner face — the clear margin
    /// around the card is not part of that gap. `position` takes a centre, so
    /// the depth is measured to the middle of the card rather than to its tip.
    private func cardCentre(
        _ place: NotchPlacement, index: Int, provider: NotchProvider
    ) -> CGPoint {
        let depth = model.edge.isVertical ? provider.cardSize.width : provider.cardSize.height
        return place.point(
            along: model.slack + model.ringCenter(index: index),
            across: model.cardInset - NotchCardMetrics.margin + depth / 2)
    }
}
