import AppKit
import HarnessUsageCore
import SwiftUI

// Generic brand rendering. The per-integration brand DATA (SVG string + BrandColor) lives in Core
// descriptors; this file only knows how to turn that data into a SwiftUI view. No per-integration
// branches — the UI is a pure renderer over `integration.descriptor`.

// A brand glyph rendered crisply straight from its vector SVG (no pre-rasterization), tinted via a
// template mask so it stays sharp at any size. `.adaptive` tints are resolved HERE, against the view's
// color scheme — black on light, white on dark — rather than via a dynamic labelColor, which does not
// reliably re-resolve inside these glass windows.
struct BrandMark: View {
    let integration: Integration
    var size: CGFloat = 16
    let tint: BrandColor
    /// Pins the scheme the mark inverts against. A selected sidebar tile is a LIGHT surface inside a
    /// dark window, so its mark must follow the tile, not the window.
    var colorSchemeOverride: ColorScheme? = nil
    @Environment(\.colorScheme) private var scheme

    private var color: Color {
        switch tint {
        case .rgb(let r, let g, let blue): return Color(.sRGB, red: r, green: g, blue: blue)
        case .adaptive: return (colorSchemeOverride ?? scheme) == .dark ? .white : .black
        }
    }

    var body: some View {
        Image(nsImage: NSImage(data: Data(integration.descriptor.brandSVG.utf8)) ?? NSImage())
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}
