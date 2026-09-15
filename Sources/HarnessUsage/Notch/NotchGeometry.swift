import AppKit

/// Everything the geometry maths needs from a screen, so it can be faked in tests.
protocol ScreenDescribing {
    var frameValue: CGRect { get }
    var visibleFrameValue: CGRect { get }
}

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }
    var visibleFrameValue: CGRect { visibleFrame }
}

enum NotchGeometry {
    /// The panel hugs the chosen edge and is centred along it.
    ///
    /// **Which edge it hugs is `visibleFrame`'s, not `frame`'s.** That is what
    /// keeps a bottom notch resting on top of the Dock and a top one below the
    /// menu bar rather than behind them, and it is why the notch moves when the
    /// Dock hides — `visibleFrame` gives the space back and the notch takes it.
    ///
    /// **Centring, though, stays on `frame`.** A Dock at the bottom is nowhere
    /// near a right-edge notch, and centring on the visible area would shift
    /// that notch up and down the screen every time the Dock hid itself, for no
    /// reason anyone could see.
    ///
    /// The rect is rounded out to whole points on purpose. AppKit rounds window
    /// frames anyway, and if it does the rounding the panel ends up a fraction
    /// larger than asked for — which leaves the content, laid out at its exact
    /// size, stopping short of the screen edge. A hairline of wallpaper along
    /// that edge is all it takes for the notch to read as floating rather than
    /// welded to the bezel.
    static func panelFrame(
        for screen: ScreenDescribing, panelSize: CGSize, edge: NotchEdge = .right
    ) -> CGRect {
        let full = screen.frameValue
        let usable = screen.visibleFrameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)

        let origin: CGPoint
        switch edge {
        case .right:
            origin = CGPoint(x: usable.maxX - width, y: full.midY - height / 2)
        case .left:
            origin = CGPoint(x: usable.minX, y: full.midY - height / 2)
        case .top:
            // AppKit's y grows upward, so the top edge is `maxY` — `visibleFrame`'s, which puts the
            // notch below the menu bar rather than behind it.
            origin = CGPoint(x: full.midX - width / 2, y: usable.maxY - height)
        case .bottom:
            origin = CGPoint(x: full.midX - width / 2, y: usable.minY)
        }

        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height)
    }

    /// The notch follows the screen with the menu bar, which is `screens.first`.
    ///
    /// Explicitly NOT `NSScreen.main`: that is the screen of the KEY window, and this app has no key
    /// window — so it followed whichever display the user's frontmost app was on, and the 0.3s poll's
    /// `visibleFrame` comparison then relocated the panel on every focus change between displays.
    static func preferredScreen(from screens: [NSScreen]) -> NSScreen? {
        screens.first
    }
}
