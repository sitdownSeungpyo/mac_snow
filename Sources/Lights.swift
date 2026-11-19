import AppKit
import SpriteKit

enum LightStyle: Int, CaseIterable {
    case multicolor, warmWhite
    var title: String { self == .multicolor ? "Multicolor" : "Warm White" }
}

/// Pre-rendered light textures (no per-frame shape tessellation).
enum LightTextures {
    static let warm = rgb(1, 0.86, 0.6)
    static let palette: [NSColor] = [rgb(1, 0.22, 0.22), rgb(0.25, 0.95, 0.4), rgb(0.3, 0.55, 1), rgb(1, 0.76, 0.2), warm]
    static let lanternGlow = rgb(1, 0.62, 0.22)

    static let glow: SKTexture = Textures.make(width: 64, height: 64) { ctx in
        let colors = [rgb(1, 1, 1, 0.9).cgColor, rgb(1, 1, 1, 0.28).cgColor, rgb(1, 1, 1, 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 1]) {
            let c = CGPoint(x: 32, y: 32)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 32, options: [])
        }
    }

    static let teardrop = bulb(round: false)
    static let roundBulb = bulb(round: true)

    /// White bulb (tinted per sprite so all bulbs share a texture and batch). 20x28 px (drawn at 2x).
    private static func bulb(round: Bool) -> SKTexture {
        Textures.make(width: 20, height: 28) { ctx in
            let body = CGMutablePath()
            if round {
                body.addEllipse(in: CGRect(x: 3, y: 3, width: 14, height: 17))
            } else {
                body.move(to: P(10, 1))
                body.addCurve(to: P(10, 21), control1: P(19, 8), control2: P(17, 21))
                body.addCurve(to: P(10, 1), control1: P(3, 21), control2: P(1, 8))
                body.closeSubpath()
            }
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            let colors = [rgb(1, 1, 1).cgColor, rgb(0.78, 0.78, 0.78).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: P(8, 13), startRadius: 0, endCenter: P(10, 11), endRadius: 11,
                                       options: [.drawsAfterEndLocation])
            }
            ctx.restoreGState()
            ctx.setFillColor(rgb(0.15, 0.15, 0.15).cgColor)
            ctx.fill(CGRect(x: 6.5, y: 20, width: 7, height: 8))
        }
    }

    /// Small amber paper lantern. 24x36 px (drawn at 2x).
    static let lantern: SKTexture = Textures.make(width: 24, height: 36) { ctx in
        let dark = rgb(0.25, 0.12, 0.06).cgColor
        ctx.setFillColor(dark)
        ctx.fill(CGRect(x: 7, y: 28, width: 10, height: 4))
        ctx.fill(CGRect(x: 8, y: 2, width: 8, height: 4))
        ctx.setStrokeColor(dark)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: 9, y: 31, width: 6, height: 5))
        let body = CGPath(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 24), cornerWidth: 8, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let colors = [rgb(1, 0.93, 0.6).cgColor, rgb(1, 0.6, 0.18).cgColor, rgb(0.8, 0.3, 0.08).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: P(12, 17), startRadius: 0, endCenter: P(12, 17), endRadius: 14,
                                   options: [.drawsAfterEndLocation])
        }
        ctx.setStrokeColor(rgb(0.75, 0.32, 0.08, 0.6).cgColor)
        ctx.setLineWidth(1)
        for x in [CGFloat(8), 12, 16] {
            ctx.move(to: P(x, 5))
            ctx.addLine(to: P(x, 29))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

private struct Anchor {
    let window: Int
    let fx: CGFloat   // 0 = left corner, 1 = right corner along the window's top edge
}

private final class Bulb {
    let sprite: SKSpriteNode
    let glow: SKSpriteNode
    let t: CGFloat
    let lantern: Bool
    let phase: CGFloat
    var sparkle: CGFloat = 0

    init(sprite: SKSpriteNode, glow: SKSpriteNode, t: CGFloat, lantern: Bool) {
        self.sprite = sprite
        self.glow = glow
        self.t = t
        self.lantern = lantern
        phase = CGFloat.random(in: 0...(2 * .pi))
    }
}

/// One sagging wire with bulbs. Midpoint follows a damped spring so it swings when anchors move.
private final class Strand {
    let a: Anchor
    let b: Anchor
    let sag: CGFloat
    let depth: Int        // windows with order < depth (other than anchors) occlude this strand
    var bulbs: [Bulb] = []
    var wires: [SKSpriteNode] = []
    var off = CGVector.zero
    var offVel = CGVector.zero
    var prevMid: CGPoint?
    let swayPhase = CGFloat.random(in: 0...(2 * .pi))
    /// Set for strands the user created (deletable in Light Edit mode).
    let link: UserLink?
    /// 0 = hidden (an anchor window is moving), 1 = fully shown.
    var fade: CGFloat = 1
    var dropping = false
    var lastP0: CGPoint?
    var lastP1: CGPoint?

    init(a: Anchor, b: Anchor, sag: CGFloat, depth: Int, link: UserLink?) {
        self.a = a
        self.b = b
        self.sag = sag
        self.depth = depth
        self.link = link
    }
}

/// Christmas string lights between nearby windows and garlands along window tops.
final class StringLights: SKNode {
    static let maxBulbs = 150
    static let maxStrands = 40
    static let fadeOutTime: CGFloat = 0.3    // s, lights drop and fade when their window is grabbed
    static let fadeInTime: CGFloat = 0.5     // s, lights return after the window settles
    /// Windows that are moving / not yet settled: strands anchored to them drop and fade out.
    var suppressed = Set<Int>()
    /// Windows with a cap window: their garland lives there (no fake occlusion, no drop on move).
    var capped = Set<Int>()
    /// Twinkle update interval in frames (3 = 20Hz; 6 on battery / Low Power Mode).
    var twinkleEvery = 3
    var style: LightStyle = .multicolor {
        didSet { if style != oldValue { signature = "" } }
    }
    private var strands: [Strand] = []
    private var signature = ""
    private var frameCount = 0

    func clear() {
        removeStrandNodes()
        removeAllChildren()
        strands.removeAll()
        signature = ""
    }

    /// Bulbs and wires may live in a cap window (garlands): remove them wherever they are.
    private func removeStrandNodes() {
        for st in strands {
            for b in st.bulbs { b.sprite.removeFromParent(); b.glow.removeFromParent() }
            for w in st.wires { w.removeFromParent() }
        }
    }

    /// Nodes of each window's own garland (strands from a window to itself), by window id.
    func garlandNodes() -> [Int: [SKNode]] {
        var out: [Int: [SKNode]] = [:]
        for st in strands where st.a.window == st.b.window {
            var nodes: [SKNode] = []
            for b in st.bulbs { nodes.append(b.glow); nodes.append(b.sprite) }
            nodes += st.wires
            out[st.a.window, default: []] += nodes
        }
        return out
    }

    static func point(_ w: AppWindow, _ fx: CGFloat) -> CGPoint {
        CGPoint(x: w.frame.minX + 3 + fx * (w.frame.width - 6), y: w.frame.maxY - 1)
    }

    static func covered(_ p: CGPoint, by w: AppWindow, in windows: [AppWindow]) -> Bool {
        windows.contains { $0.order < w.order && $0.frame.contains(p) }
    }

    /// Fraction of a window's top edge hidden behind front windows.
    private static func coverage(of w: AppWindow, in windows: [AppWindow]) -> CGFloat {
        let n = 12
        var hidden = 0
        for i in 0..<n {
            let p = CGPoint(x: w.frame.minX + (CGFloat(i) + 0.5) / CGFloat(n) * w.frame.width, y: w.frame.maxY - 2)
            if covered(p, by: w, in: windows) { hidden += 1 }
        }
        return CGFloat(hidden) / CGFloat(n)
    }

    /// Rebuilds strands when the set of window pairs / garlands changes.
    /// Lights are only built where they can be seen (mostly covered windows get none).
    /// `userLinks` come first (always built while both windows exist); `autoPairs` adds the
    /// automatic strands between nearby windows; `garlands` adds each window's own garland.
    func sync(windows: [AppWindow], userLinks: [UserLink] = [], autoPairs: Bool = true, garlands: Bool = true) {
        var specs: [(Anchor, Anchor, CGFloat, Int, UserLink?)] = []
        var sig = "\(style.rawValue)|"
        var budget = StringLights.maxBulbs
        let byWindow = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for link in userLinks.prefix(LightLinkStore.maxLinks) {
            guard let wa = byWindow[link.a.window], let wb = byWindow[link.b.window] else { continue }
            let p0 = StringLights.point(wa, link.a.kind.fx), p1 = StringLights.point(wb, link.b.kind.fx)
            let chord = hypot(p1.x - p0.x, p1.y - p0.y)
            guard chord.isFinite else { continue }
            let count = min(30, max(3, Int(chord / 30)))
            guard count <= budget else { continue }
            budget -= count
            specs.append((Anchor(window: wa.id, fx: link.a.kind.fx), Anchor(window: wb.id, fx: link.b.kind.fx),
                          min(90, 18 + chord * 0.12), min(wa.order, wb.order), link))
            sig += "u\(wa.id).\(link.a.kind.rawValue)-\(wb.id).\(link.b.kind.rawValue)-\(count);"
        }

        // Strands between nearby windows: A's top-right corner to B's top-left corner.
        var candidates: [(AppWindow, AppWindow, CGFloat)] = []
        for a in windows {
            for b in windows where a.id != b.id {
                let gap = b.frame.minX - a.frame.maxX
                let dy = abs(a.frame.maxY - b.frame.maxY)
                if gap >= 0, gap <= 600, dy < 300 { candidates.append((a, b, gap + dy)) }
            }
        }
        candidates.sort { $0.2 < $1.2 }
        var usedRight = Set<Int>(), usedLeft = Set<Int>()
        let autoLimit = specs.count + 6
        for (a, b, _) in candidates.prefix(200) where autoPairs && specs.count < autoLimit {
            guard !usedRight.contains(a.id), !usedLeft.contains(b.id) else { continue }
            if StringLights.covered(StringLights.point(a, 1), by: a, in: windows)
                && StringLights.covered(StringLights.point(b, 0), by: b, in: windows) { continue }
            let chord = hypot(b.frame.minX - a.frame.maxX, b.frame.maxY - a.frame.maxY)
            let count = max(3, Int(chord / 30))
            guard count <= budget else { continue }
            budget -= count
            usedRight.insert(a.id)
            usedLeft.insert(b.id)
            specs.append((Anchor(window: a.id, fx: 1), Anchor(window: b.id, fx: 0), 18 + chord * 0.12, min(a.order, b.order), nil))
            sig += "p\(a.id)-\(b.id)-\(count);"
        }

        // Garlands along each window's top edge, frontmost windows first.
        for w in windows.sorted(by: { $0.order < $1.order }) where garlands && StringLights.coverage(of: w, in: windows) <= 0.7 && specs.count < StringLights.maxStrands {
            let scallops = w.frame.width < 520 ? 2 : 3
            let chord = w.frame.width / CGFloat(scallops)
            let per = max(2, Int(chord / 30))
            guard per * scallops <= budget else { continue }
            budget -= per * scallops
            for s in 0..<scallops {
                let f0 = CGFloat(s) / CGFloat(scallops), f1 = CGFloat(s + 1) / CGFloat(scallops)
                specs.append((Anchor(window: w.id, fx: f0), Anchor(window: w.id, fx: f1), 10 + chord * 0.05, w.order, nil))
            }
            sig += "g\(w.id)-\(scallops)-\(per);"
        }

        guard sig != signature else { return }
        signature = sig
        removeStrandNodes()
        removeAllChildren()
        strands.removeAll()
        let byId = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, spec) in specs.enumerated() {
            let strand = Strand(a: spec.0, b: spec.1, sag: spec.2, depth: spec.3, link: spec.4)
            guard let wa = byId[spec.0.window], let wb = byId[spec.1.window] else { continue }
            let chord = hypot(StringLights.point(wb, spec.1.fx).x - StringLights.point(wa, spec.0.fx).x,
                              StringLights.point(wb, spec.1.fx).y - StringLights.point(wa, spec.0.fx).y)
            let count = max(spec.0.window == spec.1.window ? 2 : 3, Int(chord / 30))
            let round = index % 3 == 1
            for k in 0..<count {
                let lantern = count >= 5 && k % 7 == 3
                let color: NSColor = lantern ? LightTextures.lanternGlow
                    : (style == .warmWhite ? LightTextures.warm
                       : LightTextures.palette[(k + index) % LightTextures.palette.count])
                let sprite = SKSpriteNode(texture: lantern ? LightTextures.lantern
                                          : (round ? LightTextures.roundBulb : LightTextures.teardrop))
                if !lantern {
                    sprite.color = color
                    sprite.colorBlendFactor = 1
                }
                sprite.size = lantern ? CGSize(width: 11, height: 16.5) : CGSize(width: 9, height: 12.6)
                sprite.anchorPoint = CGPoint(x: 0.5, y: 1)
                sprite.zPosition = 1
                let glow = SKSpriteNode(texture: LightTextures.glow)
                glow.size = lantern ? CGSize(width: 46, height: 46) : CGSize(width: 34, height: 34)
                glow.color = color
                glow.colorBlendFactor = 1
                glow.blendMode = .add
                glow.zPosition = 0
                addChild(glow)
                addChild(sprite)
                strand.bulbs.append(Bulb(sprite: sprite, glow: glow, t: (CGFloat(k) + 0.5) / CGFloat(count), lantern: lantern))
            }
            for _ in 0..<(count + 1) {
                let seg = SKSpriteNode(color: rgb(0.06, 0.16, 0.08, 0.95), size: CGSize(width: 1, height: 1.3))
                seg.anchorPoint = CGPoint(x: 0, y: 0.5)
                seg.zPosition = 0.5
                addChild(seg)
                strand.wires.append(seg)
            }
            if suppressed.contains(strand.a.window) || suppressed.contains(strand.b.window) {
                strand.fade = 0
                for b in strand.bulbs { b.sprite.isHidden = true; b.glow.isHidden = true }
                for w in strand.wires { w.isHidden = true }
            }
            strands.append(strand)
        }
    }

    /// The user strand whose wire or bulbs lie within `tolerance` of `p` (Light Edit mode delete).
    func userLink(near p: CGPoint, tolerance: CGFloat) -> UserLink? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        var best: (UserLink, CGFloat)?
        for strand in strands {
            guard let link = strand.link else { continue }
            var d = CGFloat.infinity
            for b in strand.bulbs where !b.sprite.isHidden {
                let c = CGPoint(x: b.sprite.position.x, y: b.sprite.position.y - 6)
                d = min(d, hypot(p.x - c.x, p.y - c.y) - 4)
            }
            for seg in strand.wires where !seg.isHidden {
                let a = seg.position
                let e = CGPoint(x: a.x + cos(seg.zRotation) * seg.size.width, y: a.y + sin(seg.zRotation) * seg.size.width)
                d = min(d, StringLights.distance(p, a, e))
            }
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (link, d) }
        }
        return best?.0
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0, 1) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Per-frame: follow anchors, swing, twinkle, and hide parts covered by front windows.
    func update(dt: CGFloat, time: CGFloat, windows: [AppWindow]) {
        guard !strands.isEmpty else { return }
        frameCount += 1
        let twinkleFrame = frameCount % max(1, twinkleEvery) == 0   // twinkle at 20Hz (10Hz power saver)
        let byId = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for strand in strands {
            guard let wa = byId[strand.a.window], let wb = byId[strand.b.window] else {
                for b in strand.bulbs { b.sprite.isHidden = true; b.glow.isHidden = true }
                for w in strand.wires { w.isHidden = true }
                continue
            }
            let inCap = strand.a.window == strand.b.window && capped.contains(strand.a.window)
            if !inCap && (suppressed.contains(strand.a.window) || suppressed.contains(strand.b.window)) {
                if !strand.dropping && strand.fade > 0 {
                    strand.dropping = true
                    strand.offVel.dy -= 260          // the wire swings down as it lets go
                }
                strand.fade = max(0, strand.fade - dt / StringLights.fadeOutTime)
            } else if strand.fade < 1 {
                if strand.fade <= 0 {
                    // Returning at the window's new position: no swing left over from the drop.
                    strand.prevMid = nil
                    strand.off = .zero
                    strand.offVel = .zero
                }
                strand.dropping = false
                strand.fade = min(1, strand.fade + dt / StringLights.fadeInTime)
            }
            if strand.fade <= 0 {
                for b in strand.bulbs { b.sprite.isHidden = true; b.glow.isHidden = true }
                for w in strand.wires { w.isHidden = true }
                continue
            }
            let fade = strand.fade
            // While dropping, keep the wire where it was (the window has already moved on).
            let dropping = strand.dropping
            let p0 = dropping ? (strand.lastP0 ?? StringLights.point(wa, strand.a.fx)) : StringLights.point(wa, strand.a.fx)
            let p1 = dropping ? (strand.lastP1 ?? StringLights.point(wb, strand.b.fx)) : StringLights.point(wb, strand.b.fx)
            if !dropping { strand.lastP0 = p0; strand.lastP1 = p1 }
            guard p0.x.isFinite, p0.y.isFinite, p1.x.isFinite, p1.y.isFinite else {
                for b in strand.bulbs { b.sprite.isHidden = true; b.glow.isHidden = true }
                for w in strand.wires { w.isHidden = true }
                strand.prevMid = nil
                continue
            }
            let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            var moved = strand.prevMid == nil
            if let pm = strand.prevMid, pm != mid {
                // Wire lags behind moving anchors, then springs back.
                strand.off.dx -= (mid.x - pm.x) * 0.5
                strand.off.dy -= (mid.y - pm.y) * 0.5
                moved = true
            }
            strand.prevMid = mid
            strand.offVel.dx += -40 * strand.off.dx * dt
            strand.offVel.dy += -40 * strand.off.dy * dt
            let damp = exp(-2.5 * dt)
            strand.offVel.dx *= damp
            strand.offVel.dy *= damp
            strand.off.dx = clamp(strand.off.dx + strand.offVel.dx * dt, -60, 60)
            strand.off.dy = clamp(strand.off.dy + strand.offVel.dy * dt, -60, 60)
            // Never let a NaN (e.g. from a bad dt) poison the spring forever.
            if !strand.off.dx.isFinite || !strand.off.dy.isFinite || !strand.offVel.dx.isFinite || !strand.offVel.dy.isFinite {
                strand.off = .zero
                strand.offVel = .zero
            }
            strand.offVel.dx = clamp(strand.offVel.dx, -3000, 3000)
            strand.offVel.dy = clamp(strand.offVel.dy, -3000, 3000)
            let springing = abs(strand.off.dx) + abs(strand.off.dy) > 0.05
                || abs(strand.offVel.dx) + abs(strand.offVel.dy) > 0.5
            // Idle sway is slow, so idle strands reposition at 20Hz; moving/springing ones every frame.
            let geometry = moved || springing || frameCount % 3 == 0
            let sway = sin(time * 0.9 + strand.swayPhase) * 2.5
            let c = CGPoint(x: mid.x + strand.off.dx + sway, y: mid.y - 2 * strand.sag + strand.off.dy)

            func bez(_ t: CGFloat) -> CGPoint {
                let u = 1 - t
                return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                               y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
            }
            // A garland in a cap window is clipped by WindowServer itself.
            let occ = inCap ? [] : windows.filter { $0.order < strand.depth && $0.id != strand.a.window && $0.id != strand.b.window }
                .map { $0.frame }
            func hidden(_ p: CGPoint) -> Bool { occ.contains { $0.contains(p) } }

            // Wire joints sit exactly at the bulbs: t = 0, bulb t's..., 1.
            var prev = p0
            for (j, seg) in strand.wires.enumerated() where geometry {
                let q = j < strand.bulbs.count ? bez(strand.bulbs[j].t) : p1
                // Trim segments that cross a front window's edge so the wire stops at the window.
                var start = prev, end = q
                let hs = hidden(start), he = hidden(end)
                if hs != he {
                    var visible = hs ? end : start, covered = hs ? start : end
                    for _ in 0..<6 {
                        let m = CGPoint(x: (visible.x + covered.x) / 2, y: (visible.y + covered.y) / 2)
                        if hidden(m) { covered = m } else { visible = m }
                    }
                    if hs { start = visible } else { end = visible }
                }
                let dx = end.x - start.x, dy = end.y - start.y
                seg.position = start
                seg.size = CGSize(width: hypot(dx, dy) + 0.5, height: 1.3)
                seg.zRotation = atan2(dy, dx)
                seg.isHidden = hs && he
                seg.alpha = fade
                prev = q
            }

            for (k, b) in strand.bulbs.enumerated() {
                if geometry {
                    let p = bez(b.t)
                    b.sprite.position = CGPoint(x: p.x, y: p.y + 1)
                    let center = CGPoint(x: p.x, y: p.y - (b.lantern ? 8 : 6))
                    b.glow.position = center
                    let isHidden = hidden(center)
                    b.sprite.isHidden = isHidden
                    b.glow.isHidden = isHidden
                }
                b.sprite.alpha = fade

                if b.glow.isHidden || !(twinkleFrame || fade < 1) { continue }
                if b.sparkle > 0 { b.sparkle = max(0, b.sparkle - dt * 15) }
                else if CGFloat.random(in: 0...1) < 0.003 { b.sparkle = 1 }
                let alpha: CGFloat
                if b.lantern {
                    alpha = 0.55 + 0.15 * sin(time * 9 + b.phase) + 0.1 * sin(time * 23 + b.phase * 2)
                } else {
                    let breathe = 0.72 + 0.18 * sin(time * 1.3 + b.phase)
                    let chase = 0.8 + 0.2 * sin(time * 2.2 - CGFloat(k) * 0.7)
                    alpha = breathe * chase
                }
                b.glow.alpha = min(1, alpha + b.sparkle * 0.5) * fade
            }
        }
    }
}
