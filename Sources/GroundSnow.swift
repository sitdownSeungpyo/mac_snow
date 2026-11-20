import AppKit
import SpriteKit

/// Dock top band in screen-local points (origin = bottom-left of the screen).
struct DockBand: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
    var top: CGFloat
    /// Corner radius of the Dock plate's rounded ends (snow wraps over them).
    var corner: CGFloat = 16
}

/// Heightmap of accumulated snow in two layers: the FLOOR runs across the full screen width
/// (also under the Dock, drawn behind it — it shows in the gap below the floating Dock plate and
/// through its glass), and the Dock CAP sits on the Dock's top. Snow never flows between the
/// layers except as grains pouring off the Dock's ends onto the floor.
final class GroundSnow: SKNode {
    let colWidth: CGFloat = 6
    let width: CGFloat
    private var heights: [CGFloat]
    private var base: [CGFloat]
    private var isDock: [Bool]
    /// Floor snow under the Dock plate (used for Dock columns; `heights` holds their Dock cap).
    private var floorUnder: [CGFloat]
    /// Dock plate ends (x), for the drifts that rise around its lower corners.
    private var dockEnds: (CGFloat, CGFloat)?
    private let jitter: [CGFloat]
    /// The snow layer is rendered with Core Graphics into one texture (cheap to draw every frame).
    private let sprite = SKSpriteNode()
    private let pixelScale: CGFloat
    private var dirty = true
    private var cooldown: CGFloat = 0
    private var budget: CGFloat = 0

    static let floorStart: CGFloat = 18
    static let floorMax: CGFloat = 72
    static let dockStart: CGFloat = 3     // thin clean line on the Dock (reference)
    static let dockMax: CGFloat = 6

    init(width: CGFloat, pixelScale: CGFloat) {
        self.width = width
        self.pixelScale = max(1, pixelScale)
        let n = max(2, Int(ceil(width / colWidth)) + 1)
        heights = Array(repeating: 0, count: n)
        base = Array(repeating: 0, count: n)
        isDock = Array(repeating: false, count: n)
        floorUnder = Array(repeating: 0, count: n)
        let p1 = CGFloat.random(in: 0...6.28), p2 = CGFloat.random(in: 0...6.28)
        var j: [CGFloat] = []
        for i in 0..<n {
            let fi = CGFloat(i)
            let a: CGFloat = 3 * sin(fi * 0.11 + p1)
            let b: CGFloat = 1.5 * sin(fi * 0.29 + p2)
            j.append(a + b - 4)
        }
        jitter = j
        super.init()
        sprite.anchorPoint = .zero
        addChild(sprite)
        reset()
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    var count: Int { heights.count }

    func col(_ x: CGFloat) -> Int { min(max(Int((x / colWidth).rounded()), 0), count - 1) }

    private func startHeight(_ i: Int) -> CGFloat {
        let n = 2 * sin(CGFloat(i) * 0.17) + sin(CGFloat(i) * 0.41 + 1.3)
        return max(0, (isDock[i] ? GroundSnow.dockStart : GroundSnow.floorStart) + n * (isDock[i] ? 0.5 : 1))
    }

    private func floorStartHeight(_ i: Int) -> CGFloat {
        max(0, GroundSnow.floorStart + 2 * sin(CGFloat(i) * 0.17) + sin(CGFloat(i) * 0.41 + 1.3))
    }

    /// Floor-layer snow height of column i (under the Dock: `floorUnder`).
    private func floorH(_ i: Int) -> CGFloat { isDock[i] ? floorUnder[i] : heights[i] }
    private func setFloor(_ i: Int, _ v: CGFloat) { if isDock[i] { floorUnder[i] = v } else { heights[i] = v } }

    /// A soft drift rising around the Dock plate's lower corners (drawn and physical floor).
    private func floorBump(_ i: Int) -> CGFloat {
        guard let (a, b) = dockEnds else { return 0 }
        let x = CGFloat(i) * colWidth
        let d = min(abs(x - a), abs(x - b))
        return 9 * (1 - GroundSnow.smoothstep(d / 36))
    }

    private func maxHeight(_ i: Int) -> CGFloat {
        isDock[i] ? GroundSnow.dockMax + jitter[i] * 0.4 : GroundSnow.floorMax + jitter[i]
    }

    func reset() {
        for i in 0..<count {
            heights[i] = startHeight(i)
            floorUnder[i] = isDock[i] ? floorStartHeight(i) : 0
        }
        budget = 0
        dirty = true
        cooldown = 0
    }

    private var dockCorner: CGFloat = 16
    /// A Dock was set before (a returning Dock starts with an empty cap).
    private var dockSeen = false
    /// Dock-cap snow poured to the floor because the Dock went away (diag / harness).
    private(set) var dockGoneSpill: CGFloat = 0

    func setDock(_ band: DockBand?) {
        let c = clamp(band?.corner ?? 16, 8, 26)
        if c != dockCorner { dockCorner = c; dirty = true }
        let ends = band.map { ($0.minX, $0.maxX) }
        if ends?.0 != dockEnds?.0 || ends?.1 != dockEnds?.1 { dockEnds = ends; dirty = true }
        for i in 0..<count {
            let x = CGFloat(i) * colWidth
            var onDock = false
            var newBase: CGFloat = 0
            if let b = band, x >= b.minX, x <= b.maxX {
                onDock = true
                newBase = b.top
            }
            if onDock != isDock[i] {
                // The floor snow stays continuous: a column going under the Dock keeps its floor
                // snow (behind the plate) and gets a fresh thin cap; one coming out gets it back.
                if onDock {
                    floorUnder[i] = heights[i] > 0 ? heights[i] : floorStartHeight(i)
                    isDock[i] = true
                    // A Dock that comes back starts with an empty cap and gathers snow again; the
                    // Dock seen at start-up gets its usual thin line.
                    heights[i] = dockSeen ? 0 : startHeight(i)
                } else {
                    // The Dock went away under this column (hidden / auto-hide / full screen /
                    // narrower): its cap snow pours down onto the floor as grains (volume kept).
                    if heights[i] > 0.01 {
                        dockSpill.append((CGFloat(i) * colWidth, base[i] + heights[i], heights[i] * colWidth))
                        dockGoneSpill += heights[i] * colWidth
                    }
                    isDock[i] = false
                    heights[i] = floorUnder[i] > 0 ? floorUnder[i] : startHeight(i)
                    floorUnder[i] = 0
                }
                dirty = true
            }
            if base[i] != newBase {
                base[i] = newBase
                dirty = true
            }
        }
        if band != nil { dockSeen = true }
    }

    func baseHeight(at x: CGFloat) -> CGFloat { base[col(x)] }

    /// Top of the snow (Dock top or screen bottom + accumulated snow).
    func surface(at x: CGFloat) -> CGFloat {
        let f = clamp(x / colWidth, 0, CGFloat(count - 1))
        let i = Int(f.rounded(.down))
        let j = min(i + 1, count - 1)
        let t = f - CGFloat(i)
        if isDock[i] != isDock[j] {
            let k = t < 0.5 ? i : j
            return base[k] + heights[k] + (isDock[k] ? 0 : floorBump(k))
        }
        let a = base[i] + heights[i] + (isDock[i] ? 0 : floorBump(i)), b = base[j] + heights[j] + (isDock[j] ? 0 : floorBump(j))
        return a + (b - a) * t
    }

    /// Top of the FLOOR layer at x (also under the Dock plate), including the corner drifts.
    func floorSurface(at x: CGFloat) -> CGFloat {
        let f = clamp(x / colWidth, 0, CGFloat(count - 1))
        let i = Int(f.rounded(.down)), j = min(i + 1, count - 1)
        let a = floorH(i) + floorBump(i), b = floorH(j) + floorBump(j)
        return a + (b - a) * (f - CGFloat(i))
    }

    /// True if `p` lies within the visible snow layer (not on the bare Dock). Under the Dock only
    /// the Dock cap counts: the floor behind the plate is never a click target (the Dock is on top).
    func isSnow(at p: CGPoint) -> Bool {
        let i = col(p.x)
        return heights[i] >= 2 && p.y <= base[i] + heights[i] + 2 && p.y >= base[i] - 1
    }

    func accumulate(rate: CGFloat, dt: CGFloat) {
        budget += rate * dt * CGFloat(count)
        let lump: CGFloat = 0.6
        let weights: [CGFloat] = [0.06, 0.12, 0.18, 0.28, 0.18, 0.12, 0.06]
        while budget >= lump {
            budget -= lump
            let c = Int.random(in: 0..<count)
            for (k, w) in weights.enumerated() {
                let i = c + k - 3
                guard i >= 0, i < count, isDock[i] == isDock[c] else { continue }
                let m = maxHeight(i)
                if heights[i] < m { heights[i] = min(m, heights[i] + lump * w) }
            }
            dirty = true
        }
    }

    /// Angle-of-repose relaxation so trenches and bumps soften over time.
    func relax() {
        let maxSlope: CGFloat = 3.5
        var changed = false
        // Floor layer: one continuous granular heightmap (also under the Dock, no seams).
        for i in 0..<(count - 1) {
            let a = floorH(i), b = floorH(i + 1)
            let d = a - b
            if abs(d) > maxSlope {
                let m = (abs(d) - maxSlope) * 0.25 * (d > 0 ? 1 : -1)
                setFloor(i, a - m)
                setFloor(i + 1, b + m)
                changed = true
            }
        }
        // Dock cap layer.
        for i in 0..<(count - 1) where isDock[i] && isDock[i + 1] {
            let d = heights[i] - heights[i + 1]
            if abs(d) > maxSlope {
                let m = (abs(d) - maxSlope) * 0.25 * (d > 0 ? 1 : -1)
                heights[i] -= m
                heights[i + 1] += m
                changed = true
            }
        }
        // Dock ends: no support past the plate — snow above `dockEdgeHold` at an end column pours
        // off onto the floor as falling grains (taken by the scene with `takeDockSpill`).
        for i in 0..<count where isDock[i] {
            let leftEnd = i == 0 || !isDock[i - 1], rightEnd = i == count - 1 || !isDock[i + 1]
            guard leftEnd || rightEnd, heights[i] > GroundSnow.dockEdgeHold else { continue }
            let m = (heights[i] - GroundSnow.dockEdgeHold) * 0.25
            guard m > 0.002 else { continue }
            heights[i] -= m
            let x = CGFloat(i) * colWidth + (leftEnd ? -colWidth * 0.5 : colWidth * 0.5)
            dockSpill.append((x, base[i] + heights[i], m * colWidth))
            changed = true
        }
        if changed { dirty = true }
    }

    static let dockEdgeHold: CGFloat = 1.4
    private var dockSpill: [(x: CGFloat, y: CGFloat, area: CGFloat)] = []
    /// Snow that poured off the Dock ends since the last call (x, y of the plate edge, area pt²).
    func takeDockSpill() -> [(x: CGFloat, y: CGFloat, area: CGFloat)] {
        guard !dockSpill.isEmpty else { return [] }
        defer { dockSpill.removeAll(keepingCapacity: true) }
        return dockSpill
    }

    /// Removes up to `depth` from each column under [centerX ± halfWidth]; returns removed area (pt²).
    func remove(centerX: CGFloat, halfWidth: CGFloat, depth: CGFloat) -> CGFloat {
        let lo = col(centerX - halfWidth), hi = col(centerX + halfWidth)
        let dock = isDock[col(centerX)]
        var removed: CGFloat = 0
        for i in lo...hi where isDock[i] == dock {
            let take = min(depth, heights[i])
            if take > 0 {
                heights[i] -= take
                removed += take * colWidth
            }
        }
        if removed > 0 {
            dirty = true
            cooldown = 0
        }
        return removed
    }

    /// Scrapes the columns under a plow blade at x down to `keep` pt; returns the area (pt²).
    @discardableResult
    func scrape(at x: CGFloat, dir: CGFloat, keep: CGFloat, maxArea: CGFloat) -> CGFloat {
        guard x.isFinite, dir.isFinite, maxArea > 0 else { return 0 }
        let c = col(x)
        var area: CGFloat = 0
        for i in [c, c - Int(dir)] where i >= 0 && i < count && isDock[i] == isDock[c] {
            let take = min(max(0, heights[i] - keep) * 0.5, (maxArea - area) / colWidth)
            guard take > 0 else { continue }
            heights[i] -= take
            area += take * colWidth
        }
        if area > 0 { dirty = true; cooldown = min(cooldown, 0.1) }
        return area
    }

    /// Like `scrape`, on the floor layer (also behind the Dock): the plow never climbs the Dock.
    @discardableResult
    func scrapeFloor(at x: CGFloat, dir: CGFloat, keep: CGFloat, maxArea: CGFloat) -> CGFloat {
        guard x.isFinite, dir.isFinite, maxArea > 0 else { return 0 }
        let c = col(x)
        var area: CGFloat = 0
        for i in [c, c - Int(dir)] where i >= 0 && i < count {
            let take = min(max(0, floorH(i) - keep) * 0.5, (maxArea - area) / colWidth)
            guard take > 0 else { continue }
            setFloor(i, floorH(i) - take)
            area += take * colWidth
        }
        if area > 0 { dirty = true; cooldown = min(cooldown, 0.1) }
        return area
    }

    /// Like `depositDrift`, on the floor layer (a mound behind the Dock settles by the floor's
    /// angle of repose like anywhere else).
    func depositDriftFloor(fromX x: CGFloat, dir: CGFloat, length: CGFloat, area: CGFloat) {
        guard x.isFinite, length > 1, area > 0 else { return }
        let n = max(2, Int(length / colWidth))
        var weights: [CGFloat] = []
        for k in 0..<n { weights.append(pow(1 - CGFloat(k) / CGFloat(n), 1.5)) }
        let total = weights.reduce(0, +)
        let c0 = col(x)
        var placed: CGFloat = 0
        for (k, wgt) in weights.enumerated() {
            let i = c0 + Int(dir) * k
            guard i >= 0, i < count else { continue }
            setFloor(i, floorH(i) + area * wgt / total / colWidth)
            placed += area * wgt / total
        }
        if placed < area { setFloor(c0, floorH(c0) + (area - placed) / colWidth) }   // (off-screen part)
        dirty = true
    }

    /// Floor + Dock-cap volume (pt²), harness accounting.
    var floorVolume: CGFloat { (0..<count).reduce(0) { $0 + floorH($1) } * colWidth }
    var dockCapVolume: CGFloat { (0..<count).filter { isDock[$0] }.reduce(0) { $0 + heights[$1] } * colWidth }

    /// Lays a plow drift down as a mound: `area` pt² along [x, x + dir·length] with the drift's
    /// wedge profile (tallest at the blade). Relaxation then lets it settle slowly.
    func depositDrift(fromX x: CGFloat, dir: CGFloat, length: CGFloat, area: CGFloat) {
        guard x.isFinite, length > 1, area > 0 else { return }
        let n = max(2, Int(length / colWidth))
        var weights: [CGFloat] = []
        for k in 0..<n { weights.append(pow(1 - CGFloat(k) / CGFloat(n), 1.5)) }
        let total = weights.reduce(0, +)
        let c0 = col(x)
        for (k, wgt) in weights.enumerated() {
            let i = c0 + Int(dir) * k
            guard i >= 0, i < count, isDock[i] == isDock[c0] else { continue }
            heights[i] = min(maxHeight(i) + 40, heights[i] + area * wgt / total / colWidth)
        }
        dirty = true
    }

    /// Adds `area` pt² of snow around x (a clump that fell off a window landed here).
    func deposit(centerX: CGFloat, area: CGFloat) {
        guard centerX.isFinite, area.isFinite, area > 0 else { return }
        let c = col(centerX)
        let per = area / colWidth
        for (k, w) in [CGFloat(0.2), 0.6, 0.2].enumerated() {
            let i = c + k - 1
            guard i >= 0, i < count, isDock[i] == isDock[c] else { continue }
            heights[i] = min(maxHeight(i), heights[i] + per * w)
        }
        dirty = true
    }

    func update(dt: CGFloat) {
        cooldown -= dt
        guard dirty, cooldown <= 0 else { return }
        dirty = false
        // Slow accumulation redraws a few times per second; remove() forces an immediate redraw.
        cooldown = 1.0
        rebuild()
    }

    private func rebuild() {
        // The floor first (full width, continuous — under the Dock it is drawn behind the plate),
        // then each Dock cap segment on the plate's top.
        var segments: [(fill: CGMutablePath, rim: CGMutablePath, bottom: CGFloat, top: CGFloat, extras: [CGPath])] = [floorSegment()]
        var start = 0
        while start < count {
            var end = start
            while end + 1 < count && isDock[end + 1] == isDock[start] && base[end + 1] == base[start] { end += 1 }
            if isDock[start] { segments.append(segment(start, end)) }
            start = end + 1
        }
        let maxTop = segments.map { $0.top }.max() ?? 0
        let pad: CGFloat = 3
        let heightPts = ceil(maxTop + pad + 4)
        let wpx = Int(ceil(width * pixelScale)), hpx = Int(ceil(heightPts * pixelScale))
        guard wpx > 0, hpx > 0,
              let ctx = CGContext(data: nil, width: wpx, height: hpx, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        ctx.translateBy(x: 0, y: pad)
        let colors = [rgb(0.80, 0.87, 0.97).cgColor, rgb(0.94, 0.96, 1).cgColor, rgb(1, 1, 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])
        for seg in segments {
            for extra in seg.extras {        // rounded lumps wrapping the Dock's ends (drawn first)
                ctx.saveGState()
                ctx.addPath(extra)
                ctx.clip()
                if let gradient {
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: seg.bottom - dockCorner), end: CGPoint(x: 0, y: seg.top),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.addPath(seg.fill)
            ctx.clip()
            if let gradient {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: seg.bottom), end: CGPoint(x: 0, y: max(seg.top, seg.bottom + 8)),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
            ctx.addPath(seg.rim)
            ctx.setStrokeColor(rgb(0.86, 0.91, 1, 0.9).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
        guard let img = ctx.makeImage() else { return }
        sprite.texture = SKTexture(cgImage: img)
        sprite.size = CGSize(width: width, height: heightPts)
        sprite.position = CGPoint(x: 0, y: -pad)
    }

    private static func smoothstep(_ x: CGFloat) -> CGFloat { let t = clamp(x, 0, 1); return t * t * (3 - 2 * t) }

    /// Drawn (not physical) height of a Dock cap column: it thins toward the plate's rounded ends.
    private func drawnHeight(_ i: Int, _ a: Int, _ b: Int, left: CGFloat, right: CGFloat) -> CGFloat {
        let x = CGFloat(i) * colWidth
        let d = min(x - left, right - x)
        return heights[i] * (0.3 + 0.7 * GroundSnow.smoothstep(d / (dockCorner * 1.3)))
    }

    /// The continuous floor across the whole width, with drifts around the Dock's lower corners.
    private func floorSegment() -> (fill: CGMutablePath, rim: CGMutablePath, bottom: CGFloat, top: CGFloat, extras: [CGPath]) {
        let fill = CGMutablePath(), rim = CGMutablePath()
        let bottom: CGFloat = -3
        var top: [CGPoint] = [CGPoint(x: 0, y: floorH(0) + floorBump(0))]
        for i in 0..<count { top.append(CGPoint(x: min(width, CGFloat(i) * colWidth), y: floorH(i) + floorBump(i))) }
        top.append(CGPoint(x: width, y: floorH(count - 1) + floorBump(count - 1)))
        fill.move(to: CGPoint(x: 0, y: bottom))
        fill.addLine(to: top[0])
        rim.move(to: top[0])
        for k in 1..<(top.count - 1) {
            let mid = CGPoint(x: (top[k].x + top[k + 1].x) / 2, y: (top[k].y + top[k + 1].y) / 2)
            fill.addQuadCurve(to: mid, control: top[k])
            rim.addQuadCurve(to: mid, control: top[k])
        }
        fill.addLine(to: top[top.count - 1])
        rim.addLine(to: top[top.count - 1])
        fill.addLine(to: CGPoint(x: width, y: bottom))
        fill.closeSubpath()
        return (fill, rim, bottom, top.map { $0.y }.max() ?? bottom, [])
    }

    private func segment(_ a: Int, _ b: Int) -> (fill: CGMutablePath, rim: CGMutablePath, bottom: CGFloat, top: CGFloat, extras: [CGPath]) {
        let fill = CGMutablePath()
        let rim = CGMutablePath()
        let left = max(0, CGFloat(a) * colWidth - colWidth / 2)
        let right = min(width, CGFloat(b) * colWidth + colWidth / 2)
        let bottom = base[a] - (isDock[a] ? 1 : 3)
        let h = { (i: Int) in self.drawnHeight(i, a, b, left: left, right: right) }
        var top: [CGPoint] = [CGPoint(x: left, y: base[a] + h(a) * (isDock[a] ? 1 : 0.6))]
        for i in a...b { top.append(CGPoint(x: CGFloat(i) * colWidth, y: base[i] + h(i))) }
        top.append(CGPoint(x: right, y: base[b] + h(b) * (isDock[b] ? 1 : 0.6)))
        // Dock ends: a rounded lump wraps each end and droops over the plate's rounded corner.
        var extras: [CGPath] = []
        if isDock[a] && b > a {
            let r = dockCorner
            for (x, end, dir) in [(left, a, CGFloat(1)), (right, b, CGFloat(-1))] {
                let hEnd = max(drawnHeight(end, a, b, left: left, right: right), 0.8)
                // A thin sliver that wraps down the plate's rounded corner and tapers to nothing.
                let cx = x + dir * r, cy = base[end] - r
                let sliver = CGMutablePath()
                let steps = 10
                var outer: [CGPoint] = [], inner: [CGPoint] = []
                for k in 0...steps {
                    let u = CGFloat(k) / CGFloat(steps)
                    let ang = CGFloat.pi / 2 + dir * u * CGFloat.pi * 0.3     // from the top, 54° around the corner
                    let t = hEnd * (1 - u) * (1 - u)
                    outer.append(CGPoint(x: cx + cos(ang) * (r + t), y: cy + sin(ang) * (r + t)))
                    inner.append(CGPoint(x: cx + cos(ang) * (r - 0.3), y: cy + sin(ang) * (r - 0.3)))
                }
                sliver.addLines(between: outer + inner.reversed())
                sliver.closeSubpath()
                extras.append(sliver)
                // Excess snow forms a small lump hanging a little over the edge.
                if hEnd > r * 0.45 {
                    let s = min(r * 0.4, (hEnd - r * 0.45) * 0.6 + 3)
                    extras.append(CGPath(ellipseIn: CGRect(x: x - dir * s * 0.2 - s, y: base[end] - r * 0.45 - s * 0.6,
                                                           width: 2 * s, height: 1.7 * s), transform: nil))
                }
            }
        }

        fill.move(to: CGPoint(x: left, y: bottom))
        fill.addLine(to: top[0])
        rim.move(to: top[0])
        if top.count > 2 {
            for k in 1..<(top.count - 1) {
                let mid = CGPoint(x: (top[k].x + top[k + 1].x) / 2, y: (top[k].y + top[k + 1].y) / 2)
                fill.addQuadCurve(to: mid, control: top[k])
                rim.addQuadCurve(to: mid, control: top[k])
            }
        }
        fill.addLine(to: top[top.count - 1])
        rim.addLine(to: top[top.count - 1])
        fill.addLine(to: CGPoint(x: right, y: bottom))
        fill.closeSubpath()
        let maxY = top.map { $0.y }.max() ?? bottom
        return (fill, rim, bottom, maxY, extras)
    }
}
