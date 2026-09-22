import AppKit
import CoreImage

/// The macOS 27 capsule's tuning table: the glass filter's inputs, and the
/// clock every part of the entry and the exit runs on. Each value is fitted
/// against the system capsule, frame by frame at 60 fps on the same screen,
/// and the measurement behind it is in the comment. OSDBannerPanel reads them.
@available(macOS 26.0, *)
extension OSDBannerService {
    /// The exit travels less than the entry: the capsule opens far and closes
    /// a little.
    static let glassExitInset = CGSize(width: 18, height: 4)
    /// macOS 27 eases its glass in and out instead of fading a finished one.
    /// The grow, the blur, the bend, the tint and the label each come in on
    /// their own clock below, all of them on the clock from the key press and
    /// not from the first visible frame: the system draws nothing at all for
    /// 120 ms and then runs 0.24, 0.45, 0.55, 0.70, 0.77 and 0.85 of its
    /// settled contrast at 160, 200, 240, 280, 320 and 360 ms. On the way out
    /// the blur closes in about 180 ms and the tone and label in about 280,
    /// while the window takes the rest.
    ///
    /// The window's own fade is all but nothing: it is the carrier, and the
    /// face tint over glassInDuration is what brings the capsule in. A window
    /// still at low alpha lets the sharp desktop through whatever the filter
    /// does, and the system's first frame already blurs and bends what is
    /// behind it.
    static let glassWindowInDuration: TimeInterval = 0.02
    static let glassInDuration: TimeInterval = 0.62
    /// A gentle toe, then the body of the move, then a long settle, which is
    /// the shape the system's own tone follows over a light backdrop.
    static let glassInCurve = CAMediaTimingFunction(controlPoints: 0.3, 0.12, 0.3, 1)
    /// The content fades over the whole travel, as the system's does. Measure
    /// it over a dark backdrop: over a light one the track's white against a
    /// bright body hides the ramp.
    static let glassContentInDuration: TimeInterval = 0.72
    /// Slow at both ends, not an ease out. Measured over a dark backdrop, both
    /// capsules in one burst, as the label's brightest pixel against its
    /// settled one: the system runs 0.06, 0.12, 0.27, 0.59, 0.85, 0.93 and
    /// 0.96 at 0, 60, 120, 200, 300, 400 and 500 ms.
    static let glassContentInCurve = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.3, 1)
    /// The grow, fitted to the system capsule's own width: it opens 30 pt
    /// narrower and 7 pt shorter than it ends, and is within a point of its
    /// full width at 420 ms (27 percent of the way at 53 ms, 47 at 103, 67 at
    /// 157, 80 at 209, 93 at 313), while its blur, bend and label keep
    /// settling inside it until about 800.
    static let glassGrowInDuration: TimeInterval = 0.48
    /// An ease out: the capsule leaves at full speed and decelerates the whole
    /// way, so it arrives and settles.
    static let glassGrowInCurve = CAMediaTimingFunction(controlPoints: 0, 0.55, 0.25, 1)
    /// The rim comes up behind the body, not with it. Measured on one capture
    /// with both capsules over the same backdrop, as the rim's lift over the
    /// body divided by the body's own progress: the system's border line is at
    /// 0.32 of its share when the body is halfway there, then 0.53, 0.88, 0.94
    /// and 1.00 at 100, 150, 200 and 250 ms.
    static let glassRimInDuration: TimeInterval = 0.55
    static let glassRimInCurve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    static let glassRimStart = 0.0
    /// The bright line along the top edge is drawn twice: OSDBevelView's rim
    /// over the glass, and the glass's own key fill highlight under it. Both
    /// ride the ramp above, or half the line is up from the first frame, where
    /// the system's rim carries 0.14 of the body's progress at 100 ms.
    static let glassHighlight = (open: 0.4, closed: 0.0)
    /// The settle ends where the system's does: frame against frame, the
    /// system capsule stops changing between 650 and 700 ms after the press.
    static let glassSettleInDuration: TimeInterval = 0.7
    static let glassSettleInCurve = CAMediaTimingFunction(controlPoints: 0.25, 0.2, 0.45, 1)
    static let glassBlurInCurve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.5, 1)
    /// The exit takes the same steps back, faster at the start and with a long
    /// tail: the system capsule has 72 percent of its way left at 50 ms, 16 at
    /// 250 and the last few at 450, and its window stays opaque until then and
    /// is gone at 500.
    static let glassOutDuration: TimeInterval = 0.5
    /// The parts go at their own pace inside that. The system is down to 60
    /// percent of its contrast 130 ms into the exit, and its decay from there
    /// is close to a straight line into a long faint tail.
    static let glassBlurOutDuration: TimeInterval = 0.3
    static let glassTintOutDuration: TimeInterval = 0.35
    static let glassBendOutDuration: TimeInterval = 0.35
    static let glassRimOutDuration: TimeInterval = 0.35
    static let glassOutCurve = CAMediaTimingFunction(controlPoints: 0.15, 0.25, 0.3, 1)
    static let glassWindowOutDuration: TimeInterval = 0.5
    static let glassWindowOutCurve = CAMediaTimingFunction(controlPoints: 0.35, 0.25, 0.45, 1)
    /// macOS 27's capsule is the system's own glass: one filter that blurs,
    /// tints and bends the backdrop together, which is what reads as tinted
    /// glass. A blur with a grey laid over it reads as a solid behind glass
    /// however well its numbers match on a flat backdrop. The dark variant is
    /// the closest of them; its inputs are fitted against the system HUD over
    /// a striped and lettered backdrop, the tint to within 2 levels of the
    /// HUD's mean in each channel and the bend at both ends, where the HUD
    /// wraps the colours outside it into a thin ring. The blur goes in steps
    /// and above about 1.25 it draws the next one up. The HUD also pulls the
    /// text outside its top and bottom edges well into the body, which a
    /// refraction height of 14 draws and 12 does not.
    static let glassVariant = 2
    nonisolated static let glassBackdropScale = 1.0
    /// The blur comes in two steps, fitted over the same stripes: the text
    /// behind the system capsule keeps its edges for the first 145 ms and
    /// loses them over the next 240, which is what the delay and the length of
    /// the second step carry. A radius under 0.6 draws as none at all.
    static let glassBlurStep = 0.3
    static let glassBlurStepDuration: TimeInterval = 0.06
    static let glassBlurRiseDelay: TimeInterval = 0.18
    static let glassBlurRiseDuration: TimeInterval = 0.45
    nonisolated static let glassInputs: [String: Double] = [
        "inputRefractionOpacity": 1,
        // The first of the blur group's four opacities, which the view leaves
        // at 1. At 0.8 it lets a little of the sharp backdrop back through the
        // blur, as the system HUD does. The other three stay as the view sets
        // them.
        "inputBlurOpacity0": 0.8,
        "inputInnerRefractionHeight": 14,
        // White and black are the tone of the body, fitted on the plain part
        // of the capsule over the stripes: the system's reads mean 65.1 with a
        // spread of 20.8, and these two land on 64.8 and 21.0. The black point
        // carries the tone, and 0.095 leaves the body four levels bright.
        "inputFaceColorMatrixWhite": 0.79,
        "inputFaceColorMatrixBlack": 0.073,
        "inputFaceColorMatrixSaturation": 1.4
    ]
    /// The settled radius is one of two levels the radius can take here: 1.1
    /// and 1.25 draw the same thing and 1.3 draws the next level, with the
    /// system's capsule between them. At this level the text behind the band
    /// keeps a little more of its structure than the system's (the middle half
    /// of the band spans 49 to 68 levels against its 54 to 61); at the next
    /// level the band is three levels brighter and flatter.
    ///
    /// Open and closed are the same, because the lens is full from the first
    /// frame and closed is only where the exit ends. Closed is not zero
    /// either: a radius of 0 draws as a wide blur in the window server, and
    /// anything under 0.6 draws as none.
    static let glassBlur = (open: 0.95, closed: 0.95)
    /// The glass comes in flat and bends over the first 180 ms, where the
    /// shimmer takes over. The amount comes up with the band's depth below and
    /// not before it: a deep band at full bend is a soft shadow and a shallow
    /// one a hard dark line.
    static let glassBend = (open: -75.0, closed: 0.0)
    /// The bend ends where the shimmer begins: the bend is the capsule coming
    /// towards the eye and the shimmer is what the backdrop does once it is
    /// there, so the two hand over instead of overlapping. It is done well
    /// before the settle, since the system's edge reaches its full brightness
    /// by 350 ms and cannot until the bend behind it is full.
    static var glassBendInDuration: TimeInterval { glassRefractionHeightDuration }
    /// Off the mark at once and a long tail: the band is on its way in the
    /// first frames and the last of it takes its time.
    static let glassBendInCurve = CAMediaTimingFunction(controlPoints: 0.05, 0.5, 0.3, 1)
    /// The band the bend pulls in over the top and bottom edges. It opens at
    /// nothing and grows down from the top edge, which is the movement in the
    /// entry. The height it settles at also sets how bright the body under the
    /// band reads: on the row five to nine under the top edge the system reads
    /// 65.5, where 14 gives 64.1, 15 gives 57.7 and 17 gives 50.6, each of the
    /// higher ones darker and with the band's own arc thinner and brighter.
    static let glassRefractionHeight = (open: 15.0, closed: 0.0)
    /// Short, because a shallow band draws a harder line than a deep one and a
    /// slow ramp holds that line on screen. The system reaches its own 10
    /// levels under the body by 120 ms and holds it (6.2, 8.0, 12.0 and 10.6
    /// at 0, 60, 120 and 200 ms, both capsules in one burst).
    static let glassRefractionHeightDuration: TimeInterval = 0.44
    /// The face the entry ramps up to. Closed is nothing: the face brings the
    /// entry in, not the window.
    static let glassTint = (open: 0.88, closed: 0.0)
    /// The shimmer: once the grow, the bend and the blur are done, the glass
    /// dips its backdrop sampling from 1.0 to this and back, which makes what
    /// is behind the glass drift for a moment and then come to rest.
    ///
    /// How deep the dip goes: under about 0.4 the backdrop switches to another
    /// sampling level and part of the change arrives in one frame, which over
    /// a light window moves the biggest frame's pixels by 25 levels at 0.45
    /// and by 62 at 0.3.
    static let glassShimmerScale = 0.45
    static let glassShimmerDelay: TimeInterval = 0.20
    static let glassShimmerDuration: TimeInterval = 0.30
    /// And back to sharp, which is how the capsule settles. The system's
    /// settled capsule resolves small text behind it, down to the digits in a
    /// window of figures under its top band.
    static let glassShimmerReturnDelay: TimeInterval = 0.50
    static let glassShimmerReturnDuration: TimeInterval = 0.20
}
