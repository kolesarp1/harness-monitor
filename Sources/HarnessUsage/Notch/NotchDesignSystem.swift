import SwiftUI

// The notch's measurements, ported from Codenotch (MIT, vinzdg/codenotch) along with the notch
// surface itself. Only the geometry and the type scale are its own — colour comes from `GlassKit`'s
// `cs*` palette, the same one the card and Settings draw from.

/// Every number in the notch UI is measured off Codenotch's design frame
/// (`frame-124-hover-tooltip.png`, 2000 x 2000 px), so the layout is
/// *proportionally* exact rather than eyeballed.
///
/// The frame fixes only ratios, never an absolute size, so one anchor picks the
/// scale: the provider ring is 44pt across, and it measures 117px in the frame.
/// Change `scale` and the whole surface — notch, rings, type, tooltip — resizes
/// together, still in the design's proportions.
@MainActor
enum Design {
    /// Points per pixel of the design frame at the size it was drawn for: a 44pt ring.
    static let baseScale: CGFloat = 44.0 / 117.0
    /// The Size setting, applied on top of the frame's own scale. Set from Settings before every
    /// render and read by every measurement, so the notch, its rings, type, orb and gaps all resize
    /// together and stay in the frame's proportions.
    ///
    /// A global is not one of a view's inputs, and SwiftUI skips the body of a view whose inputs all
    /// compare equal — so every notch view that measures off `Design` takes the scale it was built
    /// at as a stored property. That is what those `scale` properties are for, unread as they look:
    /// without one, a ring and its glyph go on drawing at the previous size until something *else*
    /// about them changes, which is the next reading, minutes later.
    static var multiplier: CGFloat = 1
    /// Points per pixel of the design frame, as drawn right now.
    static var scale: CGFloat { baseScale * multiplier }

    /// A distance measured in design-frame pixels, in points.
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    /// Cap-height fraction of an em for SF Pro. Text in the frame can only be
    /// measured by its cap height, so this converts back to a point size.
    private static let capRatio: CGFloat = 0.714

    /// The point size whose capital letters are `pixels` tall in the frame.
    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }
}

/// Sizes are derived from cap heights measured in the design frame, so they
/// track `Design.scale` along with everything else.
@MainActor
enum Typography {
    /// The percent under each provider ring. Cap height 27px in the frame.
    static var percent: Font { Font.system(size: Design.fontSize(capPixels: 27), weight: .semibold) }
}
