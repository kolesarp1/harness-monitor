import HarnessUsageCore
import SwiftUI

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
struct ProviderRing: View {
    let integration: Integration
    /// Nil when the provider has reported nothing yet — there is no arc to
    /// draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    /// The severity the arc takes, from the same `UsageStyle` the card's meters colour themselves by.
    let level: UsageLevel
    /// The limit is spent and the ring is only waiting for its reset.
    let isSpent: Bool
    /// The Size setting this ring is drawn at — see `Design.multiplier`.
    let scale: CGFloat
    /// An "Update now" is in flight.
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0

    private var sweep: CGFloat { CGFloat(min(max(usedFraction ?? 0, 0), 1)) }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.csRingTrack, lineWidth: NotchLayout.trackStroke)

            if usedFraction != nil {
                Circle()
                    .inset(by: NotchLayout.trackStroke / 2)
                    .trim(from: 0, to: sweep)
                    .stroke(
                        UsageStyle.color(level),
                        style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                    )
                    // A refresh turns the reading itself rather than overlaying a separate spinner:
                    // the thing being refetched is the thing that should move, and a second arc on
                    // the same track would only compete with it.
                    .rotationEffect(.degrees(-90 + spin))
                    // A ring that snaps to a new value reads as a glitch; one
                    // that sweeps reads as a measurement being taken.
                    .animation(NotchMotion.reading, value: sweep)
                    .animation(NotchMotion.reading, value: level)
            }

            BrandMark(integration: integration, size: NotchLayout.glyphSize, tint: .adaptive)
                // A spent limit dims its glyph so the ring reads as "waiting".
                .opacity(isSpent ? 0.35 : 1)
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        // Pressed in while it works, released when the answer lands. The ring is what was asked for,
        // so the ring is what should feel pressed.
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(NotchMotion.respectingReduceMotion(NotchMotion.refreshPress, reduceMotion), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Exactly one turn, and it stops by itself — see `NotchMotion.refreshSpin`.
            withAnimation(NotchMotion.refreshSpin) { spin += 360 }
        }
    }
}

/// A ring and the percent burned underneath it.
struct ProviderCell: View {
    let provider: NotchProvider
    /// The Size setting this cell is drawn at — see `Design.multiplier`.
    let scale: CGFloat
    /// An "Update now" is in flight.
    let isRefreshing: Bool

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                integration: provider.integration, usedFraction: provider.ringFraction,
                level: provider.ringLevel, isSpent: provider.isSpent, scale: scale,
                isRefreshing: isRefreshing)
            Text(provider.headlineText)
                .font(Typography.percent)
                .foregroundStyle(Color.csTitle)
                // Never squeezed: across a horizontal edge the cell is only as
                // wide as the ring, and a label wider than that would be
                // truncated rather than allowed to overhang into the spacing
                // that is already there for it.
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: NotchLayout.percentLineHeight)
                .contentTransition(.numericText())
                .animation(NotchMotion.reading, value: provider.headlineText)
        }
        .frame(height: NotchLayout.cellExtent)
    }
}
