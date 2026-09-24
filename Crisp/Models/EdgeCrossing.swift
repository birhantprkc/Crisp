import CoreGraphics

/// Where displays of different sizes meet, part of each shared edge has no display behind
/// it and macOS stops the pointer there. This finds the nearest point on the display beyond
/// that edge, so the pointer moves on instead of meeting a wall.
/// All rects and points are in global display coordinates (origin top left, y down).
enum EdgeCrossing {
    /// The point to warp to when the pointer at `point`, moving by `delta`, pushes against
    /// an edge that another display touches but not at the pointer's height (or width).
    /// Nil leaves the move to macOS: no push, no neighbour on that side, or the neighbour
    /// already covers the spot (macOS crosses there by itself).
    static func target(from point: CGPoint, delta: CGVector, displays: [CGRect]) -> CGPoint? {
        guard let here = displays.first(where: { $0.contains(point) }) else { return nil }
        // The pointer stops within a point of the edge, fractionally on a scaled display.
        let slack: CGFloat = 1
        var best: (point: CGPoint, slide: CGFloat)?
        func offer(_ candidate: CGPoint, slide: CGFloat) {
            if best == nil || slide < best!.slide { best = (candidate, slide) }
        }
        for other in displays where other != here {
            let y = min(max(point.y, other.minY), other.maxY - 1)
            let x = min(max(point.x, other.minX), other.maxX - 1)
            if delta.dx < 0, point.x < here.minX + slack, abs(other.maxX - here.minX) < slack {
                offer(CGPoint(x: other.maxX - 1, y: y), slide: abs(y - point.y))
            }
            if delta.dx > 0, point.x >= here.maxX - slack, abs(other.minX - here.maxX) < slack {
                offer(CGPoint(x: other.minX, y: y), slide: abs(y - point.y))
            }
            if delta.dy < 0, point.y < here.minY + slack, abs(other.maxY - here.minY) < slack {
                offer(CGPoint(x: x, y: other.maxY - 1), slide: abs(x - point.x))
            }
            if delta.dy > 0, point.y >= here.maxY - slack, abs(other.minY - here.maxY) < slack {
                offer(CGPoint(x: x, y: other.minY), slide: abs(x - point.x))
            }
        }
        guard let best, best.slide >= slack else { return nil }
        return best.point
    }
}
