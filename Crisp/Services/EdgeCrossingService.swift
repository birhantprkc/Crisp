import AppKit
import CoreGraphics

/// Moves the pointer past the part of a shared display edge that has no display behind it
/// (see EdgeCrossing). A global mouse monitor needs no Accessibility grant, unlike a key tap.
@MainActor
final class EdgeCrossingService {
    static let shared = EdgeCrossingService()
    private init() {}

    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var displayBounds: [CGRect] = []

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard monitors.isEmpty else { return }
        refreshBounds()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBounds() }
        }
        // ponytail: plain moves only; a warp in the middle of a window drag is untested.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        // The global monitor misses moves over Crisp's own panel.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func refreshBounds() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displayBounds = ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    private func handle(_ event: NSEvent) {
        guard displayBounds.count > 1, let cgEvent = event.cgEvent else { return }
        let delta = CGVector(dx: cgEvent.getDoubleValueField(.mouseEventDeltaX),
                             dy: cgEvent.getDoubleValueField(.mouseEventDeltaY))
        guard let target = EdgeCrossing.target(from: cgEvent.location, delta: delta, displays: displayBounds)
        else { return }
        // A warp holds back hardware input for 0.25 s by default, which reads as a stuck
        // pointer; CGAssociateMouseAndMouseCursorPosition does not lift it on macOS 27.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(target)
    }
}
