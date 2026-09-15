import SwiftUI

/// The settings control, below the notch.
///
/// At rest it is a single arc — a segment of a circle's edge, tucked into the
/// corner the notch's bottom flare makes. On hover that same circle fills in and
/// takes a gear. The two states are the same circle, which is what makes the
/// change read as one object waking up rather than as one thing being swapped
/// for another.
///
/// It is a bare arc at rest because the notch is meant to be glanceable: a
/// permanently visible gear is a second thing competing with the readings, and
/// the readings are the point. An arc says "there is something here" without
/// asserting anything.
struct SettingsOrb: View {
    let isHovered: Bool
    var edge: NotchEdge = .right
    /// The Size setting this orb is drawn at — see `Design.multiplier`.
    let scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which quarter of the circle the resting arc occupies.
    ///
    /// The arc has to parallel the flare at the far end of the notch, so it
    /// faces two ways at once: **back along the stack**, toward the notch it
    /// hangs off, and **outward**, toward the bezel it is about to merge into.
    ///
    /// SwiftUI's `Circle` trim starts at three o'clock and runs clockwise, with
    /// y growing downward.
    static func restingTrim(for edge: NotchEdge) -> ClosedRange<CGFloat> {
        switch edge {
        case .right: return 0.75...1.0  // up, round to the right
        case .left: return 0.5...0.75  // left, round to up
        case .top: return 0.5...0.75  // left, round to up
        case .bottom: return 0.25...0.5  // down, round to the left
        }
    }

    private var restingTrim: ClosedRange<CGFloat> { Self.restingTrim(for: edge) }
    private var arcRadius: CGFloat { NotchLayout.orbArcRadius }

    var body: some View {
        ZStack {
            // The resting arc, on a circle one gap inside the flare's own.
            // The arc takes the glass's tint rather than real vibrancy: it is a 7pt line, and a
            // stroked mask that thin resolves to a smear of the desktop rather than to a material.
            // The disc below it is big enough to be worth the real thing, and it is what the eye
            // reads as the object.
            Circle()
                .trim(from: restingTrim.lowerBound, to: restingTrim.upperBound)
                .stroke(
                    Glass.tint,
                    style: StrokeStyle(lineWidth: NotchLayout.orbStroke, lineCap: .round)
                )
                .frame(width: arcRadius * 2, height: arcRadius * 2)
                .opacity(isHovered ? 0 : 1)
                .scaleEffect(isHovered ? 0.86 : 1)

            Color.clear
                .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
                .notchGlass(Circle())
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 1.1)

            Image(systemName: "gearshape")
                .font(.system(size: NotchLayout.orbGlyph, weight: .regular))
                .foregroundStyle(Color.csTitle)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)
                .rotationEffect(.degrees(isHovered ? 0 : -60))
        }
        // Sized to the larger of the two states, stroke included.
        .frame(
            width: arcRadius * 2 + NotchLayout.orbStroke,
            height: arcRadius * 2 + NotchLayout.orbStroke
        )
        .animation(NotchMotion.respectingReduceMotion(NotchMotion.orbHover, reduceMotion), value: isHovered)
    }
}
