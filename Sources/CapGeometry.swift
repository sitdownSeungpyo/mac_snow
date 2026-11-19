import CoreGraphics

/// Geometry of a per-window "cap window": a small transparent window ordered directly above an
/// app window, covering that window's top strip (snow line, riders, overhang). Pure math, shared
/// by the app and the standalone spike, unit-tested offscreen.
///
/// Coordinates: CG global (top-left origin, y down) as SkyLight/CGWindowList report window
/// bounds; Cocoa global (bottom-left origin of the primary screen, y up) for AppKit.
enum CapGeometry {
    /// Overhang past the window's left/right edges (corner snow, ball overhang).
    static let side: CGFloat = 12
    /// Room above the window's top edge: a ~45pt snowman with hat, light sag and the strip.
    static let above: CGFloat = 70
    /// Room below the top edge for the strip's soft shadow.
    static let below: CGFloat = 8
    /// Room below the edge when the window has a garland (sagging wire, bulbs and glow).
    static let garlandBelow: CGFloat = 56

    /// Largest room above the edge (a tall stack of big balls); the cap grows only as needed.
    static let maxAbove: CGFloat = 240

    /// Room inside a cap window left / right of the overhang. An edge drag (resize) never moves
    /// or rescales the cap (see `CapMover.originX`): the strip's ends move inside this room.
    static let leftRoom: CGFloat = 240
    static let rightRoom: CGFloat = 240

    /// A new cap window's frame (CG global) with that room on both sides.
    static func roomyFrameCG(target t: CGRect, above a: CGFloat = above, below b: CGFloat = below) -> CGRect {
        CGRect(x: t.minX - side - leftRoom, y: t.minY - a, width: t.width + 2 * side + leftRoom + rightRoom, height: a + b)
    }

    /// Width of a cap at global x `x` showing the target's right overhang (`targetMaxX` + side):
    /// unchanged while it fits, else grown with `rightRoom` to spare (a size-only change).
    static func coverWidth(current w: CGFloat, capX x: CGFloat, targetMaxX m: CGFloat) -> CGFloat {
        let need = m + side - x
        return need <= w ? w : (need + rightRoom).rounded(.up)
    }

    /// Room left of the overhang below which a widening left edge makes the cap grow to the left.
    static let leftLowWater: CGFloat = 80

    /// New x for a cap at `x` whose target's left edge is at `minX` (same coordinates), or nil
    /// while the room left of the overhang is ≥ `leftLowWater`. Grows back to `leftRoom`.
    static func leftGrowth(capX x: CGFloat, targetMinX m: CGFloat) -> CGFloat? {
        m - side - x >= leftLowWater ? nil : (m - side - leftRoom).rounded(.down)
    }

    /// Cap window frame in CG global coordinates for a target window frame (CG global).
    static func capFrameCG(target t: CGRect, above a: CGFloat = above, below b: CGFloat = below) -> CGRect {
        CGRect(x: t.minX - side, y: t.minY - a, width: t.width + 2 * side, height: a + b)
    }

    /// Top-left origin (CG global) to pass to a window move for a target at `t` (CG global).
    static func capOriginCG(target t: CGRect, above a: CGFloat = above) -> CGPoint {
        CGPoint(x: t.minX - side, y: t.minY - a)
    }

    /// Room above the edge needed for riders reaching `riderTop` pt above it (10pt headroom,
    /// rounded up to 10pt steps so the cap is not resized for every pixel of growth).
    static func neededAbove(riderTop: CGFloat) -> CGFloat {
        guard riderTop.isFinite else { return above }
        return min(maxAbove, max(above, ((riderTop + 10) / 10).rounded(.up) * 10))
    }

    /// Position of the world node inside a cap scene so that children keep OVERLAY-SCENE
    /// coordinates: the cap's content origin (bottom-left) is the target's top-left corner shifted
    /// by (-side, -below). `target` is the target frame in overlay-scene coordinates (Cocoa, y up).
    static func worldOffset(targetInScene t: CGRect, below b: CGFloat = below) -> CGPoint {
        CGPoint(x: -(t.minX - side), y: -(t.maxY - b))
    }

    /// CG global rect -> Cocoa global rect (`primaryHeight` = height of the primary screen).
    static func cocoa(fromCG r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Cocoa global rect -> CG global rect.
    static func cg(fromCocoa r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// The target window's top edge inside the cap window's own (bottom-left, y up) content
    /// coordinates: the strip and the riders sit on this line.
    static var edgeY: CGFloat { below }

    /// A point in the full-screen overlay scene (screen-local Cocoa coordinates of the screen whose
    /// global Cocoa frame is `screenFrame`) -> the cap window's content coordinates, for a cap whose
    /// global Cocoa frame is `capFrame`. Used when a rider is handed from the overlay to a cap.
    static func capLocal(fromScene p: CGPoint, screenFrame: CGRect, capFrame: CGRect) -> CGPoint {
        CGPoint(x: p.x + screenFrame.minX - capFrame.minX, y: p.y + screenFrame.minY - capFrame.minY)
    }

    /// Inverse of `capLocal`: a cap-content point -> overlay scene point (rider dragged off).
    static func scene(fromCapLocal p: CGPoint, screenFrame: CGRect, capFrame: CGRect) -> CGPoint {
        CGPoint(x: p.x + capFrame.minX - screenFrame.minX, y: p.y + capFrame.minY - screenFrame.minY)
    }

    /// Mouse hit rect (cap-content coordinates) for a rider drawn as a circle: exactly its visible
    /// bounding box, never padded, so a cap window never takes clicks outside a rider.
    static func riderHitRect(center c: CGPoint, radius r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }

    /// The part of `cap` not covered by `occluders`, as disjoint rectangles (vertical slabs between
    /// occluder edges, merged when neighbouring slabs have the same visible intervals).
    /// nil = nothing intersects (no masking needed); [] = fully covered.
    static func visibleRects(cap c: CGRect, occluders: [CGRect]) -> [CGRect]? {
        let occ = occluders.map { $0.intersection(c) }.filter { !$0.isNull && $0.width > 0.5 && $0.height > 0.5 }
        guard !occ.isEmpty else { return nil }
        var xs = Set<CGFloat>([c.minX, c.maxX])
        for o in occ { xs.insert(o.minX); xs.insert(o.maxX) }
        let edges = xs.sorted()
        var out: [CGRect] = []
        var prev: (x0: CGFloat, intervals: [ClosedRange<CGFloat>])?
        func flush(upTo x1: CGFloat) {
            guard let p = prev else { return }
            for iv in p.intervals { out.append(CGRect(x: p.x0, y: iv.lowerBound, width: x1 - p.x0, height: iv.upperBound - iv.lowerBound)) }
        }
        for k in 0..<(edges.count - 1) {
            let x0 = edges[k], x1 = edges[k + 1]
            guard x1 - x0 > 0.01 else { continue }
            // Occluders spanning this whole slab (slab bounds include every occluder edge).
            let covered = occ.filter { $0.minX <= x0 + 0.01 && $0.maxX >= x1 - 0.01 }.map { $0.minY...$0.maxY }.sorted { $0.lowerBound < $1.lowerBound }
            var visible: [ClosedRange<CGFloat>] = []
            var y = c.minY
            for iv in covered {
                if iv.lowerBound > y + 0.01 { visible.append(y...iv.lowerBound) }
                y = max(y, iv.upperBound)
            }
            if c.maxY > y + 0.01 { visible.append(y...c.maxY) }
            if let p = prev, p.intervals == visible { continue }        // same as the slab to the left: extend it
            flush(upTo: x0)
            prev = (x0, visible)
        }
        flush(upTo: c.maxX)
        return out
    }

    /// Whether a point (cap-content coordinates) hits a rider circle (no padding).
    static func hitsRider(_ p: CGPoint, center c: CGPoint, radius r: CGFloat) -> Bool {
        (p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y) <= r * r
    }
}
