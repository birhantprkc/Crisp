import AppKit
import SwiftUI

/// One banner window. Holds its model and the hide timer; OSDBannerService
/// owns placement and content.
@available(macOS 26.0, *)
@MainActor
final class OSDBannerPanel: NSPanel {
    /// Only ever while the pointer is on the capsule, see setHovering.
    override var canBecomeKey: Bool { true }

    let model = OSDBannerModel()
    /// The capsule's backdrop layer, or nil when the private class was
    /// missing and the banner fell back to the flat grey. See keepAlive.
    var backdrop: CALayer?
    /// macOS 27's glass, or nil where the whole window fades instead.
    var glass: OSDGlass?
    /// The close badge and the layer it samples the desktop with.
    var badge: OSDBadgeView?
    var badgeBackdrop: CALayer?
    private var hideWork: DispatchWorkItem?
    /// Whether Crisp was the front app when the pointer arrived on the capsule.
    private var crispWasActive = false
    private var keepAliveWork: DispatchWorkItem?
    /// Where the banner sits when it is up. Kept so a pointer arriving during
    /// the exit can bring it back to the frame it was leaving.
    private var restFrame: NSRect = .zero
    private var growTimer: Timer?
    private var growBegin = 0.0

    /// Grows the capsule inside a window that is already at its final frame.
    /// The window itself cannot carry the grow: a window frame animation is
    /// pixel-snapped, so the capsule jumps two points at a time, and the
    /// system's own capsule grows smoothly. The views inside take it instead,
    /// stepped at 120 Hz.
    private func growCapsule() {
        growTimer?.invalidate()
        growBegin = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(growStep), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        growTimer = timer
        growStep()
    }

    @objc private func growStep() {
        guard let glass, let root = contentView else { growTimer?.invalidate(); return }
        let t = CACurrentMediaTime() - growBegin
        let p = OSDBannerService.glassGrowInCurve.solve(min(t / OSDBannerService.glassGrowInDuration, 1))
        let final = root.bounds.insetBy(dx: OSDBannerService.windowMargin, dy: OSDBannerService.windowMargin)
        // The capsule opens narrower and shorter and grows into place, pinned
        // at the middle of its top edge: the system's left edge runs 321 to 308
        // while its right runs 587 to 600, so the middle stays put and it grows
        // out to both sides and downward.
        //
        // The glass and the rim are resized, not scaled, while the content is
        // drawn at its final size and scaled down into the smaller capsule.
        // Both halves are needed. The system's label at 140 ms matches its
        // settled label at 0.970, so the text does ride a scale; but scaling
        // the glass as well draws its refraction band thinner than it settles
        // at, and a thin band is a hard dark line that lifts as the grow ends,
        // which reads as the capsule's inner shadow going away. The system
        // holds 10.5 levels under its body throughout.
        let inset = CGSize(width: OSDBannerService.entryInset.width * (1 - p),
                           height: OSDBannerService.entryInset.height * (1 - p))
        let size = CGSize(width: final.width - inset.width, height: final.height - inset.height)
        let rect = CGRect(x: final.midX - size.width / 2, y: final.maxY - size.height,
                          width: size.width, height: size.height)
        let scale = size.width / final.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.view.frame = rect
        glass.bevel.frame = rect
        if let content = glass.faded.first?.delegate as? NSView {
            content.frame = final
            if let layer = content.layer {
                let pivot = CGPoint(x: content.bounds.width / 2, y: content.bounds.height)
                var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
                transform = CATransform3DScale(transform, scale, scale, 1)
                layer.transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
            }
        }
        CATransaction.commit()
        if t >= OSDBannerService.glassGrowInDuration { growTimer?.invalidate(); growTimer = nil }
    }
    /// When the running entry ends. `alphaValue` reads the interpolated value
    /// during a window animation, so a second press inside the entry would
    /// otherwise restart it from the shrunk frame.
    private var entryEnds = Date.distantPast
    /// Whether an exit has run since the last reveal. A press lands inside one
    /// often, one hold after the press before it. Nothing clears this when the
    /// exit ends on its own: by then stopping it is a pair of no-ops.
    var exiting = false

    /// Places the banner at `frame` and brings it to full opacity, restarting
    /// the hide timer. A hidden or fading banner plays the system HUD's entry;
    /// a visible one only moves, so key repeat animates nothing.
    func reveal(at frame: NSRect) {
        hideWork?.cancel()
        keepAliveWork?.cancel()
        startKeepAlive()
        restFrame = frame
        // A banner on screen is a control: the pointer gets a knob on the
        // track and a close badge, as the system HUD does. It takes clicks
        // only while the pointer is on the capsule, see setHovering.
        ignoresMouseEvents = !model.hovering
        if exiting {
            // A second animation on a property does not replace the one in
            // flight: both drive the window, and the exit wins, so the banner
            // blinks out and comes back. Stop it where it is and go up from
            // there. Its own alphaValue is still 1 for the first frames, which
            // is why the flag says this and not the value.
            stopAnimations()
            exiting = false
            // The exit left the window part way down and part way in. The
            // entry window from the press before it is meaningless now, and
            // leaving it set skips the branch below and strands the banner
            // dim at the shrunk frame for the whole hold.
            entryEnds = .distantPast
        }
        if Date() < entryEnds {
            // The grow in flight lands on the frame it started for. That is
            // the same frame on a key repeat, but not if the menu bar item
            // moved or the screen changed between two presses, and nothing
            // later corrects a settled banner, so re-aim it here.
            if frame != self.frame { setFrame(frame, display: false, animate: true) }
        } else if alphaValue < 1 {
            entryEnds = Date().addingTimeInterval(OSDBannerService.fadeInDuration)
            // Only from hidden: caught mid-exit the banner is on screen, and
            // dropping it back to the entry frame is a jump the eye sees.
            if alphaValue == 0 {
                setFrame(Self.hidden(frame, inset: OSDBannerService.entryInset), display: false)
                if let glass {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    glass.rim.opacity = Float(OSDBannerService.glassRimStart)
                    CATransaction.commit()
                }
            }
            orderFrontRegardless()
            if glass != nil {
                // The window goes to its final frame at once and the capsule
                // inside grows, see growCapsule.
                setFrame(frame, display: false)
                growCapsule()
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = OSDBannerService.growDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().setFrame(frame, display: true)
                }
            }
            if glass != nil {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = OSDBannerService.glassWindowInDuration
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.19, 0.26, 0.35, 1)
                    animator().alphaValue = 1
                }
                showGlass(true)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = OSDBannerService.fadeInDuration
                    ctx.timingFunction = OSDBannerService.fadeInCurve
                    animator().alphaValue = 1
                }
            }
        } else {
            setFrame(frame, display: false)
        }
        scheduleHide()
    }

    /// The hold before the banner leaves, restarted by every press and by the
    /// pointer leaving the capsule.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.hovering else { return }
            self.fadeOut()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OSDBannerService.visibleDuration, execute: work)
    }

    /// The pointer arriving on the capsule or leaving it. While it is on, the
    /// banner holds: the system's own stays up as long as the pointer is there
    /// and starts its hold again when it leaves, measured at 0.2, 0.6, 1.0 and
    /// 1.45 seconds after the leave. A pointer landing on a banner that is
    /// already leaving brings it back.
    func setHovering(_ hovering: Bool) {
        // A banner that has gone stays gone. Hidden means alpha 0 and the
        // window is still there, so the pointer crossing the corner it used to
        // be in still reaches this, and it must not bring it back. Nor does a
        // banner still fading out under Crisp's own panel take the pointer,
        // which would take key away from the panel and close it.
        if hovering && (alphaValue == 0 || BrightnessHUDService.shared.suppressed) { return }
        guard model.hovering != hovering else { return }
        model.hovering = hovering
        // The window is wider than the capsule (see windowMargin), and a
        // window takes every click inside it whatever its views say: a view
        // that hands the point back stops the view below it from seeing the
        // click, not the window below the window. So the banner is only
        // clickable while the pointer is on the capsule, and the margin, which
        // covers the menu bar over the banner, never swallows anything. The
        // tracking area that calls this fires whether the window takes clicks
        // or not, so the pointer arriving is always seen.
        ignoresMouseEvents = !hovering
        // AppKit draws a slider in a window that is not key in its inactive
        // state: a grey line and a knob with no glass. The panel is key for
        // exactly as long as the pointer is on the capsule, which is the only
        // way to the real control (see OSDBannerView.track), and it hands the
        // keyboard straight back on the way out. It cannot hold key while the
        // banner is merely up, or every brightness press would take the
        // keyboard away from whatever is in front.
        if hovering {
            // Only give the keyboard back to the app it came from. Crisp is
            // its own app in front while an update window or the About box is
            // up, and deactivating on the way out would put that behind
            // whatever is next.
            crispWasActive = NSApp.isActive
            makeKey()
        } else if isKeyWindow && !crispWasActive {
            NSApp.deactivate()
        }
        OSDBannerService.shared.hoverChanged(hovering)
        fadeBadge(to: hovering)
        if hovering {
            hideWork?.cancel()
            if exiting || alphaValue < 1 { reveal(at: restFrame) }
        } else {
            scheduleHide()
        }
    }

    /// The badge fades and only fades, measured on the system HUD over a flat
    /// backdrop at 75 frames a second: 0.29 seconds in on an ease-out that is
    /// only a little faster than a straight line, and 0.35 out, which runs
    /// straight. The knob and the fill are not animated at all.
    private func fadeBadge(to shown: Bool) {
        guard let badge else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = shown ? 0.29 : 0.35
            ctx.timingFunction = shown
                ? CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
                : CAMediaTimingFunction(name: .linear)
            badge.animator().alphaValue = shown ? 1 : 0
        }
    }

    /// The close badge: the banner goes at once, on the same exit.
    func dismiss() {
        setHovering(false)
        hideWork?.cancel()
        OSDBannerService.shared.dismissed(self)
        fadeOut()
    }

    /// Keeps the backdrop sampling while the banner is up. A layer that
    /// samples what is behind it needs the screen composited, and WindowServer
    /// stops compositing a screen with nothing changing on it: the sample then
    /// has nothing in it and the capsule goes dark, and stays dark until
    /// something on screen moves. EDROverlayManager keeps its own overlay
    /// alive against the same promotion, by re-presenting at 5 fps.
    ///
    /// Holding brightness up at 100 percent is exactly the case that hits it:
    /// the level never moves, so the banner redraws nothing of its own and the
    /// screen behind it is still. An animation the eye cannot see (a
    /// thousandth of the layer's opacity) keeps the layer rendering for as
    /// long as the banner is visible, and is taken off as it goes.
    private static let keepAliveKey = "crispBannerKeepAlive"

    private func startKeepAlive() {
        for layer in [backdrop, badgeBackdrop].compactMap({ $0 })
        where layer.animation(forKey: Self.keepAliveKey) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.999
            pulse.duration = 0.25
            pulse.autoreverses = true
            pulse.repeatCount = .greatestFiniteMagnitude
            layer.add(pulse, forKey: Self.keepAliveKey)
        }
    }

    /// Opens or closes the glass: its blur, bend and tint and the content
    /// each go from wherever they are, so a press caught mid-exit turns them
    /// round.
    private func showGlass(_ shown: Bool) {
        guard let glass else { return }
        let service = OSDBannerService.self
        // The label sits where it settles from the first frame. The system
        // holds its own about 0.6 px off and brings it home late, but a
        // sub-pixel hold on a 1x screen is a whole pixel of text moving and
        // reads as a pop however it is taken back.
        for layer in glass.faded {
            Self.ramp(layer, "opacity", to: shown ? 1.0 : 0.0,
                      duration: shown ? service.glassContentInDuration : service.glassOutDuration,
                      curve: shown ? service.glassContentInCurve : service.glassOutCurve)
        }
        if shown {
            // The rim runs its own ramp on top of the window's fade, see
            // glassRimInDuration. reveal() puts it back to its start value
            // when the capsule comes from hidden, so this is a rise from
            // there on a cold entry and a catch-up from wherever it is when a
            // press lands mid-exit.
            Self.ramp(glass.rim, "opacity", to: 1.0,
                      duration: service.glassRimInDuration, curve: service.glassRimInCurve)
        } else {
            Self.ramp(glass.rim, "opacity", to: 0.0,
                      duration: service.glassRimOutDuration, curve: service.glassOutCurve)
        }
        openGlass(shown)
    }

    /// The glass view builds its layers only once its window is on screen,
    /// so on the first entry there is nothing to tune yet. It stays unseen
    /// until there is, rather than showing its own untuned look, and this
    /// tries again on the next turns of the run loop.
    private func openGlass(_ shown: Bool, attempt: Int = 0) {
        guard let glass else { return }
        let service = OSDBannerService.self
        guard let layer = glass.tunedBackdrop() else {
            if shown && attempt < 10 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.exiting else { return }
                    self.openGlass(true, attempt: attempt + 1)
                }
            }
            return
        }
        glass.view.alphaValue = 1
        if backdrop !== layer {
            backdrop = layer
            startKeepAlive()
        }
        let curve = shown ? service.glassInCurve : service.glassOutCurve
        let inTime = service.glassInDuration
        glass.ramp(layer, [
            .init("inputBlurRadius", shown ? service.glassBlurStep : service.glassBlur.closed,
                  shown ? service.glassBlurStepDuration : service.glassBlurOutDuration,
                  shown ? service.glassInCurve : curve),
            .init("inputBlurRadius", shown ? service.glassBlur.open : service.glassBlur.closed,
                  shown ? service.glassBlurRiseDuration : 0.01,
                  shown ? service.glassBlurInCurve : curve,
                  delay: shown ? service.glassBlurRiseDelay : 0.01),
            .init("inputInnerRefractionHeight",
                  shown ? service.glassRefractionHeight.open : service.glassRefractionHeight.closed,
                  shown ? service.glassRefractionHeightDuration : service.glassBendOutDuration,
                  shown ? service.glassBendInCurve : curve),
            .init("inputInnerRefractionAmount", shown ? service.glassBend.open : service.glassBend.closed,
                  shown ? service.glassBendInDuration : service.glassBendOutDuration,
                  shown ? service.glassBendInCurve : curve),
            .init("inputFaceOpacity", shown ? service.glassTint.open : service.glassTint.closed,
                  shown ? inTime : service.glassTintOutDuration, curve),
            .init("inputKeyFillHighlightAmount",
                  shown ? service.glassHighlight.open : service.glassHighlight.closed,
                  shown ? service.glassRimInDuration : service.glassRimOutDuration,
                  shown ? service.glassRimInCurve : curve)
        ] + shimmerLegs(shown: shown, curve: curve))
    }

    /// The shimmer: the backdrop samples at full resolution through the entry
    /// and steps down once the rest has settled. The exit puts it back, so the
    /// next entry starts sharp again.
    private func shimmerLegs(shown: Bool, curve: CAMediaTimingFunction) -> [OSDGlassRamp.Leg] {
        let service = OSDBannerService.self
        guard service.drawsMacOS27Capsule else { return [] }
        guard shown else {
            // Nothing on the way out. The backdrop is left where the shimmer
            // put it: sharpening it again under a capsule that is on its way
            // off reads as something popping in. The entry below sets it back
            // in its first leg, while the window is still at alpha 0.
            return []
        }
        return [
            .init("backdropScale", service.glassBackdropScale, 0.01, curve),
            .init("backdropScale", service.glassShimmerScale, service.glassShimmerDuration,
                  service.glassSettleInCurve, delay: service.glassShimmerDelay),
            .init("backdropScale", service.glassBackdropScale, service.glassShimmerReturnDuration,
                  service.glassSettleInCurve, delay: service.glassShimmerReturnDelay)
        ]
    }

    private static func ramp(_ layer: CALayer, _ keyPath: String, to value: Any,
                             duration: TimeInterval, curve: CAMediaTimingFunction) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = curve
        // Held at its end value, not removed: with the window still fading
        // out, a finished ramp coming off the glass drew a wide, untoned blur
        // for the rest of the fade. The next ramp on the key replaces it.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath)
        CATransaction.commit()
    }

    /// Leaves the window where the animations have it and lets them go.
    private func stopAnimations() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            animator().alphaValue = alphaValue
            animator().setFrame(frame, display: false)
        }
    }

    private func fadeOut() {
        exiting = true
        let service = OSDBannerService.self
        let reversed = glass != nil
        let duration = reversed ? service.glassWindowOutDuration : service.fadeOutDuration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = reversed ? service.glassWindowOutCurve : service.fadeOutCurve
            animator().alphaValue = 0
        }
        showGlass(false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reversed ? service.glassOutDuration : service.exitShrinkDuration
            ctx.timingFunction = reversed ? service.glassOutCurve : service.exitShrinkCurve
            animator().setFrame(Self.hidden(frame,
                                            inset: reversed ? service.glassExitInset : service.exitInset,
                                            lift: reversed ? service.glassExitInset.height : service.hiddenLift),
                                display: true)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.backdrop?.removeAnimation(forKey: Self.keepAliveKey)
            self?.badgeBackdrop?.removeAnimation(forKey: Self.keepAliveKey)
            // Hidden means alpha 0, not off screen, so the window is still
            // there to take a click nobody meant for it.
            self?.ignoresMouseEvents = true
            self?.model.hovering = false
            self?.badge?.alphaValue = 0
        }
        keepAliveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The hidden frame: `frame` inset and lifted. A lift of the inset height
    /// anchors the top edge, which is what the system capsule does at both
    /// ends: its top row sits on the same pixel through the grow and through
    /// the close, and only the bottom moves. macOS 26 and older keep the lift
    /// they were measured with.
    private static func hidden(_ frame: NSRect, inset: CGSize,
                               lift: CGFloat = OSDBannerService.hiddenLift) -> NSRect {
        frame.insetBy(dx: inset.width, dy: inset.height).offsetBy(dx: 0, dy: lift)
    }
}

/// Reads the pointer arriving on the banner and leaving it. SwiftUI's own
/// onHover tracks in the key window, and this panel never becomes key, so the
/// tracking area is set to be always active. It takes no clicks: hitTest
/// returns nil, so the track's drag and the close badge see them instead.
@available(macOS 26.0, *)
final class BannerHoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The capsule rim on macOS 27, where the system stopped drawing one flat
/// white line around the edge.
///
/// Measured at rest, once the capsule has settled: over backdrops of 0, 64,
/// 128, 192 and 255 the body reads 32, 75, 118, 162 and 204, and the top and
/// the bottom edge both read 102, 158, 215, 255 and 255. The two rounded ends
/// run dark instead, about 65 levels under the body, and nothing is drawn for
/// them here: the glass view's own edge already draws that (see
/// OSDBannerService.rimEdgeColor).
/// Catch the capsule before it has settled and none of that is true: at 0.9 s
/// after a single press it is still 6 pt narrow with half the rim, so the
/// measurement holds the key down (ten presses) and shoots half a second
/// after the last one.
///
/// The lift along the top and the bottom is near enough the same 85 levels on
/// every backdrop, so it goes on as an additive layer, which is also the only
/// blend that reaches the capsule at all: the body is composited by the window
/// server, so a CoreImage blend mode here has nothing under it to blend with
/// (measured: soft light drew a third of the lift it should, overlay a sixth).
///
/// It runs as one horizontal gradient over a ring mask, because the change
/// happens along the width: 40 pt in from a corner the top edge is at its full
/// value and at 20 pt it is half way.
@available(macOS 26.0, *)
final class OSDBevelView: NSView {
    /// The ring only. The glow below is not in here on purpose: the rim's
    /// entry ramp runs on this layer, and a glow that ramps with it lifts the
    /// band under the bottom edge late, which reads as the capsule's inner
    /// shadow going away at the end of the entry (see glassRefractionHeight).
    let rings = CALayer()
    private let edgeRing = CALayer()
    private let edges = CAGradientLayer()
    private let innerMask = CALayer()
    private let inner = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer else { return }
        let clear = NSColor.clear.cgColor
        // Bright along the top and the bottom, nothing at the ends, and added
        // on rather than blended over: see OSDBannerService.rimEdgeColor for
        // the pair of backdrops that tells the two apart.
        let edgeStop = OSDBannerService.rimEdgeShare
        let colour = OSDBannerService.rimEdgeColor.cgColor
        edges.colors = [clear, colour, colour, clear]
        edges.locations = [0, NSNumber(value: edgeStop), NSNumber(value: 1 - edgeStop), 1]
        edges.startPoint = CGPoint(x: 0, y: 0.5)
        edges.endPoint = CGPoint(x: 1, y: 0.5)
        edges.compositingFilter = "plusL"
        // Inside the top and the bottom edge the system keeps a short glow:
        // over a 128 backdrop the rows under the rim read 139, 130, 126 and
        // 123 against a body of 118, gone by the sixth. It is added on like
        // the edges, over the capsule rather than over the ring.
        inner.colors = [OSDBannerService.rimGlowColor.cgColor, clear,
                        clear, OSDBannerService.rimGlowColor.cgColor]
        let glow = OSDBannerService.rimGlowShare
        inner.locations = [0, NSNumber(value: glow), NSNumber(value: 1 - glow), 1]
        inner.startPoint = CGPoint(x: 0.5, y: 0)
        inner.endPoint = CGPoint(x: 0.5, y: 1)
        inner.compositingFilter = "plusL"
        innerMask.cornerRadius = OSDBannerService.cornerRadius
        innerMask.cornerCurve = .continuous
        innerMask.backgroundColor = NSColor.white.cgColor
        inner.mask = innerMask
        layer.addSublayer(inner)
        // A mask is a layer with nothing but a border, so the ring follows the
        // same continuous corner the capsule is drawn with; a path would have
        // to rebuild that curve by hand.
        edgeRing.cornerRadius = OSDBannerService.cornerRadius
        edgeRing.cornerCurve = .continuous
        edgeRing.borderColor = NSColor.white.cgColor
        edges.mask = edgeRing
        rings.addSublayer(edges)
        layer.addSublayer(rings)
        layoutRim()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutRim()
    }

    /// The window grows and shrinks through the entry and the exit, and layers
    /// do not follow a resize on their own.
    private func layoutRim() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeRing.frame = CGRect(origin: .zero, size: bounds.size)
        edgeRing.borderWidth = OSDBannerService.rimWidth
        edges.frame = CGRect(origin: .zero, size: bounds.size)
        rings.frame = CGRect(origin: .zero, size: bounds.size)
        inner.frame = CGRect(origin: .zero, size: bounds.size)
        innerMask.frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
    }
}
