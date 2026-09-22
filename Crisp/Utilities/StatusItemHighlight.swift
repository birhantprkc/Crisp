import AppKit

/// The lit pill behind Crisp's menu bar icon while the panel or the banner is
/// up. macOS 26 and older get `NSStatusBarButton.highlight(_:)`, which paints
/// nothing on macOS 27, so there the pill is drawn here.
///
/// The shape is the system's own, measured against a native item carrying the
/// same symbol with its menu open: a plain capsule, corner radius half its
/// height, inset 3 pt from the top and the bottom of the menu bar, and 2 pt
/// wider than the item on each side.
///
/// It is drawn in the button's own layer. A window of its own over the menu
/// bar shows up in a screen capture but not on the display, so that is not an
/// option. The item's window clips at the item's edge, which
/// would cost the pill those 2 pt on each side and cut the widest rows off the
/// arc, so the window is widened by that much first.
///
/// It is added on rather than blended over. The system pill lifts the bar by a
/// flat amount in all three channels, where a white at any alpha would lift
/// the three by different amounts. Adding commutes, so the layer draws in
/// front of the icon what the system draws behind it.
enum StatusItemHighlight {
    /// How far the pill stays from the menu bar's top and bottom edge, and how
    /// far it runs past the item on each side.
    private static let barInset: CGFloat = 3
    private static let overhang: CGFloat = 2

    /// How much the pill lifts the bar, in levels, measured off a native item
    /// with its menu open on the same bar: 10, 11, 11 in the three channels.
    private static let lift: CGFloat = 11

    @MainActor
    static func apply(_ lit: Bool, to button: NSStatusBarButton?) {
        guard let button else { return }
        guard SystemLook.isMacOS27OrLater else {
            button.highlight(lit)
            return
        }
        draw(lit, on: button)
    }

    /// True while the pointer is over the item, taken as its whole window,
    /// which is the area a press on the item lands in. The button's own rect
    /// is not the same: it sits 2 pt above the menu bar and stops 4 pt short of
    /// the window's bottom edge.
    @MainActor
    static func isPointerOver(_ button: NSStatusBarButton?) -> Bool {
        guard let window = button?.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    @MainActor
    private static func draw(_ lit: Bool, on button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let host = button.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard lit, let frame = frame(in: button) else {
            pill(in: host)?.removeFromSuperlayer()
            return
        }
        let layer = pill(in: host) ?? add(to: host)
        layer.frame = frame
        layer.cornerRadius = frame.height / 2
    }

    /// The pill in the button's own coordinates, after making room for it.
    /// Taken from the menu bar rather than from the button, since the two are
    /// not the same height and a bar with a notch above it is taller again.
    @MainActor
    private static func frame(in button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window, let screen = window.screen else { return nil }
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard barHeight > 2 * barInset else { return nil }
        let height = barHeight - 2 * barInset
        let buttonTop = window.convertToScreen(button.convert(button.bounds, to: nil)).maxY
        let top = buttonTop - (screen.frame.maxY - barInset)
        return CGRect(x: 0,
                      y: button.layer?.isGeometryFlipped == true ? top : button.bounds.height - top - height,
                      width: button.bounds.width,
                      height: height)
    }

    /// Widens the item's window by the overhang on each side, once, and gives
    /// the button the new width. The item's length stays what it was, so the
    /// icon keeps a native item's spacing in the bar. Called at setup, before
    /// the item is ever lit: widening it moves the icon 2 pt, which must not
    /// happen on the first click.
    @MainActor
    static func makeRoom(for button: NSStatusBarButton?) {
        guard SystemLook.isMacOS27OrLater, let button, let window = button.window else { return }
        guard button.bounds.width < window.frame.width || widened != window.frame.width else { return }
        var frame = window.frame
        frame.origin.x -= overhang
        frame.size.width += 2 * overhang
        window.setFrame(frame, display: false)
        widened = frame.width
        button.frame = NSRect(x: 0, y: button.frame.minY, width: frame.width, height: button.frame.height)
    }

    /// The widened window width, so the widening happens once per layout.
    @MainActor private static var widened: CGFloat = 0

    private static let name = "crisp.statusItemHighlight"

    private static func pill(in host: CALayer) -> CALayer? {
        host.sublayers?.first { $0.name == name }
    }

    private static func add(to host: CALayer) -> CALayer {
        let layer = CALayer()
        layer.name = name
        layer.backgroundColor = NSColor(white: 1, alpha: lift / 255).cgColor
        layer.compositingFilter = "plusL"
        host.addSublayer(layer)
        return layer
    }
}
