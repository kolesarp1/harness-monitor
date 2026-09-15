import HarnessUsageCore
import SwiftUI

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
/// A stale ring (concept E: no current source works) draws a dashed track, the last reading's arc
/// in grey — a severity colour on an old number would claim more than the app knows — and a dimmed
/// glyph.
struct ProviderRing: View {
    let integration: Integration
    /// Nil when the provider has reported nothing yet — there is no arc to
    /// draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    /// The severity the arc takes, from the same `UsageStyle` the card's meters colour themselves by.
    let level: UsageLevel
    /// The limit is spent and the ring is only waiting for its reset.
    let isSpent: Bool
    /// No current source works: dashed track, grey arc, dim glyph.
    let isStale: Bool
    /// The letter telling this login apart from another of the same harness. Nil with only one.
    let accountLetter: String?
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
                .strokeBorder(
                    Color.csRingTrack,
                    style: StrokeStyle(lineWidth: NotchLayout.trackStroke, dash: isStale ? [4, 3] : []))

            if usedFraction != nil {
                Circle()
                    .inset(by: NotchLayout.trackStroke / 2)
                    .trim(from: 0, to: sweep)
                    .stroke(
                        isStale ? Color.csFaint : UsageStyle.color(level),
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
                // A spent limit dims its glyph so the ring reads as "waiting"; a stale reading dims
                // further, because even the shape of the number is old.
                .opacity(isStale ? 0.45 : (isSpent ? 0.35 : 1))
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        .overlay(alignment: .bottomTrailing) {
            if let accountLetter {
                AccountChip(letter: accountLetter, scale: scale)
                    .offset(x: NotchLayout.accountChipOverhang, y: NotchLayout.accountChipOverhang)
            }
        }
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

/// The letter on a ring's lower-right edge, on the same light tile Settings selects a pane with. A dark
/// halo cuts it out of the arc, so the arc reads as passing behind the chip rather than running into it.
private struct AccountChip: View {
    let letter: String
    /// The Size setting this chip is drawn at — see `Design.multiplier`.
    let scale: CGFloat

    var body: some View {
        let side = NotchLayout.accountChipSize
        let halo = NotchLayout.accountChipHalo
        Text(letter)
            .font(.system(size: Design.fontSize(capPixels: 20), weight: .bold))
            .foregroundStyle(Color.csOnAccent)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.3, style: .continuous).fill(Color.csAccent))
            .padding(halo)
            .background(RoundedRectangle(cornerRadius: side * 0.3 + halo, style: .continuous).fill(Color.black.opacity(0.6)))
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
                level: provider.ringLevel, isSpent: provider.isSpent, isStale: provider.isStale,
                accountLetter: provider.accountLetter, scale: scale, isRefreshing: isRefreshing)
            Text(provider.headlineText)
                .font(Typography.percent)
                // A stale number prints dim: it is the last reading, not a measurement.
                .foregroundStyle(provider.isStale ? Color.csFaint : Color.csTitle)
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
