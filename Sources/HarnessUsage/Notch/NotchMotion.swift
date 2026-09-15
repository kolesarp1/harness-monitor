import SwiftUI

/// The motion vocabulary, in one place so the whole surface moves like one thing.
///
/// Springs rather than eased curves throughout: macOS motion reads as physical
/// because things overshoot slightly and settle, and a panel that scales without
/// any of that feels like a slideshow. The numbers are chosen to be *just* under
/// bouncy — `dampingFraction` in the high 0.7s gives a single soft settle rather
/// than a wobble.
enum NotchMotion {
    /// Folding open and shut. Long enough to read as a movement, short enough
    /// that it never delays you.
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.78)

    /// Contents arriving after the shape has started opening.
    static let contents = Animation.spring(response: 0.36, dampingFraction: 0.82)

    /// The tooltip travelling between cells. Slower and more damped than the
    /// fold: it is a bigger object moving a longer way, and the same spring that
    /// feels crisp on a 10pt pill feels abrupt on a 226pt card.
    static let glide = Animation.spring(response: 0.5, dampingFraction: 0.86)

    /// A percentage changing under you. Slower on purpose: a ring that snaps to a
    /// new value reads as a glitch, one that sweeps reads as a measurement.
    static let reading = Animation.spring(response: 0.9, dampingFraction: 0.9)

    /// A card leaving because its ring was clicked again, the notch folded, or a click landed
    /// elsewhere. Eased rather than sprung: nothing is arriving, so there is nothing to settle.
    static let dismiss = Animation.easeOut(duration: 0.18)

    /// A card opening on a click. Quicker and tighter than `glide`, which carries a card that is
    /// already on screen from one ring to another — this one has no distance to cover.
    static let cardOpen = Animation.spring(response: 0.18, dampingFraction: 0.85)

    /// The settings orb waking under the pointer: the resting arc giving way to the filled disc and
    /// its gear. Looser than the rest, because a control answering a hover should feel springy.
    static let orbHover = Animation.spring(response: 0.36, dampingFraction: 0.7)

    /// The settings arc being taken back into the notch.
    ///
    /// Quicker than `unfold` and with no delay, which is the whole point: on
    /// the staggered spring the arc lagged the fold, so the notch began closing
    /// first and the arc appeared to leave with the screen edge instead of
    /// being absorbed. It has to be inside the black while there is still black
    /// to be inside. Eased *in* because a thing being drawn into a mass
    /// accelerates as it goes.
    static let merge = Animation.easeIn(duration: 0.2)

    /// One turn of the rings, on "Update now".
    ///
    /// The obvious spelling is a `repeatForever` linear spin started when the refresh begins and
    /// cancelled when it ends — but `repeatForever` does not stop when the value is set back, and the
    /// ring then spins forever after a refresh that finished half a second in. A single finite turn has
    /// no cancellation problem at all: 360° is the same angle as 0°, so it lands exactly where the
    /// reading belongs, and it eases out rather than stopping dead.
    static let refreshSpinSeconds: TimeInterval = 0.95
    static let refreshSpin = Animation.timingCurve(0.32, 0, 0.14, 1, duration: refreshSpinSeconds)

    /// The rings pressing in while the refresh runs, and releasing when the readings land.
    static let refreshPress = Animation.spring(response: 0.3, dampingFraction: 0.62)

    /// Each cell trails the one above it, so the stack unfurls rather than
    /// appearing all at once. Capped so a long list never feels sluggish.
    static func stagger(index: Int) -> Animation {
        contents.delay(min(Double(index) * 0.045, 0.18))
    }

    /// Everything above, unless the system has been asked for less movement.
    static func respectingReduceMotion(_ animation: Animation, _ reduce: Bool) -> Animation? {
        reduce ? nil : animation
    }
}
