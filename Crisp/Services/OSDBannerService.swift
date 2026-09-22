import AppKit
import SwiftUI
import CoreImage

/// Draws Crisp's own on-screen display on macOS 26, in the style of the
/// system's brightness and volume capsule under the menu bar. OSDUIHelper,
/// which BrightnessHUDService still calls on macOS 14 and 15, draws the
/// pre-Tahoe bottom-centre bezel on 26, and the system's own capsule
/// (Control Center's SystemBanner) has no third-party entry point (#76).
///
/// One panel per screen, created on first use and never ordered out: a
/// surface that samples what is behind it replays its materialize bloom when
/// it comes back on screen (see the menu panel notes in AppDelegate), so
/// hidden means alpha 0. Screens that vanish get their panel closed on the
/// next show.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerService {
    static let shared = OSDBannerService()
    private init() {}

    /// Measured from the native capsule on 26.5.1, at rest: 10 pt in from
    /// the right screen edge, 10 pt below the menu bar, corner radius 20 with
    /// a continuous curve. The 292 x 64 size lives on the view. Read off the
    /// lit columns of both capsules over a banded backdrop: the HUD's run
    /// ends one pixel further right than this one's did at inset 11, and both
    /// runs are the same 292 wide.
    ///
    /// Measure the native capsule at rest, a second after the key press: it
    /// settles down from above over the first half second, and a frame caught
    /// during that settle reads 2 pt narrower, 1 pt shorter and rounder than
    /// the capsule the eye actually sees.
    /// How far the capsule stays from the side edge: the system's HUD on
    /// macOS 27 sits 17 pt in, measured on the same screen with both capsules
    /// up. Older releases keep the 10 the bezel was measured at.
    static var trailingInset: CGFloat { drawsMacOS27Capsule ? 17 : 10 }
    static let topInset: CGFloat = 10
    static let cornerRadius: CGFloat = 20
    /// The capsule's tone, as one grey over the backdrop. The system HUD reads
    /// 0.657 x backdrop + 31 on a flat backdrop, so the grey is mixed to draw
    /// the same line: alpha 0.343 leaves that slope, and white 0.355 under it
    /// puts the offset at 31. Measured back over a black, a mid grey and a
    /// light backdrop the banner lands on 31, 129 and 184, the HUD's own
    /// three. The same line is applied inside the backdrop's own filters (see
    /// makeToneFilters); this layer is what draws it if that layer is missing.
    /// macOS 27 draws a slightly lighter capsule: measured settled over
    /// backdrops of 0 to 255 its body follows 0.675 x backdrop + 32, where
    /// 26.5.1 followed 0.657 x backdrop + 31.
    static var scrimColor: NSColor {
        drawsMacOS27Capsule ? NSColor(white: 0.386, alpha: 0.325)
                            : NSColor(white: 0.355, alpha: 0.343)
    }
    /// What the capsule does to the colour behind it, which the grey alone
    /// cannot do. A grey at alpha 0.343 keeps 0.657 of the backdrop's colour
    /// away from grey; the HUD keeps 1.26 of it, so a coloured window behind
    /// the banner stayed noticeably duller than behind the HUD. Measured on
    /// four saturated backdrops the HUD lands on the same brightness line as
    /// this one to a tenth of a level and multiplies what is left of the colour by
    /// 1.26 every time, so the sample is saturated by 1.26 / 0.657 after the
    /// grey. Over a strong green the HUD reads 17, 168, 55 and so does this.
    static let backdropSaturation = 1.26 / (1 - 0.343)

    /// Accessibility > Display > Reduce transparency, which the system's own
    /// capsule follows and this one has to follow with it. Measured on 26.5.1
    /// over flat backdrops of 0, 115, 179 and 255 the HUD draws 26, 54, 70 and
    /// 89 with the setting on, a line of 0.247 in + 26 where it otherwise draws
    /// 0.657 in + 31, so the capsule is much darker. It still tracks what is
    /// behind it, so this is a heavier blur and a darker line and not a flat
    /// fill: the backdrop keeps none of its detail (0.09, 0.17, 0.19 and 0.26
    /// of the energy a page of text carries at 2, 4, 8 and 16 pixels, against
    /// 1.00, 2.26, 3.15 and 4.23 with the setting off). The colour survives at
    /// a lower saturation, measured the same way over a green, a red and a
    /// blue: the HUD keeps 1.65 of what the line leaves, not 1.92.
    static let reducedScrimColor = NSColor(white: 0.135, alpha: 0.753)
    static let reducedSaturation = 1.65
    /// Enough to leave the backdrop no detail at all, as the HUD's does.
    static let reducedBlurRadius: CGFloat = 20
    /// The close badge under the same setting: the system's is a flat disc
    /// with no rim, the same over every backdrop, and it still follows the
    /// appearance. Measured over a black and a white backdrop in both: disc
    /// 242 with a 122 cross in the light appearance, 20 with a 149 cross in
    /// the dark.
    static func reducedBadgeDisc(dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.078 : 0.949, alpha: 1)
    }
    static func reducedBadgeInk(dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.584 : 0.478, alpha: 1)
    }
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    /// The HUD softens its backdrop, and that is most of what tells the two
    /// apart over a real window. Nothing public blurs the way it does, so the
    /// layer samples its backdrop at reduced resolution, as the HUD does, and
    /// blurs the smaller sample.
    ///
    /// The measure is the energy in each scale band inside the capsule, over
    /// the same page of text behind both. Band k is boxmean(k) - boxmean(2k):
    /// a cumulative measure, the energy above each scale, piles every finer
    /// band into each number, so all five come out in the same ratio and say
    /// nothing. The page has to be dense, since a sparse one lets the bare
    /// strips the measure reads fall between lines and the HUD's own number
    /// moves 16 percent run to run.
    ///
    /// Across 1-2, 2-4, 4-8, 8-16 and 16-32 pixels the HUD reads 2.56, 2.65,
    /// 3.21, 3.37 and 3.25: nearly flat. A gaussian is not flat, so no single
    /// radius holds both ends. 2.0 is three and a half times too soft at 1-2
    /// pixels. 1.0 lands the two fine
    /// bands (2.33 and 2.71) and runs about half again too sharp at the coarse
    /// ones, and it is the best of the sweep by a wide margin.
    ///
    /// What would fit is a mix, about 43 percent of the unblurred half
    /// resolution sample over 57 percent of a heavy blur, which reproduces all
    /// five bands. It cannot be built. Three mechanisms were measured and all
    /// three are inert: the glass filter's own five-level blur pyramid
    /// (inputBlurRadius with inputBlurOpacity0...4 and inputBlurDistance0...4)
    /// changes nothing at any radius, with or without distances and with or
    /// without the face; the layer's opacity does not mix a sharp share in
    /// either, since at 0.90 the profile is identical to 1.0; and stacking two
    /// backdrop layers
    /// does not mix, because the upper one samples what is already composited
    /// below it.
    ///
    /// The radius is not a smooth dial. It is quantised somewhere inside the
    /// filter: 0.6 measures as unblurred, and 0.8 is far sharper than 1.0.
    /// macOS 27 softens the backdrop far more than 26 did. Measured as the
    /// share of a bar pattern that survives behind the capsule, 8 pt from
    /// crest to crest: the system draws 0.29 there and 1.0 drew 0.57. The dial
    /// is still not smooth, 1.1 through 1.8 all land between 0.37 and 0.41,
    /// and 2.0 is the first value that meets it at 0.27.
    static let backdropScale = 0.5
    static var backdropBlurRadius: Double { drawsMacOS27Capsule ? 2.0 : 1.0 }
    /// The system capsule was redrawn on macOS 27: it softens its backdrop
    /// more, and its rim follows the edge direction instead of running white
    /// all the way round. Everything fitted on 26.5.1 stays for macOS 26,
    /// which is what this tells apart.
    static let drawsMacOS27Capsule = SystemLook.isMacOS27OrLater
    /// One point, as on 26.
    static let rimWidth: CGFloat = 1.15
    static let rimInset: CGFloat = 0
    /// The rim colour, added on rather than blended over, and the same line
    /// along the top and the bottom edge. Over a flat backdrop the system's
    /// two edges read alike: over 29 its top row is 136 and its bottom 134
    /// with the body at 57, and over 199 both clip at 255 with the body at
    /// 172. A white blended over cannot draw that pair, since the 0.40 that
    /// lands on 136 over the dark backdrop draws 205 over the light one. An
    /// added line holds the same 79 levels on both.
    ///
    /// Over a busy backdrop the system's top row does run brighter than its
    /// bottom (125 levels over the body against 80), but that is the glass
    /// pulling the backdrop behind it into the edge, so it follows what is
    /// behind rather than the edge itself.
    ///
    /// Nothing is drawn down the two rounded ends. The system's ends do run
    /// dark, about 65 levels under the body, but that is the glass view's own
    /// edge, which this one draws too: the two land on 57 and 118 against the
    /// system's 52 and 116. A dark layer on top of it reaches a second pixel
    /// inwards (63 against the system's 116 over a mid grey), which is a
    /// border the system's capsule does not have.
    static let rimEdgeColor = NSColor(white: 1, alpha: 0.27)
    /// The glow just inside the top and the bottom edge: about 25 levels at
    /// the first row under the rim, gone by the sixth.
    static let rimGlowColor = NSColor(white: 1, alpha: 0.15)
    static let rimGlowShare = 0.10
    /// Where the edge gradient reaches its own colour, as a share of the
    /// width: the system is at its full edge value 40 pt in from a corner
    /// (0.14 of 288).
    static let rimEdgeShare = 0.06
    /// How far the edge bends its backdrop, and over how many points. Both are
    /// fitted against the HUD's own bend, measured as displacement rather than
    /// by eye: a stripe backdrop of one period behind both capsules, and the
    /// phase of that pattern read column by column in from the edge. The HUD
    /// pulls its backdrop 4.8 pt sideways at the strongest point, 8 pt in from
    /// the edge, and lets go 26 pt in. This pair draws 4.3 pt at the same
    /// place and lets go in the same column, with the HUD's second, weaker
    /// shoulder at 15 pt in as well. The height is not a dial: 16 bends
    /// nothing at all and 30 folds the backdrop over itself, so it stays at
    /// 20, which is what the system's own glass carries, and the amount does
    /// the fitting. The amounts the system's own glass variants carry, -26 to
    /// -80, move this backdrop by well under a point.
    ///
    /// Refitted on the tone the edge actually shows, which the displacement
    /// alone missed: over a backdrop of 16 pt bands, how far each column in
    /// from the edge sits off the flat tone the middle of the capsule holds.
    /// The HUD reads 33, 27, 22, 20, 19, 18, 13, 11 and 11 levels off at 2 to
    /// 10 pt in; -110 read 35, 30, 27, 22, 20, 19, 17, 14 and 12, a quarter
    /// strong the whole way in, which is the dark band the eye finds along
    /// the bottom edge over a bright window. This amount reads 32, 27, 21,
    /// 21, 20, 17, 14, 12 and 11: within a level of the HUD at every column.
    static let refractionAmount = -80.0
    static let refractionHeight = 20.0
    /// The window level OSDUIHelper and Control Center draw their capsule at.
    static let windowLevel = NSWindow.Level(rawValue: 2005)
    /// Entry, hold and exit fitted to the system HUD, measured frame by
    /// frame on 26.5.1 as the tone the screen actually shows. The capsule
    /// fades in over 0.55 s on a curve with a slow start, while it grows in
    /// from 11 pt narrower and 2 pt shorter on each side and settles down
    /// 5.5 pt over 0.35 s, easing out. It holds 1 s after the last press,
    /// then lifts back and shrinks a little further than it grew from (14 by
    /// 3 pt a side) over 0.45 s, and fades on its own curve, which falls fast
    /// and tails off: the system's takes 163 ms from four fifths of its tone
    /// to one fifth and 291 ms to a twentieth, and this one 163 and 297.
    ///
    /// One fade carries the whole capsule, grey included: a separate, slower
    /// animation on the grey brings the backdrop in ahead of the tone, which
    /// reads as the banner arriving sharp. Every curve was fitted against the
    /// native capsule on the same backdrop, so change them by measuring, not
    /// by taste.
    /// macOS 27 takes its time over the same three stages. Measured frame by
    /// frame at 60 fps over the same backdrop, with one press and nothing else
    /// moving on screen: the system capsule holds its tone 530 ms after it
    /// first shows where this one held at 310, and it is off screen 1233 ms
    /// after it arrives where this one had gone at 1016.
    static var visibleDuration: TimeInterval { drawsMacOS27Capsule ? 0.98 : 1.0 }
    static var fadeInDuration: TimeInterval { drawsMacOS27Capsule ? 0.68 : 0.55 }
    static let fadeInCurve = CAMediaTimingFunction(controlPoints: 0.4, 0.05, 0.2, 0.9)
    static var growDuration: TimeInterval { drawsMacOS27Capsule ? glassGrowInDuration : 0.35 }
    static let fadeOutDuration: TimeInterval = 0.54
    static let fadeOutCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.65, 0.35, 1)
    static let exitShrinkDuration: TimeInterval = 0.45
    static let exitShrinkCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.4, 0.3, 1)
    /// How much smaller the capsule opens. macOS 27 opens from further in:
    /// the system capsule is invisible for its first 137 ms and comes into
    /// view at 266 pt wide, 28 under its settled 294, and takes until 520 ms
    /// to close that.
    static var entryInset: CGSize { drawsMacOS27Capsule ? CGSize(width: 38, height: 8) : CGSize(width: 11, height: 2) }
    static let exitInset = CGSize(width: 14, height: 3)
    static let hiddenLift: CGFloat = 5.5

    private var panels: [CGDirectDisplayID: OSDBannerPanel] = [:]
    /// What Reduce transparency was when the panels above were built.
    private var builtReduced = OSDBannerService.reduceTransparency

    /// Crisp's own menu bar item, handed over by AppDelegate once it exists.
    /// The system hangs each HUD under the menu bar item that owns it, so the
    /// banner hangs under Crisp's and the two stop landing on top of each
    /// other. Weak: the item outlives the banner, and neither owns the other.
    weak var statusItem: NSStatusItem?

    /// Lights that menu bar item while the banner is up, the way the system
    /// lights the Sound control while its own HUD is up. AppDelegate does the
    /// lighting, because an open panel holds the same highlight.
    var setHighlight: ((Bool) -> Void)?

    /// Takes a level the pointer set on a banner's track: the display, what it
    /// was showing, and 0...1 of the scale that banner shows. AppDelegate
    /// wires this to the same services the keys use.
    var onSlide: ((CGDirectDisplayID, OSDImage, Double) -> Void)?

    private var unlightWork: DispatchWorkItem?

    /// Shows (or refreshes) the banner on `screen`. `level` is 0...100 as the
    /// key paths pass it: for brightness a percentage of the display's extended
    /// maximum, for volume the DDC volume itself.
    func show(level: Double, image: OSDImage, on screen: NSScreen) {
        guard let displayID = Self.displayID(of: screen) else { return }
        prunePanels()
        dropPanelsIfTransparencyChanged()
        let panel: OSDBannerPanel
        if let existing = panels[displayID] {
            panel = existing
        } else {
            panel = makePanel()
            panels[displayID] = panel
        }
        panel.model.title = screen.localizedName
        panel.model.image = image
        panel.model.level = max(0, min(1, level / 100))
        // Re-wired on every show: the display is the panel's own, but what it
        // is showing is not (brightness one press, volume the next).
        panel.model.slide = { [weak self] fraction in self?.onSlide?(displayID, image, fraction) }
        panel.model.dismiss = { [weak panel] in panel?.dismiss() }
        // The frame is recomputed every time: a resolution change moves the
        // screen edge, and the menu bar item moves on its own.
        panel.reveal(at: Self.frame(on: screen, centredOn: anchorMidX(on: screen)))
        light()
    }

    /// Centred on Crisp's menu bar item, under the menu bar (visibleFrame
    /// excludes it), and never closer than `trailingInset` to either side
    /// edge. Measured on the system HUD: the brightness capsule's centre sits
    /// on the Display control's, to half a point, and the volume capsule sits
    /// at the trailing inset because centring it on the Sound control would
    /// take it past the screen edge. With no item to measure, the top right
    /// corner, which is where the banner always sat before.
    static func frame(on screen: NSScreen, centredOn midX: CGFloat?) -> NSRect {
        let width = OSDBannerView.size.width
        let corner = screen.frame.maxX - trailingInset - width
        var x = corner
        if showsFullScreenWindow(screen) {
            x = screen.frame.midX - width / 2
        } else if let midX {
            x = min(max(midX - width / 2, screen.frame.minX + trailingInset), corner)
        }
        // The window is the capsule plus the overhang the close badge needs.
        return NSRect(x: x,
                      y: screen.visibleFrame.maxY - topInset - OSDBannerView.size.height,
                      width: width, height: OSDBannerView.size.height)
            .insetBy(dx: -windowMargin, dy: -windowMargin)
    }

    /// Whether `screen` is showing a full-screen space, which the system places
    /// its own capsule by: measured on 26.5.1 over a full-screen window, the
    /// HUD centres on the screen's midline to the point, instead of hanging
    /// under a menu bar item. It has to, since the bar and every item on it
    /// move to another screen while a space is full screen, and the banner
    /// would otherwise fall back to the corner and sit half a screen from the
    /// HUD. Note this is only for a real full-screen space: a screen whose menu
    /// bar has simply moved away keeps the corner, which is where the system
    /// puts its capsule then too.
    ///
    /// The signal is a window covering the display exactly, owned by an app
    /// with a Dock tile, since only those take a space full screen. A zoomed
    /// window stops short of the menu bar and does not match, and nothing
    /// covers a display exactly in the ordinary case (measured in both
    /// states). An accessory app's window can, though: the Cua Driver desktop
    /// tool keeps an empty overlay over a whole display while it runs, and
    /// without the owner check the banner centred on the midline, 708 pt from
    /// its item.
    ///
    /// The answer is held briefly per display. This runs on every key press,
    /// and the window list is a round trip to the window server: usually about
    /// 1.3 ms here, but measured at 53 ms on a bad one with only thirty
    /// windows open, which on a held key is a visible hitch in the fade the
    /// press itself is driving. A space takes far longer than the hold to come
    /// and go, so a stale answer inside it cannot be wrong in practice.
    private static var fullScreenCache: [CGDirectDisplayID: (value: Bool, at: Date)] = [:]
    private static let fullScreenCacheLife: TimeInterval = 0.5

    private static func showsFullScreenWindow(_ screen: NSScreen) -> Bool {
        guard let displayID = displayID(of: screen) else { return false }
        if let hit = fullScreenCache[displayID],
           Date().timeIntervalSince(hit.at) < fullScreenCacheLife {
            return hit.value
        }
        let bounds = CGDisplayBounds(displayID)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        let covered = windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let frame = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = frame["X"], let y = frame["Y"],
                  let width = frame["Width"], let height = frame["Height"] else { return false }
            guard abs(x - bounds.minX) < 2, abs(y - bounds.minY) < 2,
                  abs(width - bounds.width) < 2, abs(height - bounds.height) < 2,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        }
        fullScreenCache[displayID] = (covered, Date())
        return covered
    }

    /// Where Crisp's menu bar item sits on `screen`, or nil when there is no
    /// item to hang under. The item is on one screen at a time and the menu
    /// bar carries the same items on all of them, so its offset from the right
    /// edge holds on the others; AppDelegate.positionPanel mirrors the menu
    /// panel the same way. An item the menu bar has no room for keeps a window
    /// away from the bar, which the last guard drops.
    private func anchorMidX(on screen: NSScreen) -> CGFloat? {
        guard let window = statusItem?.button?.window,
              let itemScreen = window.screen,
              window.frame.maxY >= itemScreen.frame.maxY - 1 else { return nil }
        return screen.frame.maxX - (itemScreen.frame.maxX - window.frame.midX)
    }

    /// Lights the menu bar item while the banner holds, and puts it out as the
    /// banner starts to leave, not when it has gone: measured on the system's
    /// own, its item goes dark between 0.85 and 0.95 seconds after the press,
    /// while its capsule is still half there. One timer for every screen, so a
    /// press anywhere pushes the light out again, like the hide timer.
    private func light() {
        unlightWork?.cancel()
        setHighlight?(true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A banner the pointer is on holds itself up, and the system's own
            // item stays lit through that, measured 2.25 seconds after the
            // press. The light goes out with the hold that follows the leave.
            guard !self.panels.values.contains(where: { $0.model.hovering }) else { return }
            self.setHighlight?(false)
        }
        unlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    /// Called by a panel when the pointer arrives or leaves, so the menu bar
    /// item follows the banner it belongs to.
    func hoverChanged(_ hovering: Bool) {
        if hovering {
            unlightWork?.cancel()
            setHighlight?(true)
        } else {
            light()
        }
    }

    /// The close badge took the banner away, so the light goes with it instead
    /// of sitting on for the rest of the hold. Another screen's banner may
    /// still be up, and it keeps the light.
    func dismissed(_ panel: OSDBannerPanel) {
        guard !panels.values.contains(where: { $0 !== panel && $0.alphaValue > 0 && !$0.exiting })
        else { return }
        unlightWork?.cancel()
        setHighlight?(false)
    }

    /// Takes every banner away at once. Crisp's own panel carries the same
    /// value on its own slider, so a banner already up when the panel opens is
    /// noise over it, and it floats above the panel: BrightnessHUDService
    /// keeps a new one away and calls this for the ones that are there.
    func hideVisible() {
        for panel in panels.values where panel.alphaValue > 0 {
            panel.dismiss()
        }
    }

    /// The layer the capsule blurs its backdrop with. Nothing public blurs
    /// this gently: every NSGlassEffectView material and every
    /// NSVisualEffectView material takes the same 204-level step below 20,
    /// against the HUD's 37, and a Core Image filter over the backdrop cannot
    /// touch it, because the window server composites the backdrop, not this
    /// process. CABackdropLayer is private, so it is asked for by name and
    /// every step of the lookup may fail; without it the banner keeps the
    /// scrim alone, which holds the tone exactly and only leaves the backdrop
    /// sharp.
    private static func makeBackdrop(frame: NSRect) -> CALayer? {
        guard let tone = makeToneFilters() else { return nil }
        let blur = reduceTransparency ? reducedBlurRadius : backdropBlurRadius
        return makeBackdrop(frame: frame, blur: blur, tone: tone, refract: true)
    }

    /// macOS 27's glass, see glassVariant. Nil where the variant is not
    /// there to ask for, which keeps the hand-made capsule.
    private static func makeGlassView(frame: NSRect) -> NSGlassEffectView? {
        guard NSGlassEffectView.instancesRespond(to: NSSelectorFromString("set_variant:")) else { return nil }
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = cornerRadius
        glass.setValue(glassVariant, forKey: "_variant")
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        return glass
    }

    private static func makeBackdrop(frame: NSRect, blur: CGFloat,
                                     tone: [NSObject], refract: Bool) -> CALayer? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
        else { return nil }
        let backdrop = backdropClass.init()
        backdrop.frame = frame
        // Also private, and the layer works without them, so each is only set
        // where it exists. windowServerAware is what the system's own glass
        // sets on its backdrop layer (dumped from a live NSGlassEffectView):
        // without it the sample is the app's own view of what is behind the
        // window, which goes stale when nothing on screen changes.
        if backdrop.value(forKey: "scale") != nil {
            backdrop.setValue(backdropScale, forKey: "scale")
        }
        if backdrop.value(forKey: "windowServerAware") != nil {
            backdrop.setValue(true, forKey: "windowServerAware")
        }
        var filters: [Any] = []
        if let blurFilter = makeFilter("gaussianBlur") {
            blurFilter.setValue(blur, forKey: "inputRadius")
            // Or the blur pulls in the transparent outside of the capsule and
            // thins its own edge.
            blurFilter.setValue(true, forKey: "inputNormalizeEdges")
            filters.append(blurFilter)
        }
        filters.append(contentsOf: tone)
        if refract, let refraction = makeRefraction(on: backdrop, frame: frame) {
            filters.append(refraction)
        }
        backdrop.filters = filters
        return backdrop
    }

    /// The close badge's own tone line. The system's badge does not sit on the
    /// capsule at all: it samples the desktop the way the capsule does and
    /// lays its own line over it. Measured over flat backdrops of five tones,
    /// its disc reads 187, 203, 230 and 249 where the desktop reads 56, 116,
    /// 183 and 255, which is out = 0.31 in + 170. No white at any alpha over
    /// the capsule can draw that: it takes alpha 0.65 to land on 203 in the
    /// middle and 0.90 to land on 249 at the top, so over a light desktop a
    /// flat badge reads as a grey disc where the system's is nearly clear.
    /// The pair is not that line: the filters do not realise what they are
    /// asked for (0.31 and 0.667 measure as 0.219 and 0.648), so both were
    /// fitted against the system's badge over the same backdrops.
    ///
    /// The system's badge follows the system appearance, which is the whole
    /// reason there are two pairs here: over the same grey backdrop its disc
    /// reads 187 in light and 88 in dark. Swept over four backdrops in each
    /// appearance, in one run per pair on the same screen, its line is
    /// 0.431 in + 150 light and 0.510 in + 23 dark, and these pairs land on
    /// 0.433 in + 150 and 0.510 in + 21. Within 6 levels at every backdrop,
    /// which is the curve the system's own line carries and a multiply and an
    /// add cannot draw.
    ///
    /// What is still not matched: near the far end of each appearance the
    /// system sometimes swaps to the other look, a light disc in dark over a
    /// backdrop of 166 and a dark one in light under about 35. It is not a
    /// fixed threshold, since the same 166 backdrop left the dark look in place
    /// on a later run. Following it at all needs the backdrop's own level,
    /// which only Screen Recording gives.
    private static func badgeTone(dark: Bool) -> (multiply: Double, add: Double) {
        dark ? (multiply: 0.636, add: 0.012) : (multiply: 0.562, add: 0.539)
    }
    /// Heavier than the capsule's: over a checkerboard the system's badge
    /// leaves 3 levels of the backdrop's 59, where the capsule leaves 15.
    private static let badgeBlurRadius: CGFloat = 8
    private static func makeBadgeBackdrop(frame: NSRect, dark: Bool) -> CALayer? {
        guard let multiply = makeFilter("multiplyColor"),
              let add = makeFilter("colorAdd") else { return nil }
        let tone = badgeTone(dark: dark)
        multiply.setValue(NSColor(white: tone.multiply, alpha: 1).cgColor, forKey: "inputColor")
        add.setValue(NSColor(white: tone.add, alpha: 1).cgColor, forKey: "inputColor")
        return makeBackdrop(frame: frame, blur: badgeBlurRadius,
                            tone: [multiply, add], refract: false)
    }

    /// The grey and the colour, as filters over the sampled backdrop rather
    /// than as a layer over it. Order matters: the grey's line has to be drawn
    /// first and the colour lifted on what it leaves, because saturating the
    /// backdrop first drives a strong colour past black in one channel and
    /// clips it. Multiply then add is that line, mixed from the same grey the
    /// fallback layer uses.
    private static func makeToneFilters() -> [NSObject]? {
        guard let multiply = makeFilter("multiplyColor"),
              let add = makeFilter("colorAdd"),
              let saturate = makeFilter("colorSaturate") else { return nil }
        let scrim = reduceTransparency ? reducedScrimColor : scrimColor
        let alpha = scrim.alphaComponent
        multiply.setValue(NSColor(white: 1 - alpha, alpha: 1).cgColor, forKey: "inputColor")
        add.setValue(NSColor(white: alpha * scrim.whiteComponent, alpha: 1).cgColor, forKey: "inputColor")
        saturate.setValue(reduceTransparency ? reducedSaturation : backdropSaturation,
                          forKey: "inputAmount")
        return [multiply, add, saturate]
    }

    /// Every fallback below this depends on it returning nil for a filter the
    /// system does not have, and two things had to be added for that to be
    /// true. The selector is checked, because performing a missing one raises
    /// and takes the app down on the first key press rather than degrading.
    /// And the name is checked against the system's own list, because
    /// filterWithName: answers ANY name with a live object whose inputKeys are
    /// empty: without this a renamed filter would leave the capsule with no
    /// grey and no bend, and nothing would return nil to say so.
    private static func makeFilter(_ name: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterWithName:")),
              filterTypes.contains(name)
        else { return nil }
        return filterClass.perform(NSSelectorFromString("filterWithName:"), with: name)?
            .takeUnretainedValue() as? NSObject
    }

    /// The filter names this system has, read once. Empty if the call is gone,
    /// which makes every makeFilter above fail into its own fallback.
    private static let filterTypes: Set<String> = {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterTypes")),
              let names = filterClass.perform(NSSelectorFromString("filterTypes"))?
                .takeUnretainedValue() as? [String]
        else { return [] }
        return Set(names)
    }()

    /// Bends the backdrop into the capsule's edge, the way a real edge of
    /// glass would. The HUD does this and it is the last thing that tells the
    /// two apart on a patterned backdrop: behind the HUD a straight line
    /// curves along the inside of the edge, behind a plain masked capsule it
    /// runs straight into a hard cut.
    ///
    /// This is the system's own glass filter. It reads the shape it bends
    /// around from a distance-field layer, which is why it draws nothing on a
    /// bare backdrop layer, so the shape layer goes in as a named sublayer
    /// and the filter is pointed at it. The face is left off: the flat grey
    /// carries the tone, and the filter's own face colour never applied here.
    ///
    /// Every class and key is private. Any of them missing leaves the banner
    /// with the blurred backdrop and no bend, which is where it was before.
    private static func makeRefraction(on backdrop: CALayer, frame: NSRect) -> NSObject? {
        guard let sdfClass = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let elementClass = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let effectClass = NSClassFromString("CASDFOutputEffect") as? NSObject.Type,
              let filter = makeFilter("glassBackground") else { return nil }
        let shapeName = "@0"
        let shape = sdfClass.init()
        shape.name = shapeName
        shape.frame = frame
        shape.setValue(effectClass.init(), forKey: "effect")
        let element = elementClass.init()
        element.frame = frame
        element.cornerRadius = cornerRadius
        element.cornerCurve = .continuous
        // The element hangs off a plain layer, as it does in the system's own
        // tree; hung directly off the shape layer it is not picked up.
        let holder = CALayer()
        holder.addSublayer(element)
        shape.addSublayer(holder)
        backdrop.addSublayer(shape)
        filter.setValue(shapeName, forKey: "inputSourceSublayerName")
        // This filter carries a blur of its own, and its default is heavy:
        // left alone it takes the banner to 5.2 of the backdrop's fine
        // structure where the HUD leaves 15.4. The gaussian above it is the
        // one that is fitted, so this one is off.
        filter.setValue(0.0, forKey: "inputBlurRadius")
        filter.setValue(1.0, forKey: "inputRefractionOpacity")
        filter.setValue(refractionAmount, forKey: "inputInnerRefractionAmount")
        filter.setValue(refractionHeight, forKey: "inputInnerRefractionHeight")
        filter.setValue(0.0, forKey: "inputOuterRefractionAmount")
        filter.setValue(0.0, forKey: "inputOuterRefractionHeight")
        filter.setValue(-1.0, forKey: "inputRefractionDistance0")
        filter.setValue(0.0, forKey: "inputRefractionDistance1")
        filter.setValue(0.0, forKey: "inputFaceOpacity")
        return filter
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Reduce transparency changes what a panel draws, and every filter is set
    /// when its layers are made, so the panels are dropped and built again the
    /// first time the banner comes up after the setting moves. Nothing watches
    /// the setting: there is no work to do while no banner is on screen.
    private func dropPanelsIfTransparencyChanged() {
        guard builtReduced != Self.reduceTransparency else { return }
        builtReduced = Self.reduceTransparency
        for (id, panel) in panels {
            panel.close()
            panels[id] = nil
        }
    }

    private func prunePanels() {
        let live = Set(NSScreen.screens.compactMap(Self.displayID(of:)))
        for (id, panel) in panels where !live.contains(id) {
            panel.close()
            panels[id] = nil
        }
    }

    /// How far the window reaches past the capsule on every side. The close
    /// badge hangs 2.5 points over the corner and its shadow reaches 30 past
    /// it, and a window cut to the capsule clips both off.
    static let windowMargin: CGFloat = 30

    /// The window is the capsule with that margin around it.
    private static var windowSize: CGSize {
        CGSize(width: OSDBannerView.size.width + 2 * Self.windowMargin,
               height: OSDBannerView.size.height + 2 * Self.windowMargin)
    }

    /// Where the capsule sits inside the window. Views placed here keep their
    /// margins through the entry grow and the exit shrink, since they resize
    /// with the window.
    private static func capsuleRect(in root: NSView) -> NSRect {
        root.bounds.insetBy(dx: Self.windowMargin, dy: Self.windowMargin)
    }

    /// The close badge, centred 6.5 points in from the capsule's top left
    /// corner and 18 across, so it hangs 2.5 points over the corner. Measured
    /// on the system HUD over a flat backdrop.
    private static func badgeRect(in root: NSView) -> NSRect {
        let capsule = capsuleRect(in: root)
        return NSRect(x: capsule.minX + OSDBadgeView.centreInset - OSDBadgeView.size / 2,
                      y: capsule.maxY - OSDBadgeView.centreInset - OSDBadgeView.size / 2,
                      width: OSDBadgeView.size, height: OSDBadgeView.size)
    }

    private func makePanel() -> OSDBannerPanel {
        let p = OSDBannerPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Set the level explicitly and never isFloatingPanel: that setter
        // silently resets the level to floating (3), under the menu bar.
        p.level = Self.windowLevel
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        // The masked capsule carries the shape: the edge profile matched the
        // native capsule to within two pixels without a WindowServer shadow.
        p.hasShadow = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        p.alphaValue = 0

        let root = BannerRootView(frame: NSRect(origin: .zero, size: Self.windowSize))
        root.wantsLayer = true

        // The capsule is what is behind the window, softened and toned down,
        // inside a layer masked to the capsule shape. The content sits above
        // it, so the label, glyphs and track keep their own tone.
        let clip = NSView(frame: Self.capsuleRect(in: root))
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.autoresizingMask = [.width, .height]
        let glassView = Self.drawsMacOS27Capsule && !Self.reduceTransparency
            ? Self.makeGlassView(frame: clip.frame) : nil
        if glassView != nil {
            // The system glass is the whole capsule, see glassVariant.
        } else if let backdrop = Self.makeBackdrop(frame: clip.bounds) {
            clip.layer?.addSublayer(backdrop)
            p.backdrop = backdrop
        } else {
            let scrim = CALayer()
            scrim.frame = clip.bounds
            scrim.backgroundColor = (Self.reduceTransparency ? Self.reducedScrimColor
                                                              : Self.scrimColor).cgColor
            clip.layer?.addSublayer(scrim)
        }
        root.addSubview(glassView ?? clip)

        let hosting = NSHostingView(rootView: OSDBannerView(model: p.model))
        // Every colour in the banner is explicit, so the appearance only
        // reaches what the system draws itself, which is the held knob's
        // glass. That has to be the light one: the system's own slider knob
        // lifts its backdrop, and dark glass over the capsule's own tone is
        // invisible (measured 102 where the body reads 100). The appearance
        // goes here and not on the panel: the capsule takes its own tone from
        // the grey, and an appearance on the panel would tint that too.
        hosting.appearance = NSAppearance(named: .darkAqua)
        // No intrinsic-size constraints: the content follows the window
        // through the entry grow and the exit shrink.
        hosting.sizingOptions = []
        hosting.frame = Self.capsuleRect(in: root)
        hosting.autoresizingMask = [.width, .height]
        root.addSubview(hosting)

        // Hover is read here and not with SwiftUI's own onHover: onHover wants
        // a key window, and this panel is key only while the pointer is
        // already on it, so a tracking area set to be always active is what
        // sees the pointer arrive. The view takes no
        // clicks (hitTest returns nil), so the track's drag still lands.
        // Three points out, so the badge hanging over the corner is inside it.
        let hover = BannerHoverView(frame: Self.capsuleRect(in: root).insetBy(dx: -3, dy: -3))
        hover.autoresizingMask = [.width, .height]
        hover.onHover = { [weak p] inside in p?.setHovering(inside) }
        root.addSubview(hover)

        // The close badge is drawn here and not in SwiftUI: it samples the
        // desktop the way the system's does, which no fill can, and it hangs
        // over the capsule's corner (see Self.windowMargin).
        let badge = OSDBadgeView(frame: Self.badgeRect(in: root))
        badge.alphaValue = 0
        badge.onClick = { [weak p] in p?.dismiss() }
        // Rebuilt rather than retuned when the appearance changes, since the
        // filters are set when the layer is made and the badge is one layer.
        badge.retone = { [weak badge, weak p] dark in
            guard let badge else { return }
            p?.badgeBackdrop?.removeFromSuperlayer()
            p?.badgeBackdrop = nil
            if Self.reduceTransparency {
                badge.disc.backgroundColor = Self.reducedBadgeDisc(dark: dark).cgColor
            } else if let sample = Self.makeBadgeBackdrop(frame: badge.bounds, dark: dark) {
                badge.disc.backgroundColor = nil
                badge.disc.addSublayer(sample)
                p?.badgeBackdrop = sample
            } else {
                badge.disc.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            }
        }
        badge.addGlyph()
        root.addSubview(badge)
        p.badge = badge

        // The native capsule carries a rim one point wide along its edge,
        // drawn here over the capsule and its content. Measured at rest it
        // lifts the capsule 74 levels over a black backdrop, 47 over a mid
        // grey and 28 over a light one, which is white blended over, not
        // added: a flat alpha fits all three.
        //
        // macOS 27 redrew that rim: it is bright along the straight top and
        // bottom and dark down the two rounded ends, so OSDBevelView draws it
        // instead there. The flat white below is the one fitted on 26.5.1 and
        // stays for macOS 26.
        let bevel: NSView
        if Self.drawsMacOS27Capsule {
            bevel = OSDBevelView(frame: Self.capsuleRect(in: root))
        } else {
            bevel = NSView(frame: Self.capsuleRect(in: root))
            bevel.wantsLayer = true
            bevel.layer?.cornerRadius = Self.cornerRadius
            bevel.layer?.cornerCurve = .continuous
            bevel.layer?.borderWidth = 1
            bevel.layer?.borderColor = NSColor.white.withAlphaComponent(0.36).cgColor
        }
        bevel.autoresizingMask = [.width, .height]
        // Under the content and the hover view: a plain NSView takes every
        // click inside its bounds, and this one covers the whole capsule.
        root.addSubview(bevel, positioned: .below, relativeTo: hosting)

        // The rim is not faded in with the content: the system's is there from
        // the first frame. On the way out it goes with the glass.
        if let glassView, let content = hosting.layer,
           let rim = (bevel as? OSDBevelView)?.rings ?? bevel.layer {
            content.opacity = 0
            glassView.alphaValue = 0
            p.glass = OSDGlass(view: glassView, faded: [content], rim: rim, bevel: bevel)
        }

        p.contentView = root
        return p
    }
}

/// The system glass view, tuned to the HUD (see OSDBannerService.glassInputs),
/// and the layers that fade with it. The panel ramps three of the inputs
/// (the blur, the bend and the tint), see OSDBannerPanel.showGlass.
@available(macOS 26.0, *)
@MainActor
struct OSDGlass {
    let view: NSGlassEffectView
    let faded: [CALayer]
    /// The rim's rings, which the entry ramps. Not the whole bevel view: its
    /// glow stays up, see OSDBevelView.rings.
    let rim: CALayer
    let bevel: NSView

    /// The layer that carries the view's glass filter, set up so that every
    /// filter it is given is tuned. The view writes a new filter at each size
    /// change (its blur follows its size, 5.7 at 260 pt wide to 6.1 at 288),
    /// from SwiftUI's render pass, after any layout hook: a tuning put back
    /// from outside lost to it on every other frame of the entry's grow and
    /// the exit's shrink, and the glass flashed. So the layer tunes the filter
    /// as it is set. Nil if the view has no such filter, and the banner then
    /// shows the view as it draws itself.
    func tunedBackdrop() -> CALayer? {
        view.layoutSubtreeIfNeeded()
        guard let layer = Self.backdrop(in: view.layer),
              let tunedClass = Self.tunedClass(for: type(of: layer)) else { return nil }
        if layer.value(forKey: Self.targetsKey) == nil {
            layer.setValue([
                "inputBlurRadius": OSDBannerService.glassBlur.closed,
                "inputInnerRefractionAmount": OSDBannerService.glassBend.closed,
                "inputFaceOpacity": OSDBannerService.glassTint.closed,
                "inputInnerRefractionHeight": OSDBannerService.glassRefractionHeight.closed,
                "inputKeyFillHighlightAmount": OSDBannerService.glassHighlight.closed,
                "backdropScale": OSDBannerService.glassBackdropScale
            ], forKey: Self.targetsKey)
        }
        if !layer.isKind(of: tunedClass) { object_setClass(layer, tunedClass) }
        layer.filters = layer.filters
        return layer
    }

    /// Takes each input from where it is to its value on its own curve. The
    /// window server does not run a Core Animation animation on this view's
    /// filter (it drew the settled glass from the first frame), so the inputs
    /// are stepped here and the filter set again on each step.
    func ramp(_ layer: CALayer, _ legs: [OSDGlassRamp.Leg]) {
        Self.ramps[ObjectIdentifier(layer)]?.stop()
        let ramp = OSDGlassRamp(layer: layer, legs: legs,
                                from: layer.value(forKey: Self.targetsKey) as? [String: Double] ?? [:])
        Self.ramps[ObjectIdentifier(layer)] = ramp
        ramp.start()
    }

    private static var ramps: [ObjectIdentifier: OSDGlassRamp] = [:]

    static let filterName = "glassBackground"
    /// Where the three ramped inputs are headed, kept on the layer. The ramps
    /// draw the way there; this is what a filter set in the meantime starts at.
    fileprivate nonisolated static let targetsKey = "crispGlassTargets"

    /// A subclass of the backdrop's class whose setFilters: passes on a tuned
    /// copy of the glass filter. The filter is copied and not changed in
    /// place, because a change in place never reaches the window server.
    private static func tunedClass(for base: AnyClass) -> AnyClass? {
        let name = "CrispTuned" + NSStringFromClass(base)
        if let existing = NSClassFromString(name) { return existing }
        if NSStringFromClass(base).hasPrefix("CrispTuned") { return base }
        guard let tuned = objc_allocateClassPair(base, name, 0) else { return nil }
        let selector = NSSelectorFromString("setFilters:")
        typealias SetFilters = @convention(c) (AnyObject, Selector, NSArray?) -> Void
        let inherited = unsafeBitCast(class_getMethodImplementation(base, selector), to: SetFilters.self)
        let setFilters: @convention(block) (CALayer, NSArray?) -> Void = { layer, filters in
            let targets = layer.value(forKey: targetsKey) as? [String: Double] ?? [:]
            let scale = targets["backdropScale"] ?? OSDBannerService.glassBackdropScale
            if layer.value(forKey: "scale") as? Double != scale {
                layer.setValue(scale, forKey: "scale")
            }
            inherited(layer, selector, tunedFilters(filters, targets: targets))
        }
        class_addMethod(tuned, selector, imp_implementationWithBlock(setFilters), "v@:@")
        objc_registerClassPair(tuned)
        return tuned
    }

    private nonisolated static func tunedFilters(_ filters: NSArray?, targets: [String: Double]) -> NSArray? {
        guard let filters = filters as? [NSObject],
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return filters as NSArray? }
        return filters.map { filter -> NSObject in
            guard filter.value(forKey: "name") as? String == "glassBackground",
                  let copy = filterClass.perform(NSSelectorFromString("filterWithName:"), with: "glassBackground")?
                    .takeUnretainedValue() as? NSObject,
                  let keys = filter.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String]
            else { return filter }
            for key in keys { copy.setValue(filter.value(forKey: key), forKey: key) }
            copy.setValue("glassBackground", forKey: "name")
            for (key, value) in OSDBannerService.glassInputs { copy.setValue(value, forKey: key) }
            for (key, value) in targets where key.hasPrefix("input") { copy.setValue(value, forKey: key) }
            return copy
        } as NSArray
    }

    private static func backdrop(in layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if (layer.filters as? [NSObject])?.contains(where: { $0.value(forKey: "name") as? String == filterName }) == true {
            return layer
        }
        for sublayer in layer.sublayers ?? [] {
            if let found = backdrop(in: sublayer) { return found }
        }
        return nil
    }
}

/// The window is bigger than the capsule so the badge and its shadow have
/// room (see OSDBannerService.windowMargin), and a banner that is up takes
/// mouse events. This hands back everything outside the capsule, or the
/// margin would swallow clicks on the menu bar above the banner and on the
/// desktop around it.
@available(macOS 26.0, *)
final class BannerRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // The same three points the hover view takes, which is what holds the
        // badge hanging over the capsule's corner.
        let live = bounds.insetBy(dx: OSDBannerService.windowMargin - 3,
                                  dy: OSDBannerService.windowMargin - 3)
        return live.contains(local) ? super.hitTest(point) : nil
    }
}

/// The close badge: a disc that samples the desktop through its own backdrop
/// layer, with the system's xmark over it. AppKit and not SwiftUI, because a
/// SwiftUI fill can only blend with the capsule under it, and the system's
/// badge reads the desktop straight (see OSDBannerService.badgeTone).
@available(macOS 26.0, *)
final class OSDBadgeView: NSView {
    /// Measured on the system HUD: 18 points across, its centre 6.5 points in
    /// from the capsule's top left corner.
    static let size: CGFloat = 18
    static let centreInset: CGFloat = 6.5

    var onClick: (() -> Void)?
    /// The disc itself. It is a sublayer and not this view's own layer because
    /// the shadow below has to fall outside it, and a layer that masks its
    /// content to a circle masks its shadow away with it.
    private(set) var disc = CALayer()
    /// Kept so its resolution can follow the screen, see below.
    private var shadowLayer = CAGradientLayer()
    /// Kept so its ink can follow the appearance, see applyAppearance.
    private weak var glyph: NSImageView?
    /// Rebuilds the disc's sample of the desktop for the appearance given.
    /// Set by OSDBannerService, which owns the tone the sample is drawn with.
    var retone: ((Bool) -> Void)? { didSet { applyAppearance() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.frame = bounds
        disc.cornerRadius = frame.width / 2
        disc.masksToBounds = true
        disc.borderWidth = 1

        layer?.addSublayer(disc)
        shadowLayer = makeShadow()
        layer?.insertSublayer(shadowLayer, below: disc)
        applyAppearance()
    }

    /// A layer made by hand draws at one pixel a point whatever the screen is,
    /// where AppKit gives a view's own layer the screen's scale. On a Retina
    /// panel that left the shadow drawn at half resolution and scaled up, which
    /// is what turned its ramp into steps.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        disc.contentsScale = scale
        shadowLayer.contentsScale = scale
        shadowLayer.mask?.contentsScale = scale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// The two looks the system's badge has. In light it is a light disc with
    /// a dark cross and in dark the mirror of that, over the same backdrop:
    /// measured over a grey desktop its disc reads 187 against 88 and its
    /// cross flips with it. The tone lives in OSDBannerService.badgeAdd; here
    /// are the ink and the rim.
    ///
    /// The ink is half the disc's way to black or to white, and it is the disc
    /// it goes half way from, not a flat grey: over four backdrops in each
    /// appearance the system's cross reads 0.491 to 0.502 of the way down in
    /// light and 0.551 to 0.555 of the way up in dark.
    ///
    /// The rim is the disc's own edge, lit. The alpha is what it measures
    /// rather than what it is asked for, since a one point border is half
    /// covered by its own anti-aliasing: 0.66 lands on the 0.485 of the disc's
    /// headroom the system's rim carries in light, and the dark rim carries
    /// only 0.20 of it (measured 88 over a disc of 46, and 71 over 30).
    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduced = OSDBannerService.reduceTransparency
        retone?(dark)
        disc.borderColor = reduced ? NSColor.clear.cgColor
                                   : NSColor(white: 1, alpha: dark ? 0.20 : 0.66).cgColor
        shadowLayer.colors = (dark ? Self.shadowAlphasDark : Self.shadowAlphasLight)
            .map { NSColor.black.withAlphaComponent($0).cgColor }
        glyph?.contentTintColor = reduced ? OSDBannerService.reducedBadgeInk(dark: dark)
                                          : Self.inkColour(dark: dark)
    }

    private static func inkColour(dark: Bool) -> NSColor {
        dark ? NSColor(white: 1, alpha: 0.552) : NSColor(white: 0, alpha: 0.498)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The shadow the system's badge sits on, which is what makes it an object
    /// over a light desktop rather than a disc that disappears into it. A
    /// radial gradient, masked to the outside of the disc, since the disc is a
    /// backdrop sample and lets whatever is under it through, which took ten
    /// levels off its own tone.
    ///
    /// The alphas are the system's own, read as a drop profile: over a flat
    /// backdrop, how far the screen sits below it ring by ring, in the quadrant
    /// up and left of the disc where nothing but desktop is behind. Taken that
    /// way the system's shadow is a black at 0.079 one point outside the disc,
    /// 0.044 five points out, 0.024 eleven out and 0.007 twenty-two out, which
    /// is the same profile over two backdrops. Read it there and not by eye:
    /// the near end is what reads as a drawn circle, not the reach, and a tail
    /// a third to a half too strong from eleven points out is what reads too
    /// wide. A blur instead of a gradient
    /// does not do it either, since the tail is far longer than any blur's.
    ///
    /// The dark appearance carries its own, weaker profile, which the same
    /// measurement gives: 0.048 a point out where light has 0.079, and it is
    /// gone by twenty points out where light still carries 0.024.
    private static let shadowReach: CGFloat = 36
    /// Points out from the centre, as fractions of the reach: 9, 10, 12, 14,
    /// 17, 20, 24, 28, 31, 34, 36. Inside 9 is the disc, which the mask cuts.
    private static let shadowLocations: [CGFloat] = [
        0.25, 0.278, 0.333, 0.389, 0.472, 0.556, 0.667, 0.778, 0.861, 0.944, 1.0
    ]
    private static let shadowAlphasLight: [CGFloat] = [
        0.085, 0.079, 0.058, 0.044, 0.031, 0.024, 0.016, 0.010, 0.007, 0.004, 0
    ]
    private static let shadowAlphasDark: [CGFloat] = [
        0.052, 0.048, 0.027, 0.016, 0.008, 0.006, 0.003, 0.001, 0, 0, 0
    ]

    private func makeShadow() -> CAGradientLayer {
        let reach = Self.shadowReach
        let shadow = CAGradientLayer()
        shadow.type = .radial
        shadow.frame = CGRect(x: bounds.midX - reach, y: bounds.midY - reach,
                              width: reach * 2, height: reach * 2)
        shadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 1)
        shadow.locations = Self.shadowLocations.map { NSNumber(value: Double($0)) }
        let hole = CGMutablePath()
        hole.addRect(CGRect(origin: .zero, size: shadow.frame.size))
        hole.addEllipse(in: CGRect(x: reach - bounds.width / 2, y: reach - bounds.height / 2,
                                   width: bounds.width, height: bounds.height))
        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: shadow.frame.size)
        mask.path = hole
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        shadow.mask = mask
        return shadow
    }

    /// The glyph over the disc. Its weight is what fits it: the system's
    /// covers 29 pixels at 1x and its ink adds up to about 1900 levels below
    /// the disc, where 9 point bold covers 29 at 1975 and every lighter weight
    /// leaves the X too thin (8.5 regular covers 19 at 1003). Half a point over
    /// the 9 the ink fit asked for. Its colour follows the appearance, see
    /// applyAppearance.
    func addGlyph() {
        let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        guard let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let view = NSImageView(image: image)
        view.contentTintColor = Self.inkColour(
            dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        // Centred on the X's own crossing point, which is what the eye reads
        // as the middle of the badge. SF Symbols carry their own bearings, so
        // the ink is not in the middle of the image they hand over, and a
        // hand-measured nudge does not survive a size change (or a screen: at
        // one pixel a point a half point moves nothing at all). This asks the
        // image where its ink is.
        let ink = Self.inkOffset(of: image)
        view.frame = bounds.offsetBy(dx: -ink.x, dy: -ink.y)
        view.imageScaling = .scaleNone
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        glyph = view
    }

    /// Where a symbol's ink sits in its own image, in points from the image's
    /// centre. Read off the image itself, so it follows the point size.
    private static func inkOffset(of image: NSImage) -> CGPoint {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return .zero }
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        let scaleX = image.size.width / CGFloat(rep.pixelsWide)
        let scaleY = image.size.height / CGFloat(rep.pixelsHigh)
        let midX = CGFloat(minX + maxX + 1) / 2 * scaleX
        let midY = CGFloat(minY + maxY + 1) / 2 * scaleY
        // The bitmap's rows run down and the view's y runs up.
        return CGPoint(x: midX - image.size.width / 2, y: image.size.height / 2 - midY)
    }

    /// Round, and only while the badge is there to be clicked.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.5 else { return nil }
        let local = convert(point, from: superview)
        let radius = bounds.width / 2
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= radius ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Steps the glass filter's ramped inputs, see OSDGlass.ramp.
@available(macOS 26.0, *)
@MainActor
final class OSDGlassRamp: NSObject {
    struct Leg {
        let key: String
        let to: Double
        let duration: TimeInterval
        let curve: CAMediaTimingFunction
        let delay: TimeInterval

        init(_ key: String, _ to: Double, _ duration: TimeInterval, _ curve: CAMediaTimingFunction,
             delay: TimeInterval = 0) {
            (self.key, self.to, self.duration, self.curve, self.delay) = (key, to, duration, curve, delay)
        }
    }

    private let layer: CALayer
    private let legs: [Leg]
    private let from: [String: Double]
    private let begin = CACurrentMediaTime()
    private var timer: Timer?

    init(layer: CALayer, legs: [Leg], from: [String: Double]) {
        (self.layer, self.legs, self.from) = (layer, legs, from)
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(step),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        step()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func step() {
        let elapsed = CACurrentMediaTime() - begin
        var values = layer.value(forKey: OSDGlass.targetsKey) as? [String: Double] ?? [:]
        var prior = from
        var seen = Set<String>()
        for leg in legs {
            let start = prior[leg.key] ?? leg.to
            if elapsed >= leg.delay || !seen.contains(leg.key) {
                values[leg.key] = start + (leg.to - start)
                    * leg.curve.solve(min(max(elapsed - leg.delay, 0) / leg.duration, 1))
            }
            prior[leg.key] = leg.to
            seen.insert(leg.key)
        }
        layer.setValue(values, forKey: OSDGlass.targetsKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.filters = layer.filters
        CATransaction.commit()
        if legs.allSatisfy({ elapsed >= $0.delay + $0.duration }) { stop() }
    }
}

extension CAMediaTimingFunction {
    /// The curve's output at an input time, 0...1. Nothing public evaluates a
    /// timing function; this is the method Core Animation itself uses.
    func solve(_ time: Double) -> Double {
        let selector = NSSelectorFromString("_solveForInput:")
        guard responds(to: selector) else { return time }
        typealias Solve = @convention(c) (AnyObject, Selector, Float) -> Float
        return Double(unsafeBitCast(method(for: selector), to: Solve.self)(self, selector, Float(time)))
    }
}
