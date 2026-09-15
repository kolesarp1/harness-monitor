import AppKit
import HarnessUsageCore
import SwiftUI

// The hover card: `UsageSection`, in whichever layout Settings selects (Spotlight, Minimal, Linear,
// Dot-matrix), on the app's one glass. The notch supplies only the anchor — which provider, and where
// the card sits.
struct NotchUsageCard: View {
    let usage: UsageStore
    let settings: SettingsStore
    let selection: ProviderSelection
    /// The Size setting the tail and its shape are drawn at — see `Design.multiplier`.
    let scale: CGFloat
    let accounts: [Integration]

    var body: some View {
        UsageSection(usage: usage, settings: settings, selection: selection, accounts: accounts)
            .frame(width: NotchCardMetrics.cardWidth)
            // The tail sits beside the content, not over it: the body keeps its full width and the
            // silhouette grows by the tail's length toward the notch.
            .padding(.trailing, NotchCardMetrics.tailLength)
            // No shadow: `.shadow` has to rasterize the subtree to derive it, which a behind-window
            // vibrancy view cannot survive — it came out as a grey veil over the card's own contents.
            .notchGlass(NotchCardMetrics.shape)
            .clipShape(NotchCardMetrics.shape)
            .padding(NotchCardMetrics.margin)
            // A layout change alters the ideal height, and an auto-sizing host reports the
            // interpolated size every frame when that happens under an animated transaction, which
            // slides the card. Nil the animation at the root so the resize is a single jump.
            .animation(nil, value: settings.settings.usageLayout)
    }
}

// How much room a card needs, measured rather than budgeted.
//
// The black tooltip this replaced could compute its own height from a table of type metrics, because
// it drew a known number of fixed rows. `UsageSection` cannot: its height depends on the layout, on
// how many windows the provider reports and on whether the token strip is showing. So the card is
// laid out off screen once and asked how tall it came out, and that figure is what the panel reserves
// and what the hover region uses — one number, so what is drawn and what is reachable cannot drift.
@MainActor
enum NotchCardMetrics {
    /// Width of the visible card — the width every `UsageSection` layout was drawn and tuned against.
    static let cardWidth: CGFloat = 360
    /// Clear ring around the card, so the hover region has a little tolerance at its edges and the
    /// glass never butts straight up against the measured bound.
    static let margin: CGFloat = 8
    /// The tail that points at the ring, from Codenotch's design frame; it scales with the notch.
    static var tailLength: CGFloat { Design.px(75) }
    static var tailHeight: CGFloat { Design.px(87) }
    /// Body, tail, and the clear ring either side.
    static var totalWidth: CGFloat { cardWidth + tailLength + 2 * margin }
    /// The floor a card's height is measured against, so a provider reporting nothing still gets a
    /// card with proportions rather than a sliver. One definition, because the panel reserves this
    /// room and the measurement clamps to it — two copies could disagree by a scale change.
    static var minHeight: CGFloat { totalWidth / 2 }
    /// The card's corner, from the same frame (49.5px, so 18.6pt at full size). Bigger than the
    /// Settings window's 15 and, unlike it, it scales: this corner runs into the tail, and a fixed
    /// one would tighten against a growing tail at every Size above 100%.
    static var cardCorner: CGFloat { Design.px(49.5) }
    /// What makes the tail read as a beak rather than a spike, both taken off the frame: the point
    /// carries a small round, and the tail leaves the card's edge as a curve instead of a crease.
    static var tailTipRadius: CGFloat { Design.px(9) }
    static var tailBaseFillet: CGFloat { Design.px(34) }
    static var shape: CardTailShape {
        CardTailShape(
            radius: cardCorner, tailLength: tailLength, tailHeight: tailHeight,
            tipRadius: tailTipRadius, baseFillet: tailBaseFillet)
    }

    /// The card's full height for one provider, shadow ring included.
    ///
    /// Measuring costs a SwiftUI layout pass, so the answer is kept until one of the things it
    /// depends on actually changes. Without the cache this runs once per provider on every engine
    /// tick; with it, only when a reading, a setting or the notch's size moves.
    static func height(
        for integration: Integration, usage: UsageStore, settings: SettingsStore,
        accounts: [Integration]
    ) -> CGFloat {
        let key = Key(
            snapshot: usage[integration], config: settings.settings.provider(for: integration),
            layout: settings.settings.usageLayout, multiplier: Design.multiplier)
        if let cached = cache[integration], cached.key == key { return cached.height }

        let selection = ProviderSelection()
        selection.integration = integration
        let host = NSHostingView(
            rootView: NotchUsageCard(
                usage: usage, settings: settings, selection: selection, scale: Design.multiplier,
                accounts: accounts))
        host.frame = CGRect(x: 0, y: 0, width: totalWidth, height: 0)
        host.layoutSubtreeIfNeeded()
        let height = max(host.fittingSize.height, minHeight)
        cache[integration] = (key, height)
        return height
    }

    /// `multiplier` is in here because `totalWidth` — the width the card is measured at — is scaled by
    /// it. Without it the Size slider left every provider's height frozen at the previous scale's
    /// measurement, and the panel reserved room for a card that is no longer that size.
    private struct Key: Equatable {
        let snapshot: UsageSnapshot?
        let config: ProviderConfig
        let layout: UsageLayout
        let multiplier: CGFloat
    }

    private static var cache: [Integration: (key: Key, height: CGFloat)] = [:]
}

/// The card's silhouette: a rounded rectangle with a tail on its trailing edge, its tip pointing at
/// the ring the card belongs to. Drawn as one closed outline rather than a rectangle plus a triangle,
/// so the rim runs round the tail instead of stroking the body's edge across its base.
///
/// The tail is the design frame's own 75 x 87 box, and — as the frame draws it and Codenotch's
/// straight-line port does not — it is rounded where it meets both the card and the ring: a spike
/// grown out of a crease reads as a graphic pasted on the card, a beak reads as the card reaching.
struct CardTailShape: Shape {
    var radius: CGFloat
    var tailLength: CGFloat
    var tailHeight: CGFloat
    /// The point's own round, and the blend where the tail leaves the card's edge. Zero for either
    /// draws that join as the bare corner it is.
    var tipRadius: CGFloat = 0
    var baseFillet: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailLength, height: rect.height)
        let r = max(0, min(radius, body.width / 2, body.height / 2))
        let half = max(0, min(tailHeight / 2, body.height / 2 - r))
        // Both roundings are cut out of the tail itself, so a tail the card has squeezed carries
        // smaller ones rather than blends that overrun the edges they are supposed to join.
        let tip = max(0, min(tipRadius, tailLength / 3))
        let fillet = max(0, min(baseFillet, half))
        let midY = rect.midY
        let baseTop = CGPoint(x: body.maxX, y: midY - half)
        let baseBottom = CGPoint(x: body.maxX, y: midY + half)
        let point = CGPoint(x: rect.maxX, y: midY)

        // Every corner as an arc tangent to the two lines that meet at it — the tail's blends are
        // rounds of a 120° and a 60° corner, and their centres lie nowhere the outline passes, so
        // there is no centre to hand a `startAngle`/`endAngle` arc. A zero radius degenerates to the
        // corner point itself, which is how `tipRadius: 0` still draws a straight triangle.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: baseTop, radius: r)
        p.addArc(tangent1End: baseTop, tangent2End: point, radius: fillet)
        p.addArc(tangent1End: point, tangent2End: baseBottom, radius: tip)
        p.addArc(tangent1End: baseBottom, tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: fillet)
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
        p.closeSubpath()
        return Path(p)
    }
}
