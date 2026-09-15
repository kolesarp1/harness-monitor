import AppKit

/// Every measurement is quoted in design-frame pixels so it can be checked
/// against Codenotch's `frame-124-hover-tooltip.png` directly.
@MainActor
enum NotchLayout {
    // The notch body
    /// The depth the design frame fixes: a 44pt ring with an even margin
    /// either side of it.
    static var sideBodyDepth: CGFloat { Design.px(186) }

    /// How deep the notch is, which is **not** the same on every edge.
    ///
    /// Turning the stack is more than a rotation. The percent label sits below
    /// its ring, so on a side edge it spends the stack's *length* — the ring
    /// leads the cell and the label follows it down. Turn the stack horizontal
    /// and the label has nowhere to go but into the notch's *depth*, and 70pt
    /// no longer fits a ring, a gap and a line of type. So a horizontal notch
    /// is deeper, and it keeps the frame's margin around the ring to stay
    /// recognisably the same object.
    static func bodyDepth(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? sideBodyDepth : 2 * sideRingMargin + cellExtent
    }

    /// Clear space between the ring and the bezel, from the design frame.
    private static var sideRingMargin: CGFloat { (sideBodyDepth - ringDiameter) / 2 }

    static var curlRadius: CGFloat { Design.px(103) }
    static var cornerRadius: CGFloat { Design.px(78.8) }
    static var padTop: CGFloat { Design.px(69.5) }  // body top -> first ring
    static var padBottom: CGFloat { Design.px(50.1) }  // last label -> body bottom
    static var cellSpacing: CGFloat { Design.px(83.5) }  // label bottom -> next ring top

    // The resting pill. Not in the design frame — it is the notch folded away,
    // sized to read as a deliberate handle rather than a sliver of chrome.
    static var pillWidth: CGFloat { Design.px(26) }
    static var pillHeight: CGFloat { Design.px(210) }
    /// The pill is small, so the region that wakes it is deliberately larger.
    static var pillHotZone: CGFloat { Design.px(90) }

    // A provider cell
    static var ringDiameter: CGFloat { Design.px(117) }  // 44pt, the design spec's anchor
    static var trackStroke: CGFloat { Design.px(15.5) }
    static var progressStroke: CGFloat { Design.px(8) }
    static var glyphSize: CGFloat { Design.px(46) }
    static var ringLabelGap: CGFloat { Design.px(26.9) }

    // The settings orb: it lives *below* the notch, not inside it. At rest only
    // an arc of its edge is drawn, tucked into the corner the bottom flare
    // makes; on hover the same circle fills in and takes a gear. One circle,
    // two states — which is why the arc has to be a segment of it rather than a
    // decorative stroke that happens to sit nearby.
    //
    // The important find: the resting arc is **concentric with the notch's own
    // bottom flare**, one radius inside it. That is what makes it follow the
    // contour of the edge instead of merely sitting near it, and it is why the
    // orb is centred on the flare's centre rather than on the body's axis.
    static var orbDiameter: CGFloat { Design.px(124) }
    static var orbStroke: CGFloat { Design.px(18) }
    /// Distance from the flare's curve in to the resting arc.
    static var orbGap: CGFloat { Design.px(27) }
    /// Radius of the resting arc: the flare's radius, less the gap.
    static var orbArcRadius: CGFloat { curlRadius - orbGap }
    static var orbGlyph: CGFloat { Design.px(56) }
    /// What the arc scales to as it hides.
    ///
    /// The arc is concentric with the bottom flare, `orbGap` inside it, so
    /// growing its radius carries it outward along the normal and *into* the
    /// notch's black. Landing exactly on the flare is not enough — sitting on
    /// the boundary it is still half visible. It goes a full stroke past, so
    /// the line is genuinely buried and stops being drawable rather than
    /// merely becoming faint.
    static var orbMergeScale: CGFloat { (curlRadius + orbStroke) / orbArcRadius }
    /// Generous, like the pill's — it is a small target on a screen edge.
    static var orbHotZone: CGFloat { Design.px(152) }

    /// Clear space between the notch's inner face and the hover card.
    static var cardGap: CGFloat { Design.px(28) }

    /// The percent label's line box. Fixed rather than intrinsic so the panel
    /// geometry can be worked out in AppKit before SwiftUI lays anything out.
    ///
    /// Memoised on the one input it has. Every hit region derives from `cellExtent`, so the pointer
    /// tracker reached this several times per provider per mouse-moved event — each read building an
    /// `NSFont` and querying its metrics.
    static var percentLineHeight: CGFloat {
        if let cached = lineHeightCache, cached.multiplier == Design.multiplier { return cached.height }
        let font = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 27), weight: .semibold)
        let height = ceil(font.ascender - font.descender + font.leading)
        lineHeightCache = (Design.multiplier, height)
        return height
    }

    private static var lineHeightCache: (multiplier: CGFloat, height: CGFloat)?

    /// Ring plus its percent label.
    static var cellExtent: CGFloat { ringDiameter + ringLabelGap + percentLineHeight }

    /// What one cell claims along the stack.
    ///
    /// Down a side edge, the ring *and the label underneath it*: both are on
    /// this axis. Across a horizontal one the label has moved into the depth,
    /// so the cell is the ring alone.
    static func cellAlong(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? cellExtent : ringDiameter
    }

    /// Ring centre to ring centre.
    static func cellPitch(for edge: NotchEdge) -> CGFloat {
        cellAlong(for: edge) + cellSpacing
    }

    /// Padding at the start and the end of the stack.
    ///
    /// Down a side edge these are the frame's own two numbers, and they stay
    /// different: `padTop` measures the body's top to the first *ring*,
    /// `padBottom` measures the last *label* to the body's foot. They pad
    /// different things, so they are not the same size.
    ///
    /// Across a horizontal edge the label has moved off this axis and both ends
    /// are padding the same thing — a cell — so the two become one number,
    /// their mean, which leaves the bar exactly as long as it would have been.
    static func padStart(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? padTop : (padTop + padBottom) / 2
    }

    static func padEnd(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? padBottom : (padTop + padBottom) / 2
    }

    /// Distance from the start of the whole shape to cell `index`'s ring centre.
    static func ringCenter(index: Int, edge: NotchEdge = .right) -> CGFloat {
        curlRadius + padStart(for: edge) + ringDiameter / 2 + CGFloat(index) * cellPitch(for: edge)
    }

    /// Height of the notch body for a given number of provider cells.
    static func bodyLength(cellCount: Int, edge: NotchEdge = .right) -> CGFloat {
        let start = padStart(for: edge)
        let end = padEnd(for: edge)
        guard cellCount > 0 else { return start + end }
        return start + CGFloat(cellCount) * cellAlong(for: edge)
            + CGFloat(cellCount - 1) * cellSpacing + end
    }

    /// Distance in from the screen edge, matching the flare's centre.
    static var orbInsetFromEdge: CGFloat { curlRadius }

    /// Full shape length, flares included.
    static func shapeLength(cellCount: Int, edge: NotchEdge = .right) -> CGFloat {
        bodyLength(cellCount: cellCount, edge: edge) + 2 * curlRadius
    }

    /// Room at each end of the stack: enough for the settings orb to hang past
    /// the foot of the shape, and enough for a card anchored to the first or
    /// last cell to still have somewhere to sit.
    ///
    /// Both orientations need half a card past each end, and for the same
    /// reason: the card is centred on the cell it belongs to, so hovering the
    /// first or last provider throws half of it past the stack. Which dimension
    /// crosses the ends is what differs: the card's height along a vertical
    /// edge, its width along a horizontal one. `cardSize` already carries the
    /// shadow ring, which is the visual margin, so nothing is added on top.
    static func slack(for edge: NotchEdge, cardSize: CGSize) -> CGFloat {
        edge.isVertical ? max(endSlack, cardSize.height / 2) : max(endSlack, cardSize.width / 2)
    }

    private static var endSlack: CGFloat { Design.px(190) }

    /// How far the panel reaches inward from the bezel, past the notch itself,
    /// so the card has somewhere to live. Beside the stack on a side edge,
    /// below or above it on a horizontal one.
    static func cardDepth(for edge: NotchEdge, cardSize: CGSize) -> CGFloat {
        (edge.isVertical ? cardSize.width : cardSize.height) + cardGap
    }
}
