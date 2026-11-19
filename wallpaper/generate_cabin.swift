// generate_cabin.swift
// Procedural "winter cabin" desktop wallpaper (original storybook composition, v2).
// Build & run:
//   swiftc -O generate_cabin.swift -o /tmp/gencabin && /tmp/gencabin [output.png]
// Output: 2940x1912 PNG (MacBook Air 1470x956pt @2x).
// Layout: cabin left of center; right ~45% calm (sky, moon, hills, a few small trees);
// top center calm for the notch; bottom ~240px smooth snow for the Dock.
// Deterministic (fixed seeds). Everything is drawn procedurally; no image assets.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let W = 2940
let H = 1912
let N = W * H

// MARK: - Math

struct RGB { var r: Float; var g: Float; var b: Float
    init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    static func * (a: RGB, s: Float) -> RGB { RGB(a.r * s, a.g * s, a.b * s) }
    static func * (a: RGB, b: RGB) -> RGB { RGB(a.r * b.r, a.g * b.g, a.b * b.b) }
    static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
}
struct V2 { var x: Float; var y: Float
    init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
    static func + (a: V2, b: V2) -> V2 { V2(a.x + b.x, a.y + b.y) }
    static func - (a: V2, b: V2) -> V2 { V2(a.x - b.x, a.y - b.y) }
    static func * (a: V2, s: Float) -> V2 { V2(a.x * s, a.y * s) }
    var cg: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    var len: Float { sqrtf(x * x + y * y) }
    var norm: V2 { let l = max(len, 1e-6); return V2(x / l, y / l) }
}
@inline(__always) func clamp01(_ v: Float) -> Float { v < 0 ? 0 : (v > 1 ? 1 : v) }
@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func mixc(_ a: RGB, _ b: RGB, _ t: Float) -> RGB {
    RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
}
@inline(__always) func lerp(_ a: V2, _ b: V2, _ t: Float) -> V2 { V2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t) }
@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clamp01((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
}
@inline(__always) func fract(_ x: Float) -> Float { x - floorf(x) }
func segDist(_ p: V2, _ a: V2, _ b: V2) -> Float {
    let ab = b - a, ap = p - a
    let t = clamp01((ap.x * ab.x + ap.y * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 1e-6))
    return (ap - ab * t).len
}
func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> CGRect {
    CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
}
func ell(_ c: V2, _ rx: Float, _ ry: Float) -> CGRect { rect(c.x - rx, c.y - ry, c.x + rx, c.y + ry) }

// MARK: - Noise

@inline(__always) func hash2(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
    var h = UInt32(bitPattern: x) &* 0x27d4eb2d
    h ^= UInt32(bitPattern: y) &* 0x165667b1
    h ^= seed &* 0x9E3779B9
    h = (h ^ (h >> 15)) &* 0x85ebca6b
    h = (h ^ (h >> 13)) &* 0xc2b2ae35
    h ^= h >> 16
    return Float(h) / 4294967295.0
}
@inline(__always) func vnoise(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
    let xf = floorf(x), yf = floorf(y)
    let xi = Int32(xf), yi = Int32(yf)
    let fx = x - xf, fy = y - yf
    let ux = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
    let uy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
    let a = hash2(xi, yi, seed), b = hash2(xi + 1, yi, seed)
    let c = hash2(xi, yi + 1, seed), d = hash2(xi + 1, yi + 1, seed)
    return mixf(mixf(a, b, ux), mixf(c, d, ux), uy)
}
func fbm(_ x: Float, _ y: Float, _ oct: Int, _ seed: UInt32) -> Float {
    var sum: Float = 0, amp: Float = 0.5, f: Float = 1, norm: Float = 0
    for o in 0..<oct {
        sum += amp * vnoise(x * f + Float(o) * 17.3, y * f - Float(o) * 9.1, seed &+ UInt32(o))
        norm += amp; amp *= 0.5; f *= 2.03
    }
    return sum / norm
}
/// Cellular noise: (distance to nearest point, to second nearest, id of nearest cell)
func voronoi(_ x: Float, _ y: Float, _ seed: UInt32) -> (Float, Float, Float) {
    let xi = Int32(floorf(x)), yi = Int32(floorf(y))
    var f1: Float = 9, f2: Float = 9, id: Float = 0
    for j in -1...1 {
        for i in -1...1 {
            let cx = xi + Int32(i), cy = yi + Int32(j)
            let px = Float(cx) + 0.15 + 0.7 * hash2(cx, cy, seed)
            let py = Float(cy) + 0.15 + 0.7 * hash2(cx, cy, seed &+ 1)
            let d = hypotf(x - px, y - py)
            if d < f1 { f2 = f1; f1 = d; id = hash2(cx, cy, seed &+ 2) } else if d < f2 { f2 = d }
        }
    }
    return (f1, f2, id)
}
struct Rng {
    var s: UInt64
    mutating func next() -> Float {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
}

// MARK: - Canvas + glow (bloom) buffer

func alloc() -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: N); p.initialize(repeating: 0, count: N); return p
}
let Rb = alloc(), Gb = alloc(), Bb = alloc()
let Lr = alloc(), Lg = alloc(), Lb = alloc()

@inline(__always) func idx(_ x: Int, _ y: Int) -> Int { y * W + x }
@inline(__always) func blend(_ i: Int, _ c: RGB, _ a: Float) {
    if a <= 0 { return }
    let t = a > 1 ? 1 : a
    Rb[i] += (c.r - Rb[i]) * t; Gb[i] += (c.g - Gb[i]) * t; Bb[i] += (c.b - Bb[i]) * t
}
@inline(__always) func addLight(_ i: Int, _ c: RGB, _ a: Float) {
    Rb[i] += c.r * a; Gb[i] += c.g * a; Bb[i] += c.b * a
}
@inline(__always) func darken(_ i: Int, _ k: Float) {
    let a = clamp01(k)
    Rb[i] *= 1 - a; Gb[i] *= 1 - a * 0.92; Bb[i] *= 1 - a * 0.6   // shadows lean blue
}
@inline(__always) func emit(_ i: Int, _ c: RGB, _ a: Float) {
    Lr[i] += c.r * a; Lg[i] += c.g * a; Lb[i] += c.b * a
}
@inline(__always) func getc(_ i: Int) -> RGB { RGB(Rb[i], Gb[i], Bb[i]) }

func boxBlur(_ buf: UnsafeMutablePointer<Float>, _ w: Int, _ h: Int, _ r: Int, passes: Int = 3) {
    if r <= 0 { return }
    let tmp = UnsafeMutablePointer<Float>.allocate(capacity: max(w, h))
    defer { tmp.deallocate() }
    let inv = 1 / Float(2 * r + 1)
    for _ in 0..<passes {
        for y in 0..<h {
            let row = buf + y * w
            var acc: Float = 0
            for k in -r...r { acc += row[min(max(k, 0), w - 1)] }
            for x in 0..<w {
                tmp[x] = acc * inv
                acc += row[min(x + r + 1, w - 1)] - row[max(x - r, 0)]
            }
            for x in 0..<w { row[x] = tmp[x] }
        }
        if h > 1 {
            for x in 0..<w {
                var acc: Float = 0
                for k in -r...r { acc += buf[min(max(k, 0), h - 1) * w + x] }
                for y in 0..<h {
                    tmp[y] = acc * inv
                    acc += buf[min(y + r + 1, h - 1) * w + x] - buf[max(y - r, 0) * w + x]
                }
                for y in 0..<h { buf[y * w + x] = tmp[y] }
            }
        }
    }
}

// "Volume" buffer: a blurred copy of the current mask, so shaders can tell
// top edges (lit), undersides (shadow) and interiors apart.
var volBuf: UnsafeMutablePointer<Float>? = nil
var volX0 = 0, volY0 = 0, volW = 0, volH = 0
@inline(__always) func volAt(_ x: Int, _ y: Int) -> Float {
    let cx = x - volX0, cy = y - volY0
    if cx < 0 || cy < 0 || cx >= volW || cy >= volH { return 0 }
    return volBuf![cy * volW + cx]
}

/// Rasterises vector shapes (CoreGraphics, anti-aliased) into a coverage mask over a
/// bounding box (y-down canvas coords), optionally blurs it, optionally builds a
/// volume buffer, then calls `shade` for every covered pixel.
func mask(_ bx0: Float, _ by0: Float, _ bx1: Float, _ by1: Float, blur: Int = 0, vol: Int = 0,
          _ draw: (CGContext) -> Void, _ shade: (Int, Int, Float) -> Void) {
    let pad = max(blur, vol) * 3 + 4
    let x0 = max(Int(floorf(bx0)) - pad, 0), y0 = max(Int(floorf(by0)) - pad, 0)
    let x1 = min(Int(ceilf(bx1)) + pad, W), y1 = min(Int(ceilf(by1)) + pad, H)
    let w = x1 - x0, h = y1 - y0
    if w <= 0 || h <= 0 { return }
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: CGFloat(-x0), y: CGFloat(-y0))
    ctx.setFillColor(gray: 1, alpha: 1); ctx.setStrokeColor(gray: 1, alpha: 1)
    ctx.setShouldAntialias(true); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    draw(ctx)
    let bpr = ctx.bytesPerRow
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let m = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
    defer { m.deallocate() }
    for r in 0..<h { for c in 0..<w { m[r * w + c] = Float(data[r * bpr + c]) / 255 } }
    if blur > 0 { boxBlur(m, w, h, blur) }
    var v: UnsafeMutablePointer<Float>? = nil
    if vol > 0 {
        v = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
        memcpy(v!, m, w * h * 4)
        boxBlur(v!, w, h, vol, passes: 2)
        volBuf = v; volX0 = x0; volY0 = y0; volW = w; volH = h
    }
    for r in 0..<h {
        for c in 0..<w {
            let cv = m[r * w + c]
            if cv > 0.002 { shade(x0 + c, y0 + r, cv) }
        }
    }
    if let v = v { v.deallocate(); volBuf = nil; volW = 0; volH = 0 }
}
func poly(_ ctx: CGContext, _ pts: [V2]) {
    guard let f = pts.first else { return }
    ctx.move(to: f.cg)
    for p in pts.dropFirst() { ctx.addLine(to: p.cg) }
    ctx.closePath()
}
func bbox(_ pts: [V2]) -> (Float, Float, Float, Float) {
    var a = pts[0].x, b = pts[0].y, c = pts[0].x, d = pts[0].y
    for p in pts { a = min(a, p.x); b = min(b, p.y); c = max(c, p.x); d = max(d, p.y) }
    return (a, b, c, d)
}
func dot(_ x: Float, _ y: Float, _ r: Float, _ c: RGB, _ a: Float, additive: Bool = false) {
    let ext = Int(r * 3 + 2)
    let ylo = max(Int(y) - ext, 0), yhi = min(Int(y) + ext, H - 1)
    let xlo = max(Int(x) - ext, 0), xhi = min(Int(x) + ext, W - 1)
    if ylo > yhi || xlo > xhi { return }
    for py in ylo...yhi {
        for px in xlo...xhi {
            let d = hypotf(Float(px) + 0.5 - x, Float(py) + 0.5 - y)
            let v = expf(-d * d / (r * r))
            if additive { addLight(idx(px, py), c, a * v) } else { blend(idx(px, py), c, a * v) }
        }
    }
}
func emitDot(_ x: Float, _ y: Float, _ r: Float, _ c: RGB, _ a: Float) {
    let ext = Int(r * 3 + 2)
    let ylo = max(Int(y) - ext, 0), yhi = min(Int(y) + ext, H - 1)
    let xlo = max(Int(x) - ext, 0), xhi = min(Int(x) + ext, W - 1)
    if ylo > yhi || xlo > xhi { return }
    for py in ylo...yhi {
        for px in xlo...xhi {
            let d = hypotf(Float(px) + 0.5 - x, Float(py) + 0.5 - y)
            emit(idx(px, py), c, a * expf(-d * d / (r * r)))
        }
    }
}
/// Soft elliptical light/shadow pool.
func pool(_ c: V2, _ rx: Float, _ ry: Float, _ col: RGB, _ k: Float, minY: Float = 0) {
    for y in max(Int(c.y - ry * 2.6), 0)..<min(Int(c.y + ry * 2.6), H) {
        let fy = Float(y)
        if fy < minY - 30 { continue }
        let gate = smoothstep(minY - 30, minY + 10, fy)
        for x in max(Int(c.x - rx * 2.6), 0)..<min(Int(c.x + rx * 2.6), W) {
            let dx = (Float(x) - c.x) / rx, dy = (fy - c.y) / ry
            let v = expf(-(dx * dx + dy * dy))
            if v < 0.003 { continue }
            if k >= 0 { addLight(idx(x, y), col, v * k * gate) } else { darken(idx(x, y), -k * v * gate) }
        }
    }
}

// MARK: - Palette, snow shading, lights

let warm = RGB(1.0, 0.64, 0.28)
let warmHot = RGB(1.0, 0.82, 0.52)
let snowS0 = RGB(0.28, 0.31, 0.60)
let snowS1 = RGB(0.56, 0.59, 0.87)
let snowS2 = RGB(0.90, 0.92, 1.0)
func snowRamp(_ t: Float) -> RGB {
    t < 0.5 ? mixc(snowS0, snowS1, t * 2) : mixc(snowS1, snowS2, (t - 0.5) * 2)
}
/// Lit factor of a snow shape from its volume buffer: tops bright, undersides blue,
/// a little extra light on faces toward the moon (upper right).
func snowLitV(_ x: Int, _ y: Int, _ r: Int) -> Float {
    let up = volAt(x, y - r), dn = volAt(x, y + r)
    let lf = volAt(x - r, y), rt = volAt(x + r, y)
    return clamp01(0.55 + 0.80 * (dn - up) + 0.22 * (lf - rt))
}

let horizonY: Float = 1190
let moonP = V2(2400, 250), moonR: Float = 64
let dockCalm: Float = Float(H) - 240

// Cabin geometry: the gable end faces the viewer; the right side wall recedes to a
// far-right vanishing point.
let VP = V2(5600, 1170)
func proj(_ p: V2, _ s: Float) -> V2 { VP + (p - VP) * s }
let wallL: Float = 600, wallR: Float = 1020
let eaveY: Float = 1218, wallBot: Float = 1440, footBot: Float = 1478
let apex = V2(810, 985)
let sBack: Float = 0.90
let eaveLf = V2(566, 1254), eaveRf = V2(1054, 1254)
func sideY(_ Y: Float, _ x: Float) -> Float { VP.y + (Y - VP.y) * (x - VP.x) / (wallR - VP.x) }
func sidePt(_ s: Float, _ Y: Float) -> V2 { proj(V2(wallR, Y), s) }
func sideS(_ x: Float) -> Float { (x - VP.x) / (wallR - VP.x) }
func sideYf(_ x: Float, _ y: Float) -> Float { VP.y + (y - VP.y) / sideS(x) }   // canvas -> front-plane Y
let backX = VP.x + (wallR - VP.x) * sBack

struct Lamp { var p: V2; var s: Float; var r: Float }
let lamps: [Lamp] = [
    Lamp(p: V2(680, 1362), s: 0.85, r: 170),   // left front window
    Lamp(p: V2(940, 1362), s: 0.85, r: 170),   // right front window
    Lamp(p: V2(820, 1430), s: 1.25, r: 200),   // open door
    Lamp(p: V2(700, 1318), s: 0.75, r: 140),   // porch lantern
    Lamp(p: V2(1125, 1345), s: 0.70, r: 150),  // side window A
    Lamp(p: V2(1300, 1338), s: 0.65, r: 140),  // side window B
    Lamp(p: V2(810, 1112), s: 0.25, r: 90),    // attic window
    Lamp(p: V2(1452, 1424), s: 1.00, r: 170),  // lamp post
]
func warmLight(_ x: Float, _ y: Float) -> Float {
    var s: Float = 0
    for l in lamps {
        let dx = x - l.p.x, dy = (y - l.p.y) * 1.5
        let d2 = dx * dx + dy * dy
        var v = l.s * l.r * l.r / (l.r * l.r + d2)
        if y < l.p.y - 30 { v *= expf(-(l.p.y - 30 - y) / 60) }
        s += v
    }
    return s
}

// MARK: - 1. Sky: gradient, veils, milky way, moon, clouds, stars

do {
    let c0 = RGB(0.026, 0.032, 0.108)
    let c1 = RGB(0.058, 0.062, 0.200)
    let c2 = RGB(0.128, 0.115, 0.315)
    let c3 = RGB(0.262, 0.208, 0.435)
    let c4 = RGB(0.410, 0.315, 0.525)
    let mwA = V2(-200, 990), mwB = V2(3150, 70)
    let mwD = (mwB - mwA).norm
    for y in 0..<Int(horizonY + 40) {
        let t = Float(y) / horizonY
        var c: RGB
        if t < 0.30 { c = mixc(c0, c1, smoothstep(0, 0.30, t)) }
        else if t < 0.62 { c = mixc(c1, c2, smoothstep(0.30, 0.62, t)) }
        else if t < 0.88 { c = mixc(c2, c3, smoothstep(0.62, 0.88, t)) }
        else { c = mixc(c3, c4, smoothstep(0.88, 1.0, t)) }
        let fy = Float(y)
        for x in 0..<W {
            let fx = Float(x)
            // painterly streaky veils
            let n = fbm(fx * 0.0009 + fy * 0.0002, fy * 0.0032, 5, 11)
            let veil = smoothstep(0.50, 0.78, n) * 0.05 * (0.25 + t)
            // milky way: soft band with mottled glow and darker dust lanes
            let rel = V2(fx, fy) - mwA
            let along = rel.x * mwD.x + rel.y * mwD.y
            let pd = rel.x * mwD.y - rel.y * mwD.x
            let band = expf(-powf(pd / 190, 2)) * (1 - smoothstep(780, 1050, fy))
            var mw: Float = 0
            if band > 0.01 {
                let mott = fbm(along * 0.004, pd * 0.012, 5, 77)
                let dust = smoothstep(0.52, 0.68, fbm(along * 0.006 + 3, pd * 0.02, 4, 78)) * expf(-powf(pd / 90, 2))
                mw = band * (0.35 + 1.0 * mott) * (1 - 0.75 * dust) * 0.11
            }
            // moon halo
            let dm = hypotf(fx - moonP.x, fy - moonP.y)
            let ang = atan2f(fy - moonP.y, fx - moonP.x)
            let rays = 0.6 + 0.8 * fbm(ang * 9 + 50, dm * 0.0004, 3, 88)
            let halo = 0.22 * expf(-max(dm - moonR, 0) / 60) + 0.09 * expf(-dm / 330) * rays + 0.045 * expf(-dm / 900)
            // warm haze low behind the cabin
            let gx = (fx - 860) / 1400, gy = (fy - 1150) / 480
            let g = 0.05 * expf(-(gx * gx + gy * gy))
            let i = y * W + x
            Rb[i] = c.r + veil * 0.62 + mw * 0.85 + halo * 0.70 + g * 0.9
            Gb[i] = c.g + veil * 0.52 + mw * 0.82 + halo * 0.74 + g * 0.55
            Bb[i] = c.b + veil * 0.95 + mw * 1.00 + halo * 0.95 + g * 0.6
        }
    }
}

// subtle aurora ribbon arcing over the peaks (teal low edge -> violet top)
do {
    for y in 120..<760 {
        let fy = Float(y)
        for x in 150..<2700 {
            let fx = Float(x)
            let t = (fx - 150) / 2550
            let yc = 600 - 210 * sinf(t * .pi) + 40 * sinf(t * 7.0 + 1) + 30 * (fbm(fx * 0.0015, 2, 3, 401) - 0.5)
            let dy = fy - yc
            // curtain: sharp lower edge, long fading top
            let prof = dy > 0 ? expf(-dy * dy / 300) : expf(dy / 170)
            if prof < 0.01 { continue }
            let warp = fbm(fx * 0.002, fy * 0.002, 2, 402) * 60
            let rays = 0.35 + 0.9 * powf(fbm((fx + warp) * 0.022, fy * 0.0015, 3, 403), 1.6)
            let ends = smoothstep(0, 0.15, t) * smoothstep(1, 0.8, t)
            let notch = 1 - (1 - smoothstep(380, 600, abs(fx - 1470))) * (1 - smoothstep(170, 300, fy))
            let k = prof * rays * ends * notch * 0.13
            let hue = clamp01(-dy / 160)
            let c = mixc(RGB(0.25, 0.95, 0.70), RGB(0.55, 0.35, 0.95), hue)
            addLight(idx(x, y), c, k)
        }
    }
}

// wispy moonlit clouds (kept away from the notch)
do {
    for y in 60..<820 {
        let fy = Float(y)
        let bandA = expf(-powf((fy - 400) / 80, 2)), bandB = expf(-powf((fy - 700) / 60, 2)) * 0.7
        for x in 0..<W {
            let fx = Float(x)
            let notch = 1 - (1 - smoothstep(420, 640, abs(fx - 1470))) * (1 - smoothstep(180, 300, fy))
            let warp = fbm(fx * 0.0015, fy * 0.004, 3, 501) * 2
            let n = fbm(fx * 0.0011 + warp * 0.3, fy * 0.009 + warp * 0.2, 5, 502)
            let dens = smoothstep(0.55, 0.80, n) * max(bandA * smoothstep(1500, 2100, fx), bandB * (1 - smoothstep(900, 1500, fx))) * notch
            if dens < 0.003 { continue }
            let dm = hypotf(fx - moonP.x, fy - moonP.y)
            let moonLit = expf(-dm / 420)
            // silver lining where density falls off toward the moon
            let n2 = fbm((fx + 8) * 0.0011 + warp * 0.3, (fy + 6) * 0.009 + warp * 0.2, 5, 502)
            let edge = clamp01((n - n2) * 14) * moonLit
            var c = mixc(RGB(0.17, 0.16, 0.36), RGB(0.55, 0.54, 0.78), moonLit * 0.7)
            c = c + RGB(0.35, 0.36, 0.45) * edge
            blend(idx(x, y), c, dens * 0.55)
        }
    }
}

// stars: varied sizes and colors, dense dust along the milky way
do {
    var rng = Rng(s: 20261119)
    func star(_ x: Float, _ y: Float, _ b: Float, _ col: RGB, spikes: Bool) {
        let rad: Float = 0.6 + b * 1.7
        let ext = Int(rad * 5 + 2)
        let cx = Int(x), cy = Int(y)
        for py in max(cy - ext, 0)...min(cy + ext, H - 1) {
            for px in max(cx - ext, 0)...min(cx + ext, W - 1) {
                let dx = Float(px) + 0.5 - x, dy = Float(py) + 0.5 - y
                let d2 = dx * dx + dy * dy
                let core = expf(-d2 / (rad * rad * 0.7))
                let halo = b > 0.45 ? 0.12 * expf(-sqrtf(d2) / (rad * 2.6)) : 0
                addLight(py * W + px, col, (core * 0.9 + halo) * b)
            }
        }
        if spikes {
            let len: Float = 12 + 20 * b
            for k in -Int(len)...Int(len) {
                let f = Float(k)
                let a = 0.30 * b * expf(-abs(f) / (len * 0.33))
                if cx + k >= 0 && cx + k < W { addLight(cy * W + cx + k, col, a) }
                if cy + k >= 0 && cy + k < H { addLight((cy + k) * W + cx, col, a) }
                let a2 = a * 0.35
                if cx + k >= 0 && cx + k < W && cy + k >= 0 && cy + k < H && abs(k) < Int(len * 0.5) {
                    addLight((cy + k) * W + cx + k, col, a2)
                    if cy - k >= 0 && cy - k < H { addLight((cy - k) * W + cx + k, col, a2) }
                }
            }
        }
    }
    let palette = [RGB(0.78, 0.85, 1.0), RGB(0.95, 0.95, 1.0), RGB(1.0, 0.92, 0.78), RGB(1.0, 0.80, 0.62), RGB(0.85, 0.90, 1.0)]
    for _ in 0..<1900 {
        let x = rng.range(0, Float(W))
        let y = powf(rng.next(), 1.3) * 960
        var b = powf(rng.next(), 3.0)
        let notch = 1 - (1 - smoothstep(300, 520, abs(x - 1470))) * (1 - smoothstep(60, 170, y))
        let dm = hypotf(x - moonP.x, y - moonP.y)
        b *= notch * (1 - smoothstep(620, 960, y)) * smoothstep(moonR + 30, moonR + 260, dm)
        if b < 0.02 { continue }
        let col = palette[Int(rng.next() * 5) % 5]
        star(x, y, b, col, spikes: b > 0.66)
    }
    // milky-way dust
    let mwA = V2(-200, 990), mwB = V2(3150, 70)
    let d = (mwB - mwA).norm
    for _ in 0..<8000 {
        let t = rng.next() * (mwB - mwA).len
        let g = (rng.next() + rng.next() + rng.next() - 1.5) * 260
        let p = mwA + d * t + V2(d.y, -d.x) * g
        if p.x < 0 || p.x >= Float(W) || p.y < 0 || p.y > 900 { continue }
        if abs(p.x - 1470) < 420 && p.y < 160 { continue }
        let b = powf(rng.next(), 2.2) * 0.32 + 0.03
        dot(p.x, p.y, 0.7, palette[Int(rng.next() * 5) % 5], b, additive: true)
    }
}

// the moon: small, softly textured, with a bright rim
do {
    for y in Int(moonP.y - moonR - 3)...Int(moonP.y + moonR + 3) {
        for x in Int(moonP.x - moonR - 3)...Int(moonP.x + moonR + 3) {
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let d = hypotf(fx - moonP.x, fy - moonP.y)
            let cov = clamp01(moonR - d + 0.5)
            if cov <= 0 { continue }
            let maria = fbm(fx * 0.06, fy * 0.06, 4, 909)
            let crater = voronoi(fx * 0.12, fy * 0.12, 910)
            let rr = d / moonR
            var c = RGB(1.0, 0.97, 0.88) * (1 - 0.16 * smoothstep(0.45, 0.7, maria))
            c = c * (1 - 0.07 * smoothstep(0.25, 0.05, crater.0))
            c = c * (1 - 0.18 * powf(rr, 3))
            blend(idx(x, y), c, cov)
            emit(idx(x, y), RGB(0.9, 0.9, 1.0), cov * 0.25)
        }
    }
}

// MARK: - 2. Mountains: rocky ridges, gullies, moonlit rims, haze

func ridgeHeight(_ x: Float, _ freq: Float, _ seed: UInt32) -> Float {
    let cell: Float = 0.55 / freq
    let ci = Int(floorf(x / cell))
    var m: Float = 0
    for k in (ci - 3)...(ci + 3) {
        let hk = Int32(truncatingIfNeeded: k)
        let px = (Float(k) + 0.2 + 0.6 * hash2(hk, 1, seed)) * cell
        let ph = 0.35 + 0.65 * powf(hash2(hk, 2, seed), 1.4)
        let pw = cell * (0.9 + 1.1 * hash2(hk, 3, seed))
        let skew: Float = hash2(hk, 4, seed) < 0.5 ? 0.8 : 1.25
        let xj = x + (fbm(x * freq * 2.5, 5.5, 3, seed &+ 40) - 0.5) * pw * 0.35
        let dx = xj - px
        let d = dx < 0 ? -dx * skew : dx / skew
        let v = max(0, 1 - d / pw)
        m = max(m, ph * powf(v, 1.25))
    }
    var r: Float = 0, amp: Float = 1, f = freq * 3, sum: Float = 0
    for o in 0..<6 {
        let n = vnoise(x * f, Float(o) * 3.7, seed &+ UInt32(o))
        let rr = 1 - abs(n * 2 - 1)
        r += rr * rr * amp; sum += amp
        amp *= 0.5; f *= 2.1
    }
    r /= sum
    return m + (r - 0.35) * (0.08 + 0.20 * m)
}

func drawRange(baseY: Float, amp: Float, freq: Float, seed: UInt32, lit: RGB, shadow: RGB, rock: RGB,
               mist: RGB, haze: Float, mistDepth: Float, bottomY: Int, envelope: (Float) -> Float) {
    let margin = 600
    var top = [Float](repeating: 0, count: W + 2 * margin)
    for k in 0..<top.count {
        let x = Float(k - margin)
        top[k] = baseY - amp * envelope(x) * ridgeHeight(x, freq, seed)
    }
    let sm = UnsafeMutablePointer<Float>.allocate(capacity: top.count)
    defer { sm.deallocate() }
    for k in 0..<top.count { sm[k] = top[k] }
    boxBlur(sm, top.count, 1, 26)
    let sm2 = UnsafeMutablePointer<Float>.allocate(capacity: top.count)
    defer { sm2.deallocate() }
    for k in 0..<top.count { sm2[k] = top[k] }
    boxBlur(sm2, top.count, 1, 7)
    func topAt(_ x: Float) -> Float { sm[min(max(Int(x) + margin, 0), top.count - 1)] }
    func top2At(_ x: Float) -> Float { sm2[min(max(Int(x) + margin, 0), top.count - 1)] }
    func rawAt(_ x: Float) -> Float { top[min(max(Int(x) + margin, 0), top.count - 1)] }
    for x in 0..<W {
        let ty = top[x + margin]
        let fx = Float(x) + 0.5
        // local crest slope (fine) for the rim light
        let fine = (rawAt(fx + 3) - rawAt(fx - 3)) / 6
        for y in max(Int(ty) - 1, 0)..<bottomY {
            let fy = Float(y) + 0.5
            let cov = clamp01(fy - ty + 0.5)
            if cov <= 0 { continue }
            let d = max(fy - ty, 0)
            // big faces: lit toward the moon (right flanks), spur ridges run diagonally
            let jit = (fbm(fx * 0.004, fy * 0.003, 3, seed &+ 7) - 0.5) * d * 0.6
            let xs = fx + jit * 0.6 + d * 0.55
            let e: Float = 10 + d * 0.15
            let slope = (topAt(xs + e) - topAt(xs - e)) / (2 * e)
            let micro = (fbm(fx * 0.010, fy * 0.004, 3, seed &+ 13) - 0.5) * 0.25
            let l1 = smoothstep(-0.05, 0.07, slope + micro)
            // secondary spurs from the less-smoothed ridgeline: crisp sub-faces
            let xs2 = fx + jit * 0.35 + d * 0.42
            let e2: Float = 4 + d * 0.08
            let slope2 = (top2At(xs2 + e2) - top2At(xs2 - e2)) / (2 * e2)
            let l2 = smoothstep(-0.08, 0.10, slope2 + micro * 0.6)
            let light = clamp01(l1 * 0.62 + l2 * 0.38 + (l1 * l2 - 0.25) * 0.2)
            var c = mixc(shadow, lit, light)
            // snow texture along the fall line
            let fall = fbm(fx * 0.016 + fy * 0.010, fy * 0.0045, 4, seed &+ 29)
            c = c * (0.90 + 0.22 * fall)
            // exposed rock: ridged noise bands, mostly on shadowed faces and steep parts
            let rn = fbm(fx * 0.006 + jit * 0.004, fy * 0.016, 4, seed &+ 23)
            let strata = fbm(fx * 0.03, fy * 0.012, 3, seed &+ 25)
            let streaks = fbm(fx * 0.018 + rn * 0.8, fy * 0.0045, 4, seed &+ 27)
            let rockAmt = smoothstep(0.60, 0.74, streaks) * (0.95 - 0.75 * light) * smoothstep(10, 50, d)
                + smoothstep(0.30, 0.0, abs(l2 - 0.45)) * smoothstep(0.42, 0.62, fbm(fx * 0.02, fy * 0.03, 3, seed &+ 33)) * 1.1 * smoothstep(4, 30, d)
            c = c * (1.06 - 0.16 * smoothstep(0, amp * 0.9, d))
            c = mixc(c, rock * (0.85 + 0.3 * strata), clamp01(rockAmt) * 0.75)
            // snow gullies: pale vertical streaks
            let gully = fbm(fx * 0.045, fy * 0.006, 3, seed &+ 21)
            c = c * (1 + 0.10 * smoothstep(0.58, 0.74, gully) * smoothstep(10, 60, d))
            // fine texture
            c = c * (0.95 + 0.10 * fbm(fx * 0.06, fy * 0.06, 2, seed &+ 31))
            // moonlit crest rim on right-facing crest segments
            let rimK = expf(-d / 3.0) * smoothstep(-0.05, 0.3, fine) * 0.30 + expf(-d / 10) * 0.05
            c = c + RGB(0.75, 0.78, 0.95) * rimK
            let m = smoothstep(mistDepth * 0.2, mistDepth, d)
            c = mixc(c, mist, clamp01(haze + m * 0.9))
            blend(y * W + x, c, cov)
        }
    }
}

func mistBand(_ cy: Float, _ height: Float, _ c: RGB, _ amt: Float, _ seed: UInt32) {
    for y in max(Int(cy - height * 2), 0)..<min(Int(cy + height * 2), H) {
        let fy = Float(y)
        let v = expf(-powf((fy - cy) / height, 2))
        for x in 0..<W {
            let n = fbm(Float(x) * 0.0016, fy * 0.012, 4, seed)
            blend(y * W + x, c, v * amt * (0.5 + 0.9 * (n - 0.5) + 0.5))
        }
    }
}

// towering alpine peaks (background, hazy at the base, moonlit snowfields)
drawRange(baseY: 1120, amp: 760, freq: 0.00072, seed: 606,
          lit: RGB(0.74, 0.76, 0.98), shadow: RGB(0.19, 0.19, 0.43), rock: RGB(0.15, 0.14, 0.31),
          mist: RGB(0.33, 0.28, 0.54), haze: 0.22, mistDepth: 560, bottomY: 1150,
          envelope: { x in 0.80 + 0.20 * sinf(x * 0.0021 + 0.4) - 0.18 * smoothstep(2200, 2900, x) })
mistBand(900, 70, RGB(0.36, 0.31, 0.58), 0.45, 30)
mistBand(1000, 55, RGB(0.38, 0.32, 0.60), 0.40, 29)
drawRange(baseY: 1100, amp: 420, freq: 0.0012, seed: 707,
          lit: RGB(0.66, 0.66, 0.92), shadow: RGB(0.27, 0.25, 0.51), rock: RGB(0.22, 0.20, 0.40),
          mist: RGB(0.38, 0.31, 0.55), haze: 0.36, mistDepth: 300, bottomY: 1200,
          envelope: { x in 0.55 + 0.22 * smoothstep(1500, 2400, x) + 0.25 * (1 - smoothstep(200, 900, x)) })
mistBand(1060, 50, RGB(0.40, 0.33, 0.58), 0.40, 31)
drawRange(baseY: 1170, amp: 240, freq: 0.0019, seed: 808,
          lit: RGB(0.70, 0.71, 0.94), shadow: RGB(0.24, 0.24, 0.48), rock: RGB(0.18, 0.17, 0.36),
          mist: RGB(0.36, 0.30, 0.56), haze: 0.15, mistDepth: 220, bottomY: 1230,
          envelope: { x in 0.5 + 0.22 * smoothstep(1800, 2700, x) + 0.3 * (1 - smoothstep(0, 600, x)) })
mistBand(1150, 38, RGB(0.40, 0.34, 0.60), 0.45, 32)

// MARK: - 3. Trees

/// Snow-laden conifer: drooping tiers with needle-jagged silhouettes, irregular
/// volume-shaded snow clumps on the boughs, a rim lit toward the cabin.
func drawPine(cx: Float, base: Float, h: Float, hw: Float, tiers: Int, seed: UInt32,
              body: RGB, haze: Float, hazeC: RGB, snowAmt: Float = 1, warmK: Float = 0,
              droopK: Float = 0.16, detail: Float = 1) {
    var rng = Rng(s: UInt64(seed) &* 7919)
    let topY = base - h
    let crownH = h * 0.90
    let tierF = Float(tiers)
    let tw = max(hw * 0.09, 2.5)
    mask(cx - tw, base - h * 0.2, cx + tw, base + 4, { ctx in
        ctx.fill(rect(cx - tw, base - h * 0.2, cx + tw, base + 4))
    }, { x, y, cov in
        let c = RGB(0.09, 0.06, 0.07) * (0.8 + 0.4 * fbm(Float(x) * 0.3, Float(y) * 0.02, 2, seed))
        blend(idx(x, y), mixc(c, hazeC, haze), cov)
    })
    struct Tier { var yt: Float; var yb: Float; var w: Float; var lean: Float }
    var ts: [Tier] = []
    for k in 0..<tiers {
        let f1 = Float(k + 1) / tierF
        let yb = topY + crownH * powf(f1, 0.92)
        let th = crownH / tierF * (k == 0 ? 1.8 : 1.95)
        let w = hw * (0.15 + 0.85 * powf(f1, 0.95)) * rng.range(0.88, 1.12)
        ts.append(Tier(yt: max(yb - th, topY), yb: yb, w: w, lean: rng.range(-0.07, 0.07)))
    }
    let cabinSide: Float = cx > 900 ? 1 : -1      // +1: cabin is to the left of this tree
    func hem(_ t: Tier, _ x: Float) -> Float? {
        let th = t.yb - t.yt, droop = th * droopK
        let u = (x - (cx - t.w)) / (2 * t.w)
        if u < 0 || u > 1 { return nil }
        let nSc = Float(max(3, Int(t.w / 24)))
        let sc = th * 0.09 * sinf(fract(u * nSc + 0.2) * .pi)
        let s = 2 * u - 1
        return t.yb + droop - droop * 0.6 * (1 - s * s) - sc + 0.25 * droop * (1 - abs(s))
    }
    for k in stride(from: tiers - 1, through: 0, by: -1) {
        let t = ts[k]
        let th = t.yb - t.yt
        let droop = th * droopK
        let ax = cx + t.lean * t.w
        func edge(_ side: Float, _ u: Float) -> V2 {
            let p0 = V2(ax, t.yt), p2 = V2(cx + side * t.w, t.yb + droop)
            let p1 = V2(cx + side * t.w * 0.42, t.yt + th * 0.60)
            return lerp(lerp(p0, p1, u), lerp(p1, p2, u), u)
        }
        let needle = max(1.0, th * 0.055) * detail
        // silhouette with needle-tufted edges
        var pts: [V2] = []
        let ne = max(12, Int(th / max(needle * 1.4, 1)))
        for j in 0...ne {
            let u = Float(j) / Float(ne)
            let p = edge(-1, u)
            let tg = (edge(-1, min(u + 0.02, 1)) - edge(-1, max(u - 0.02, 0))).norm
            let nrm = V2(tg.y, -tg.x)            // outward for the left edge
            let jag = (j % 2 == 0 ? 1.0 : -0.35) * needle * (0.5 + rng.next()) * (0.3 + u)
            pts.append(p + nrm * jag)
        }
        let nh = max(10, Int(2 * t.w / max(needle * 1.5, 1)))
        for j in 1..<nh {
            let x = cx - t.w + 2 * t.w * Float(j) / Float(nh)
            let jag: Float = (j % 2 == 0 ? powf(rng.next(), 2) * 1.8 + 0.2 : -0.3 * rng.next()) * needle
            pts.append(V2(x, hem(t, x)! + jag))
        }
        for j in stride(from: ne, through: 0, by: -1) {
            let u = Float(j) / Float(ne)
            let p = edge(1, u)
            let tg = (edge(1, min(u + 0.02, 1)) - edge(1, max(u - 0.02, 0))).norm
            let nrm = V2(-tg.y, tg.x)
            let jag = (j % 2 == 0 ? 1.0 : -0.35) * needle * (0.5 + rng.next()) * (0.3 + u)
            pts.append(p + nrm * jag)
        }
        let bb = bbox(pts)
        let rimR = max(2, Int(needle * 1.5))
        mask(bb.0, bb.1, bb.2, bb.3, vol: rimR, { ctx in poly(ctx, pts); ctx.fillPath() }, { x, y, cov in
            let fx = Float(x), fy = Float(y)
            let v = (fy - t.yt) / th
            let sd: Float = fx < cx ? -1 : 1
            // needle streaks along the drooping boughs
            let along = (fx - cx) * sd * 0.75 + (fy - t.yt) * 0.55
            let across = (fy - t.yt) * 0.75 - (fx - cx) * sd * 0.55
            let streak = fbm(along * 0.035, across * 0.28, 3, seed &+ 6)
            let n = fbm(fx * 0.02, fy * 0.02, 2, seed &+ 5)
            var c = body * (0.65 + 0.95 * streak + 0.30 * (n - 0.5)) * (0.85 + 0.45 * (1 - v))
            // rims: moon (upper right) and the cabin's warm light
            let lf = volAt(x - rimR, y), rt = volAt(x + rimR, y), up = volAt(x, y - rimR)
            let rimMoon = clamp01((lf - rt) * 1.4) * 0.6 + clamp01((volAt(x, y + rimR) - up) * 1.2) * 0.3
            c = c + RGB(0.16, 0.18, 0.32) * rimMoon
            let towardCabin = clamp01((cabinSide > 0 ? rt - lf : lf - rt) * 1.5)
            let wl = warmLight(fx, fy) * warmK
            c = c + warm * (wl * (0.08 + 0.55 * towardCabin))
            blend(idx(x, y), mixc(c, hazeC, haze), cov)
        })
        if snowAmt <= 0 { continue }
        // irregular snow clumps resting on the boughs
        var blobs: [(V2, Float, Float)] = []
        for side in [Float(-1), 1] {
            var u: Float = rng.range(0.08, 0.2)
            while u < 0.97 {
                let p = edge(side, u)
                let r = th * (0.06 + 0.09 * u) * rng.range(0.7, 1.35) * snowAmt
                if rng.next() > 0.12 && r > 0.8 {
                    let tg = (edge(side, min(u + 0.03, 1)) - edge(side, max(u - 0.03, 0))).norm
                    let c0 = p + V2(-side * r * 0.35, -r * 0.05)
                    blobs.append((c0 - tg * (r * 0.55), r * 1.15, r * 0.75))
                    blobs.append((c0 + tg * (r * 0.55), r * 0.95, r * 0.65))
                }
                u += rng.range(0.10, 0.22)
            }
            let tip = edge(side, 1)
            let rt = th * rng.range(0.09, 0.15) * snowAmt
            if rt > 0.8 { blobs.append((tip + V2(-side * rt * 0.4, -rt * 0.35), rt * 1.3, rt * 0.75)) }
        }
        if k > 0 {
            let a = ts[k - 1]
            var x = cx - a.w * 0.95
            while x < cx + a.w * 0.95 {
                let r = th * rng.range(0.05, 0.11) * snowAmt
                if rng.next() > 0.45, let hy = hem(a, x), r > 0.8 {
                    blobs.append((V2(x, hy + r * 0.25), r * 1.5, r * 0.8))
                }
                x += max(th * rng.range(0.10, 0.22), 2)
            }
        } else {
            let r = th * 0.11 * snowAmt
            if r > 0.8 { blobs.append((V2(ax, t.yt + th * 0.14), r * 0.9, r * 1.1)) }
        }
        if blobs.isEmpty { continue }
        var sb = (Float(1e9), Float(1e9), Float(-1e9), Float(-1e9))
        var rAvg: Float = 0
        for (c, rx, ry) in blobs {
            sb = (min(sb.0, c.x - rx), min(sb.1, c.y - ry), max(sb.2, c.x + rx), max(sb.3, c.y + ry)); rAvg += ry
        }
        rAvg /= Float(blobs.count)
        let vr = max(1, Int(rAvg * 0.6))
        let mantleW = th * 0.085 * snowAmt
        let aboveT: Tier? = k > 0 ? ts[k - 1] : nil
        mask(sb.0, sb.1, sb.2, sb.3, vol: vr, { ctx in
            for (c, rx, ry) in blobs { ctx.fillEllipse(in: ell(c, rx, ry)) }
            // continuous mantle of snow lying along both bough edges
            if mantleW > 0.8 {
                for side in [Float(-1), 1] {
                    var r2 = Rng(s: UInt64(seed) &+ UInt64(k * 31) &+ (side > 0 ? 7 : 0))
                    for j in 1...24 {
                        let u0 = 0.05 + 0.93 * Float(j - 1) / 24, u1 = 0.05 + 0.93 * Float(j) / 24
                        if r2.next() < 0.12 { continue }
                        let lift = V2(-side * mantleW * 0.15, -mantleW * 0.30)
                        ctx.setLineWidth(CGFloat(mantleW * (0.7 + 1.1 * u1) * r2.range(0.8, 1.2)))
                        ctx.move(to: (edge(side, u0) + lift).cg); ctx.addLine(to: (edge(side, u1) + lift).cg); ctx.strokePath()
                    }
                }
                if let a = aboveT {
                    var r3 = Rng(s: UInt64(seed) &+ UInt64(k * 57))
                    var x = cx - a.w * 0.9
                    while x < cx + a.w * 0.9 {
                        let nx = x + max(a.w * 0.08, 2)
                        if r3.next() > 0.55, let h0 = hem(a, x), let h1 = hem(a, nx) {
                            ctx.setLineWidth(CGFloat(mantleW * r3.range(0.9, 1.6)))
                            ctx.move(to: CGPoint(x: CGFloat(x), y: CGFloat(h0 + mantleW * 0.4)))
                            ctx.addLine(to: CGPoint(x: CGFloat(nx), y: CGFloat(h1 + mantleW * 0.4))); ctx.strokePath()
                        }
                        x = nx
                    }
                }
            }
        }, { x, y, cov in
            let fx = Float(x), fy = Float(y)
            let n = fbm(fx * 0.08, fy * 0.08, 2, seed &+ 9)
            let lit = clamp01(snowLitV(x, y, vr) + 0.15 * (n - 0.5))
            var c = snowRamp(lit)
            let wl = warmLight(fx, fy) * warmK
            c = c + warm * (wl * (0.25 + 0.45 * lit)) * RGB(0.95, 0.88, 0.8)
            blend(idx(x, y), mixc(c, hazeC, haze), cov)
        })
    }
}

/// Bare deciduous tree: recursive forking branches with snow lying on the upper side.
func drawBareTree(x: Float, base: Float, h: Float, seed: UInt32, haze: Float, hazeC: RGB, warmK: Float) {
    var rng = Rng(s: UInt64(seed))
    var segs: [(V2, V2, Float)] = []
    func grow(_ p: V2, _ ang: Float, _ len: Float, _ w: Float, _ depth: Int) {
        let a = ang + (rng.next() - 0.5) * 0.25
        let mid = p + V2(cosf(a) * len * 0.5, sinf(a) * len * 0.5) + V2((rng.next() - 0.5) * len * 0.12, 0)
        let q = mid + V2(cosf(a + (rng.next() - 0.5) * 0.3) * len * 0.5, sinf(a) * len * 0.5)
        segs.append((p, mid, w)); segs.append((mid, q, w * 0.88))
        if depth == 0 || w < 0.7 { return }
        let n = depth >= 6 ? 2 : (rng.next() < 0.55 ? 2 : 3)
        for i in 0..<n {
            let spread = rng.range(0.30, 0.70)
            let na: Float = i == 0 ? a - spread : (i == 1 ? a + spread * 0.9 : a + rng.range(-0.15, 0.15))
            // gravity: thin twigs lean outward then slightly droop
            let g: Float = depth < 3 ? 0.15 * (cosf(na) > 0 ? 1 : -1) : 0
            grow(q, na + g, len * rng.range(0.62, 0.80), w * 0.64, depth - 1)
        }
    }
    grow(V2(x, base), -.pi / 2, h * 0.30, h * 0.04, 8)
    var b = (x, base, x, base)
    for (p, q, _) in segs { b = (min(b.0, p.x, q.x), min(b.1, p.y, q.y), max(b.2, p.x, q.x), max(b.3, p.y, q.y)) }
    mask(b.0 - 6, b.1 - 6, b.2 + 6, b.3 + 6, vol: 2, { ctx in
        for (p, q, w) in segs {
            ctx.setLineWidth(CGFloat(max(w, 0.8))); ctx.move(to: p.cg); ctx.addLine(to: q.cg); ctx.strokePath()
        }
    }, { px, py, cov in
        let fx = Float(px), fy = Float(py)
        var c = RGB(0.10, 0.08, 0.12) * (0.8 + 0.5 * fbm(fx * 0.2, fy * 0.05, 2, seed))
        let rim = clamp01((volAt(px - 2, py) - volAt(px + 2, py)) * 1.5)
        c = c + RGB(0.14, 0.15, 0.28) * rim
        c = c + warm * (warmLight(fx, fy) * warmK * 0.15)
        blend(idx(px, py), mixc(c, hazeC, haze), cov * (0.6 + 0.4 * min(cov * 2, 1)))
    })
    // snow on the upper side of fairly horizontal limbs
    mask(b.0 - 6, b.1 - 8, b.2 + 6, b.3 + 6, vol: 2, { ctx in
        for (p, q, w) in segs {
            let d = q - p
            if abs(d.x) < abs(d.y) * 0.45 || w < 0.9 { continue }
            let off = V2(0, -w * 0.55)
            ctx.setLineWidth(CGFloat(max(w * 0.7, 1.0)))
            ctx.move(to: (p + off).cg); ctx.addLine(to: (q + off).cg); ctx.strokePath()
        }
    }, { px, py, cov in
        let lit = snowLitV(px, py, 2)
        var c = snowRamp(0.35 + 0.65 * lit)
        c = c + warm * (warmLight(Float(px), Float(py)) * warmK * 0.4)
        blend(idx(px, py), mixc(c, hazeC, haze), cov)
    })
}

// MARK: - 4. Rolling snow layers

/// Fills everything below a crest line with sculpted, softly shaded snow.
func snowLayer(crest: (Float) -> Float, rim: RGB, body: RGB, deep: RGB, deepDist: Float,
               sculpt: Float, seed: UInt32, warmK: Float, calmBelow: Float = 99999, x0: Int = 0, x1: Int = W) {
    for x in x0..<x1 {
        let fx = Float(x) + 0.5
        let cy = crest(fx)
        if cy >= Float(H) { continue }
        let rimSlope = crest(fx + 4) - crest(fx - 4)        // >0 means face tilts toward the moon
        for y in max(Int(cy) - 1, 0)..<H {
            let fy = Float(y) + 0.5
            let cov = clamp01(fy - cy + 0.5)
            if cov <= 0 { continue }
            let d = fy - cy
            var c = mixc(rim, body, smoothstep(0, 70, d))
            c = mixc(c, deep, smoothstep(40, deepDist, d))
            let calm = 1 - smoothstep(calmBelow - 140, calmBelow, fy)
            // painterly sculpting at two scales, lit from the upper right (moon)
            let s1 = fbm(fx * 0.0022, fy * 0.0075, 4, seed)
            let s2 = fbm((fx - 6) * 0.0022, (fy - 4) * 0.0075, 4, seed)
            let t1 = fbm(fx * 0.011, fy * 0.03, 3, seed &+ 5)
            let t2 = fbm((fx - 3) * 0.011, (fy - 2) * 0.03, 3, seed &+ 5)
            c = c * (1 + (s1 - s2) * sculpt * calm + (t1 - t2) * 0.9 * sculpt * calm)
            // cool hue drift: lavender <-> blue
            let hue = fbm(fx * 0.0015, fy * 0.004, 3, seed &+ 9) - 0.5
            c = c * RGB(1 + hue * 0.10, 1, 1 - hue * 0.06)
            // wind ripples
            let rip = fbm(fx * 0.0012, fy * 0.02, 3, seed &+ 3)
            c = c * (1 - 0.06 * smoothstep(0.55, 0.75, rip) * calm)
            // crest rim
            c = c + RGB(0.10, 0.10, 0.15) * expf(-d / 3.5) * (0.6 + 0.6 * smoothstep(-2, 2, rimSlope))
            if warmK > 0 {
                let wl = warmLight(fx, fy)
                c = c + warm * (wl * warmK) * RGB(0.95, 0.9, 0.85)
            }
            blend(y * W + x, c, cov)
        }
    }
}

// far hill + soft band of distant fir silhouettes
let crest1 = { (x: Float) -> Float in 1205 + 16 * sinf(x * 0.0021 + 0.7) + 22 * (fbm(x * 0.0012, 3.3, 3, 41) - 0.5) }
do {
    var rng = Rng(s: 909)
    var trees: [(Float, Float, Float)] = []
    var x: Float = -20
    while x < Float(W) + 20 {
        let density = 0.35 + 0.65 * fbm(x * 0.004, 1.1, 2, 42)
        if rng.next() < density {
            trees.append((x, crest1(x) + 6, rng.range(26, 78) * (0.6 + 0.6 * density)))
        }
        x += rng.range(8, 18)
    }
    mask(0, 1100, Float(W), 1300, { ctx in
        for (tx, tb, th) in trees {
            let w = th * 0.30
            poly(ctx, [V2(tx, tb - th), V2(tx + w * 0.55, tb - th * 0.5), V2(tx + w * 0.4, tb - th * 0.5),
                       V2(tx + w, tb), V2(tx - w, tb), V2(tx - w * 0.4, tb - th * 0.5), V2(tx - w * 0.55, tb - th * 0.5)])
            ctx.fillPath()
        }
    }, { x, y, cov in
        let fy = Float(y)
        var c = mixc(RGB(0.17, 0.17, 0.37), RGB(0.38, 0.32, 0.58), smoothstep(1120, 1220, fy) * 0.6 + 0.15)
        c = c * (0.92 + 0.16 * fbm(Float(x) * 0.08, fy * 0.04, 2, 43))
        blend(idx(x, y), c, cov)
    })
}
snowLayer(crest: crest1, rim: RGB(0.60, 0.58, 0.84), body: RGB(0.48, 0.45, 0.74), deep: RGB(0.44, 0.40, 0.70),
          deepDist: 160, sculpt: 0.6, seed: 51, warmK: 0)
mistBand(1225, 30, RGB(0.46, 0.40, 0.66), 0.35, 33)

// frozen lake in the valley on the calm right, reflecting the moon
do {
    let shore = { (x: Float) -> Float in 1240 + 5 * (fbm(x * 0.01, 1.7, 3, 451) - 0.5) + 70 * (1 - smoothstep(1640, 1980, x)) }
    for x in 1600..<W {
        let fx = Float(x) + 0.5
        let sy = shore(fx)
        for y in max(Int(sy) - 1, 0)..<1380 {
            let fy = Float(y) + 0.5
            let cov = clamp01(fy - sy + 0.5)
            if cov <= 0 { continue }
            let d = fy - sy
            var c = mixc(RGB(0.44, 0.40, 0.68), RGB(0.22, 0.22, 0.48), smoothstep(0, 90, d))
            // streaky polished ice
            let streak = fbm(fx * 0.0025, fy * 0.08, 3, 452)
            c = c * (0.92 + 0.16 * streak)
            // moon path
            let wcol = 26 + d * 0.9
            let mx = (fx - moonP.x) / wcol
            let glitter = 0.5 + 0.9 * smoothstep(0.45, 0.8, fbm(fx * 0.03, fy * 0.35, 3, 453))
            c = c + RGB(0.80, 0.82, 0.98) * (expf(-mx * mx) * 0.38 * glitter * (1 - smoothstep(10, 120, d) * 0.4))
            // faint ice cracks and wind-blown snow patches
            let (f1, f2, _) = voronoi(fx * 0.012, fy * 0.05, 454)
            c = c * (1 - 0.10 * smoothstep(0.06, 0.0, f2 - f1))
            let patch = smoothstep(0.58, 0.72, fbm(fx * 0.004, fy * 0.03, 4, 455))
            c = mixc(c, RGB(0.62, 0.62, 0.88), patch * 0.6)
            // bright snowy far shore
            c = c + RGB(0.20, 0.20, 0.26) * expf(-d / 2.5)
            blend(idx(x, y), c, cov)
        }
    }
    mistBand(1250, 16, RGB(0.50, 0.46, 0.72), 0.25, 34)
}

// middle hill: dense, hazy forest line behind the cabin (thin on the right)
let crest2 = { (x: Float) -> Float in
    1266 + 22 * sinf(x * 0.0017 + 2.1) + 24 * (fbm(x * 0.0011, 7.7, 3, 61) - 0.5) + 78 * smoothstep(1650, 2250, x)
}
let hazeC = RGB(0.32, 0.28, 0.54)
do {
    var rng = Rng(s: 1212)
    var x: Float = -30
    while x < 1780 {
        let h = rng.range(120, 250) * (1 - 0.4 * smoothstep(1400, 1780, x))
        drawPine(cx: x, base: crest2(x) + 8, h: h, hw: h * rng.range(0.24, 0.32), tiers: 6, seed: UInt32(x + 100) &+ 77,
                 body: RGB(0.10, 0.12, 0.24), haze: 0.42, hazeC: hazeC, snowAmt: 0.7, detail: 0.7)
        x += rng.range(16, 34)
    }
    for gx in [1880, 1925, 1975, 2540, 2585, 2640, 2830] as [Float] {
        let h = rng.range(90, 170)
        drawPine(cx: gx, base: crest2(gx) + 8, h: h, hw: h * 0.28, tiers: 5, seed: UInt32(gx) &+ 5,
                 body: RGB(0.10, 0.12, 0.24), haze: 0.40, hazeC: hazeC, snowAmt: 0.7, detail: 0.7)
    }
}
snowLayer(crest: crest2, rim: RGB(0.66, 0.66, 0.90), body: RGB(0.52, 0.51, 0.80), deep: RGB(0.46, 0.45, 0.75),
          deepDist: 200, sculpt: 0.8, seed: 62, warmK: 0)
// a nearer row of firs on that hill, right behind the cabin
do {
    var rng = Rng(s: 3434)
    var x: Float = 120
    while x < 1640 {
        let h = rng.range(200, 360) * (1 - 0.35 * smoothstep(1350, 1640, x))
        drawPine(cx: x, base: crest2(x) + 46, h: h, hw: h * rng.range(0.24, 0.30), tiers: 7, seed: UInt32(x) &+ 901,
                 body: RGB(0.08, 0.10, 0.20), haze: 0.24, hazeC: hazeC, snowAmt: 0.85, warmK: 0.2, detail: 0.8)
        x += rng.range(45, 95)
    }
}
// the bare tree and the companion fir beside the cabin
drawBareTree(x: 1612, base: 1398, h: 470, seed: 77, haze: 0.08, hazeC: hazeC, warmK: 0.5)
drawBareTree(x: 2330, base: crest2(2330) + 6, h: 230, seed: 78, haze: 0.30, hazeC: hazeC, warmK: 0)
drawPine(cx: 450, base: 1400, h: 600, hw: 165, tiers: 10, seed: 450,
         body: RGB(0.05, 0.08, 0.14), haze: 0.08, hazeC: hazeC, warmK: 0.8)

// cabin terrace
let crest3 = { (x: Float) -> Float in
    1388 + 80 * smoothstep(1350, 2800, x) + 12 * sinf(x * 0.0035 + 1.0) + 14 * (fbm(x * 0.002, 9.1, 3, 71) - 0.5)
}
snowLayer(crest: crest3, rim: RGB(0.74, 0.75, 0.96), body: RGB(0.52, 0.54, 0.85), deep: RGB(0.42, 0.44, 0.76),
          deepDist: 330, sculpt: 1.0, seed: 73, warmK: 0.34)

// soft ambient occlusion where the cabin meets the snow
do {
    mask(wallL - 60, 1440, backX + 60, 1530, blur: 10, { ctx in
        poly(ctx, [V2(wallL - 30, 1490), V2(wallR + 40, 1500), V2(backX + 30, sideY(footBot, backX) + 10),
                   V2(backX + 30, sideY(footBot, backX) - 20), V2(wallR, 1470), V2(wallL - 30, 1470)])
        ctx.fillPath()
    }, { x, y, cov in darken(idx(x, y), 0.35 * cov) })
}

// MARK: - 5. Cabin

/// Log wall shading. `along` = position along the wall, `Yf` = front-plane height.
func logColor(_ along: Float, _ Yf: Float, _ x: Float, _ y: Float, side: Bool) -> RGB {
    let LH: Float = 29.6
    let lv = (Yf - eaveY) / LH
    let li = floorf(lv)
    let f = lv - li
    let ii = Int32(li)
    let n = 2 * f - 1
    let cyl = sqrtf(max(0, 1 - n * n))
    // light from above: upper half of each log brighter
    let lit = clamp01(0.40 + 0.75 * cyl * (0.75 - 0.45 * n))
    let tone = 0.82 + 0.36 * hash2(ii, 3, 41)
    let grain = fbm(along * 0.010 + li * 13.1, Yf * 0.30, 4, 91)
    let fine = fbm(along * 0.08, Yf * 0.9, 2, 92)
    var wood = mixc(RGB(0.11, 0.06, 0.045), RGB(0.44, 0.27, 0.15), lit * (0.70 + 0.55 * (grain - 0.5)) * tone)
    wood = wood * (0.92 + 0.16 * fine)
    // knots
    let cellW: Float = 110
    let ci = floorf(along / cellW)
    let kh = hash2(Int32(ci), ii, 42)
    if kh < 0.45 {
        let kx = (ci + 0.2 + 0.6 * hash2(Int32(ci), ii, 43)) * cellW
        let kd = hypotf((along - kx) / 8.5, (f - 0.5) / 0.20)
        if kd < 1.6 {
            let ring = 0.5 + 0.5 * sinf(kd * 9)
            wood = mixc(wood, RGB(0.09, 0.05, 0.035), smoothstep(1.6, 0.5, kd) * (0.55 + 0.3 * ring))
        }
    }
    // cracks / checks running along the log
    let crack = abs(fbm(along * 0.006, li * 3.3, 3, 44) - 0.5)
    if f > 0.3 && f < 0.7 { wood = wood * (1 - 0.45 * smoothstep(0.012, 0.0, crack)) }
    // pale chinking between logs, darker shadow beneath each log's belly
    let chink = smoothstep(0.09, 0.03, f) + smoothstep(0.91, 0.97, f)
    wood = mixc(wood, RGB(0.36, 0.32, 0.32) * (0.85 + 0.3 * fine), clamp01(chink) * 0.85)
    wood = wood * (1 - 0.35 * smoothstep(0.75, 0.9, f) * (1 - smoothstep(0.93, 0.97, f)))
    // cool night ambient, warm spill
    wood = wood * (side ? RGB(0.60, 0.64, 0.95) : RGB(0.78, 0.78, 1.04))
    let wl = warmLight(x, y)
    wood = wood + RGB(0.60, 0.33, 0.13) * (wl * 0.55 * (0.35 + 0.65 * cyl))
    return wood
}
/// Fieldstone foundation (cellular stones with mortar), used on walls and chimney.
func stoneColor(_ u: Float, _ v: Float, _ x: Float, _ y: Float, _ seed: UInt32, ambient: RGB) -> RGB {
    let (f1, f2, id) = voronoi(u, v, seed)
    let edge = f2 - f1
    var c = mixc(RGB(0.30, 0.27, 0.29), RGB(0.52, 0.46, 0.44), id)
    c = c * (0.85 + 0.3 * fbm(x * 0.15, y * 0.15, 2, seed &+ 3))
    c = c * (1.08 - 0.45 * smoothstep(0.1, 0.5, f1))          // rounded stone
    c = mixc(c, RGB(0.12, 0.11, 0.14), smoothstep(0.10, 0.03, edge))
    return c * ambient + RGB(0.5, 0.28, 0.12) * (warmLight(x, y) * 0.3)
}

// side wall logs
do {
    let pts = [V2(wallR, eaveY), V2(backX, sideY(eaveY, backX)), V2(backX, sideY(wallBot, backX)), V2(wallR, wallBot)]
    let b = bbox(pts)
    mask(b.0, b.1, b.2, b.3, { ctx in poly(ctx, pts); ctx.fillPath() }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let s = sideS(fx)
        let Yf = sideYf(fx, fy)
        var c = logColor((1 - s) * 4580, Yf, fx, fy, side: true)
        c = c * (0.55 + 0.45 * smoothstep(eaveY, eaveY + 50, Yf))
        blend(idx(x, y), c, cov)
    })
    // side foundation
    let fp = [V2(wallR, wallBot), V2(backX, sideY(wallBot, backX)), V2(backX, sideY(footBot, backX)), V2(wallR, footBot)]
    let fb = bbox(fp)
    mask(fb.0, fb.1, fb.2, fb.3, { ctx in poly(ctx, fp); ctx.fillPath() }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let s = sideS(fx)
        let c = stoneColor((1 - s) * 4580 / 30, (sideYf(fx, fy) - wallBot) / 19, fx, fy, 201, ambient: RGB(0.62, 0.66, 0.98))
        blend(idx(x, y), c, cov)
    })
}
// front wall + gable boards
do {
    let pts = [V2(wallL, footBot), V2(wallL, eaveY), apex, V2(wallR, eaveY), V2(wallR, footBot)]
    let b = bbox(pts)
    mask(b.0, b.1, b.2, b.3, { ctx in poly(ctx, pts); ctx.fillPath() }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        var c: RGB
        if fy > wallBot {
            c = stoneColor(fx / 30, (fy - wallBot) / 19, fx, fy, 202, ambient: RGB(0.75, 0.76, 1.02))
        } else if fy > eaveY {
            c = logColor(fx, fy, fx, fy, side: false)
            // under the porch roof it is darker
            c = c * (0.5 + 0.5 * smoothstep(1296, 1350, fy))
        } else {
            let bw: Float = 26
            let col = floorf((fx - wallL) / bw)
            let f = fract((fx - wallL) / bw)
            let grain = fbm(fx * 0.3, fy * 0.012, 3, 93)
            let tone = 0.85 + 0.3 * hash2(Int32(col), 7, 94)
            c = mixc(RGB(0.15, 0.085, 0.06), RGB(0.34, 0.20, 0.11), (0.5 + 0.6 * (grain - 0.5)) * tone)
            c = c * (1 - 0.6 * (smoothstep(0.07, 0.0, f) + smoothstep(0.93, 1.0, f)))
            c = c * (1 + 0.15 * smoothstep(0.2, 0.0, f))            // board edge catches light
            c = c * RGB(0.78, 0.78, 1.05) + RGB(0.55, 0.30, 0.12) * (warmLight(fx, fy) * 0.35)
            c = c * (0.55 + 0.45 * smoothstep(1010, 1120, fy))
        }
        blend(idx(x, y), c, cov)
    })
}
// protruding log ends at the front corners, each with a pinch of snow
for (cxL, dir) in [(wallL, Float(-1)), (wallR, Float(1))] {
    for k in 0..<8 {
        let cyL = eaveY + (Float(k) + 0.5) * 29.6
        if cyL > wallBot - 6 { continue }
        let px = cxL + dir * 8
        let r: Float = 15
        mask(px - r, cyL - r, px + r, cyL + r, { ctx in ctx.fillEllipse(in: ell(V2(px, cyL), r * (dir > 0 ? 0.85 : 1), r)) }, { x, y, cov in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let d = hypotf(fx - px, fy - cyL) / r
            let ring = 0.5 + 0.5 * sinf(d * 22 + fbm(fx * 0.2, fy * 0.2, 2, 95) * 4)
            var c = mixc(RGB(0.50, 0.34, 0.20), RGB(0.32, 0.20, 0.12), ring * 0.55)
            c = c * (1 - 0.5 * smoothstep(0.7, 1.0, d)) * (1.1 - 0.3 * clamp01((fy - cyL) / r + 0.5))
            let shade: Float = fy < 1300 ? 0.55 : 1
            c = c * RGB(0.80, 0.80, 1.02) * shade + RGB(0.5, 0.28, 0.1) * (warmLight(fx, fy) * 0.4)
            blend(idx(x, y), c, cov)
        })
        if cyL > 1300 || k < 3 {
            mask(px - r, cyL - r - 6, px + r, cyL - r + 6, vol: 2, { ctx in
                ctx.fillEllipse(in: ell(V2(px, cyL - r + 2.5), r * 0.75, 4.5))
            }, { x, y, cov in blend(idx(x, y), snowRamp(0.3 + 0.7 * snowLitV(x, y, 2)), cov) })
        }
    }
}

/// Window with frame, warm interior, curtains, a silhouette (1 lamp, 2 plant, 3 candle),
/// frosted pane corners, muntins and a snowy sill.
func drawWindow(_ quad: [V2], uvAt: @escaping (Float, Float) -> (Float, Float), deco: Int,
                round: Bool = false, power: Float = 1, panes: Int = 2, shutters: Bool = false) {
    let b = bbox(quad)
    let cw = V2((b.0 + b.2) / 2, (b.1 + b.3) / 2)
    let fr: Float = round ? 7 : 9
    let frame = quad.map { p -> V2 in let d = p - cw; let l = max(d.len, 1); return p + d * (fr / l * 1.35) }
    let fb = bbox(frame)
    if shutters {
        let wq = b.2 - b.0
        for sx in [b.0 - fr - wq * 0.42, b.2 + fr] {
            let sx1 = sx + wq * 0.42
            let top = b.1 - 4, bot = b.3 + 4
            mask(sx, top, sx1, bot, { ctx in ctx.fill(rect(sx, top, sx1, bot)) }, { x, y, cov in
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let pl = fract((fx - sx) / ((sx1 - sx) / 3))
                let slat = fract((fy - top) / 7)
                var c = RGB(0.10, 0.20, 0.22) * (0.8 + 0.4 * fbm(fx * 0.2, fy * 0.03, 2, 61))
                c = c * (1 - 0.35 * smoothstep(0.1, 0.0, pl)) * (1 - 0.25 * smoothstep(0.75, 1.0, slat))
                c = c * RGB(0.85, 0.88, 1.05) + RGB(0.5, 0.28, 0.1) * (warmLight(fx, fy) * 0.3)
                blend(idx(x, y), c, cov)
            })
        }
    }
    mask(fb.0, fb.1, fb.2, fb.3, { ctx in
        if round { ctx.fillEllipse(in: rect(fb.0, fb.1, fb.2, fb.3)) } else { poly(ctx, frame); ctx.fillPath() }
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        var c = RGB(0.16, 0.10, 0.07) * (0.8 + 0.4 * fbm(fx * 0.2, fy * 0.2, 2, 62))
        c = c + RGB(0.45, 0.24, 0.08) * (power * 0.45)
        blend(idx(x, y), c, cov)
    })
    mask(b.0, b.1, b.2, b.3, { ctx in
        if round { ctx.fillEllipse(in: rect(b.0, b.1, b.2, b.3)) } else { poly(ctx, quad); ctx.fillPath() }
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let (u, v) = uvAt(fx, fy)
        let du = u - 0.5, dv = v - 0.6
        let g = expf(-(du * du * 3.5 + dv * dv * 2.6))
        var c = mixc(RGB(0.58, 0.22, 0.07), RGB(1.0, 0.80, 0.46), g)
        // back wall hint: a darker band (shelf / beam) and soft vertical variation
        c = c * (1 - 0.18 * smoothstep(0.02, 0.0, abs(v - 0.22)))
        var glowExtra: Float = 0
        if deco == 1 {
            // table lamp: glowing shade, dark stand
            let shade = (v > 0.40 && v < 0.58) && abs(u - 0.26) < 0.10 + (v - 0.40) * 0.35
            if shade { c = RGB(1.0, 0.90, 0.62); glowExtra = 0.7 }
            if abs(u - 0.26) < 0.018 && v >= 0.58 && v < 0.84 { c = RGB(0.20, 0.09, 0.04) }
            if abs(u - 0.26) < 0.08 && v >= 0.84 && v < 0.90 { c = RGB(0.20, 0.09, 0.04) }
            let lg = expf(-((u - 0.26) * (u - 0.26) + (v - 0.5) * (v - 0.5)) * 30)
            c = c + RGB(0.35, 0.22, 0.08) * lg
        } else if deco == 2 {
            // potted plant
            if v > 0.80 && abs(u - 0.74) < 0.10 - (v - 0.80) * 0.15 { c = RGB(0.30, 0.10, 0.05) }
            let lobes = fbm(u * 9, v * 9, 3, 63)
            let ld = hypotf((u - 0.74) / 0.20, (v - 0.62) / 0.22)
            if ld < 0.75 + 0.5 * (lobes - 0.5) && v < 0.82 { c = RGB(0.16, 0.12, 0.05) }
        } else if deco == 3 {
            // candle on the sill
            if abs(u - 0.5) < 0.05 && v > 0.70 { c = RGB(0.9, 0.82, 0.70) }
            let fl = hypotf((u - 0.5) / 0.035, (v - 0.64) / 0.07)
            if fl < 1 { c = RGB(1.0, 0.95, 0.75); glowExtra = 0.9 }
        }
        // curtains
        if !round {
            let tie = 0.17 + 0.09 * smoothstep(0.55, 0.0, abs(v - 0.58))
            let cl = smoothstep(tie, tie - 0.05, u) + smoothstep(1 - tie, 1 - tie + 0.05, u)
            let folds = 0.85 + 0.3 * sinf(u * 70)
            c = mixc(c, RGB(0.58, 0.15, 0.10) * (0.7 + 0.5 * g) * folds, clamp01(cl) * 0.9)
        }
        // frost in the pane corners
        let pu = fract(u * Float(panes)), pv = fract(v * Float(panes))
        let cd = min(min(hypotf(pu, pv), hypotf(1 - pu, pv)), min(hypotf(pu, 1 - pv), hypotf(1 - pu, 1 - pv)))
        let frost = smoothstep(0.32, 0.05, cd) * (0.5 + 0.6 * fbm(fx * 0.2, fy * 0.2, 3, 64))
        c = mixc(c, RGB(0.95, 0.88, 0.85), clamp01(frost) * 0.45)
        // muntins
        let mw: Float = round ? 0.05 : 0.03
        var mull: Float = 0
        for k in 1..<panes {
            let p = Float(k) / Float(panes)
            mull = max(mull, max(smoothstep(mw, mw * 0.4, abs(u - p)), smoothstep(mw * 1.2, mw * 0.5, abs(v - p))))
        }
        c = mixc(c, RGB(0.17, 0.09, 0.05), mull * 0.92)
        c = c * power
        blend(idx(x, y), c, cov)
        emit(idx(x, y), c, cov * (0.45 + glowExtra) * (1 - mull * 0.6))
    })
    if !round {
        let sy = fb.3
        let sx0 = fb.0 - 6, sx1 = fb.2 + 6
        mask(sx0, sy - 6, sx1, sy + 8, { ctx in ctx.fill(rect(sx0, sy - 3, sx1, sy + 5)) }, { x, y, cov in
            blend(idx(x, y), RGB(0.14, 0.09, 0.07) + RGB(0.3, 0.16, 0.06) * power * 0.3, cov)
        })
        mask(sx0 - 2, sy - 18, sx1 + 2, sy + 2, vol: 3, { ctx in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: CGFloat(sx0 - 1), y: CGFloat(sy - 1)))
            p.addCurve(to: CGPoint(x: CGFloat(sx1 + 1), y: CGFloat(sy - 1)),
                       control1: CGPoint(x: CGFloat(sx0 + 6), y: CGFloat(sy - 20)),
                       control2: CGPoint(x: CGFloat(sx1 - 10), y: CGFloat(sy - 15)))
            p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
            ctx.fillEllipse(in: ell(V2(sx1 - 4, sy + 2), 4, 6))      // a small drip
        }, { x, y, cov in
            let lit = snowLitV(x, y, 3)
            var c = snowRamp(0.25 + 0.75 * lit)
            c = c + warm * (0.35 * power * clamp01(1 - lit * 0.5))
            blend(idx(x, y), c, cov)
        })
    }
}

// front windows (left: table lamp, right: potted plant), attic window
drawWindow([V2(638, 1318), V2(722, 1318), V2(722, 1402), V2(638, 1402)],
           uvAt: { x, y in ((x - 638) / 84, (y - 1318) / 84) }, deco: 1, shutters: true)
drawWindow([V2(898, 1318), V2(982, 1318), V2(982, 1402), V2(898, 1402)],
           uvAt: { x, y in ((x - 898) / 84, (y - 1318) / 84) }, deco: 2, shutters: true)
drawWindow([V2(782, 1084), V2(838, 1084), V2(838, 1140), V2(782, 1140)],
           uvAt: { x, y in ((x - 782) / 56, (y - 1084) / 56) }, deco: 0, round: true, power: 0.85)

// side windows A and B (candle in one)
for (s0, s1, deco) in [(Float(0.986), Float(0.968), 3), (Float(0.948), Float(0.930), 2)] {
    let Y0: Float = 1290, Y1: Float = 1395
    drawWindow([sidePt(s0, Y0), sidePt(s1, Y0), sidePt(s1, Y1), sidePt(s0, Y1)],
               uvAt: { x, y in ((s0 - sideS(x)) / (s0 - s1), (sideYf(x, y) - Y0) / (Y1 - Y0)) },
               deco: deco, power: 0.92)
}

// sled leaning on the side wall between the windows
do {
    let s0: Float = 0.9625, s1: Float = 0.9545
    let a = sidePt(s0, 1330), b = sidePt(s1, 1326)
    let c = sidePt(s1, wallBot + 20) + V2(6, 0), d = sidePt(s0, wallBot + 22) + V2(-2, 0)
    let q = [a, b, c, d]
    let bb = bbox(q)
    mask(bb.0 - 4, bb.1 - 12, bb.2 + 4, bb.3, { ctx in
        poly(ctx, q); ctx.fillPath()
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let slat = fract((fy - a.y) / 18)
        var col = mixc(RGB(0.40, 0.24, 0.13), RGB(0.55, 0.33, 0.18), fbm(fx * 0.3, fy * 0.05, 2, 66))
        col = col * (1 - 0.55 * smoothstep(0.8, 0.95, slat))
        col = col * RGB(0.7, 0.72, 1.0) + RGB(0.5, 0.28, 0.1) * (warmLight(fx, fy) * 0.4)
        blend(idx(x, y), col, cov)
    })
    // red runners with a curled top
    mask(bb.0 - 10, bb.1 - 20, bb.2 + 10, bb.3 + 4, { ctx in
        ctx.setLineWidth(3.5)
        for off in [Float(-3), bb.2 - bb.0 + 1] {
            let p0 = V2(bb.0 + off, bb.3 + 2), p1 = V2(bb.0 + off + 2, bb.1 + 4)
            ctx.move(to: p0.cg); ctx.addLine(to: p1.cg)
            ctx.addQuadCurve(to: (p1 + V2(-8, -2)).cg, control: (p1 + V2(-2, -14)).cg)
            ctx.strokePath()
        }
    }, { x, y, cov in
        let c = RGB(0.62, 0.12, 0.10) * RGB(0.8, 0.8, 1.0) + RGB(0.5, 0.25, 0.1) * (warmLight(Float(x), Float(y)) * 0.4)
        blend(idx(x, y), c, cov)
    })
    mask(bb.0 - 6, bb.1 - 10, bb.2 + 6, bb.1 + 6, vol: 2, { ctx in ctx.fillEllipse(in: ell(V2((a.x + b.x) / 2, a.y - 1), (b.x - a.x) * 0.6, 5)) },
         { x, y, cov in blend(idx(x, y), snowRamp(0.3 + 0.7 * snowLitV(x, y, 2)), cov) })
}

// firewood stacked under the eave toward the back corner
do {
    let s0: Float = 0.925, s1: Float = 0.904
    let top: Float = 1384
    var logs: [(V2, Float)] = []
    var rng = Rng(s: 55)
    var row = 0
    var Y = wallBot + 14
    while Y > top {
        var s = s0 - (row % 2 == 0 ? 0 : 0.0014)
        while s > s1 {
            let p = sidePt(s, Y)
            logs.append((p + V2(14, 0), rng.range(8.5, 11)))
            s -= 0.0042
        }
        Y -= 18; row += 1
    }
    let pb = bbox(logs.map { $0.0 })
    // stack body (bark seen from the side, as a dark slab behind the ends)
    mask(pb.0 - 12, pb.1 - 12, pb.2 + 12, pb.3 + 12, { ctx in
        poly(ctx, [sidePt(s0, top - 8) + V2(4, 0), sidePt(s1, top - 8) + V2(20, 0),
                   sidePt(s1, wallBot + 26) + V2(20, 0), sidePt(s0, wallBot + 26) + V2(4, 0)]); ctx.fillPath()
    }, { x, y, cov in blend(idx(x, y), RGB(0.10, 0.07, 0.07), cov) })
    for (p, r) in logs {
        mask(p.x - r, p.y - r, p.x + r, p.y + r, { ctx in ctx.fillEllipse(in: ell(p, r * 0.92, r)) }, { x, y, cov in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let d = hypotf((fx - p.x) / 0.92, fy - p.y) / r
            let ring = 0.5 + 0.5 * sinf(d * 16 + fbm(fx * 0.3, fy * 0.3, 2, 67) * 3)
            var c = mixc(RGB(0.62, 0.44, 0.26), RGB(0.45, 0.30, 0.17), ring * 0.5)
            c = mixc(c, RGB(0.20, 0.12, 0.08), smoothstep(0.78, 0.95, d))
            c = c * RGB(0.72, 0.74, 1.0) * (1.05 - 0.25 * clamp01((fy - p.y) / r + 0.5))
            c = c + RGB(0.5, 0.28, 0.1) * (warmLight(fx, fy) * 0.4)
            blend(idx(x, y), c, cov)
        })
    }
    // snow on top of the stack
    let st0 = sidePt(s0, top - 8) + V2(2, 0), st1 = sidePt(s1, top - 8) + V2(22, 0)
    mask(st0.x - 6, st0.y - 16, st1.x + 6, st0.y + 8, vol: 3, { ctx in
        let p = CGMutablePath()
        p.move(to: (st0 + V2(-4, 4)).cg)
        p.addCurve(to: (st1 + V2(4, 4)).cg, control1: (st0 + V2(10, -18)).cg, control2: (st1 + V2(-10, -16)).cg)
        p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
    }, { x, y, cov in blend(idx(x, y), snowRamp(0.25 + 0.75 * snowLitV(x, y, 3)), cov) })
}

// door (slightly ajar, warm gap), with a wreath
let doorX0: Float = 772, doorX1: Float = 848, doorY0: Float = 1300, doorY1: Float = 1458
do {
    mask(doorX0 - 9, doorY0 - 10, doorX1 + 9, doorY1, { ctx in ctx.fill(rect(doorX0 - 8, doorY0 - 9, doorX1 + 8, doorY1)) },
         { x, y, cov in blend(idx(x, y), RGB(0.12, 0.07, 0.05) + RGB(0.2, 0.1, 0.03) * 0.4, cov) })
    mask(doorX0, doorY0, doorX1, doorY1, { ctx in ctx.fill(rect(doorX0, doorY0, doorX1, doorY1)) }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let u = (fx - doorX0) / (doorX1 - doorX0), v = (fy - doorY0) / (doorY1 - doorY0)
        var c: RGB
        if u > 0.90 {
            // the open gap: warm interior light
            c = mixc(RGB(1.0, 0.86, 0.56), RGB(0.95, 0.55, 0.20), v * 0.6)
            emit(idx(x, y), c, cov * 1.1)
        } else {
            let plank = fract(u * 4 / 0.9)
            let grain = fbm(fx * 0.25, fy * 0.012, 3, 97)
            c = mixc(RGB(0.24, 0.12, 0.07), RGB(0.46, 0.25, 0.13), 0.5 + 0.7 * (grain - 0.5))
            c = c * (1 - 0.5 * (smoothstep(0.08, 0.0, plank) + smoothstep(0.92, 1.0, plank)))
            // Z-brace
            let zb = min(abs(v - 0.25), abs(v - 0.78))
            if zb < 0.025 { c = c * 1.15 }
            c = c * RGB(0.72, 0.72, 1.0) + RGB(0.6, 0.32, 0.12) * (warmLight(fx, fy) * 0.35)
            // light rim along the gap
            c = c + RGB(0.6, 0.35, 0.1) * smoothstep(0.80, 0.90, u)
            let kn = hypotf((u - 0.80) * 76, (v - 0.56) * 158)
            c = mixc(c, RGB(1.0, 0.78, 0.38), smoothstep(4, 2, kn))
        }
        blend(idx(x, y), c, cov)
    })
    // wreath: needle ring, berries, red bow
    let wc = V2(806, 1346)
    mask(wc.x - 26, wc.y - 26, wc.x + 26, wc.y + 26, vol: 3, { ctx in
        ctx.setLineWidth(11); ctx.strokeEllipse(in: ell(wc, 19, 19))
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let a = atan2f(fy - wc.y, fx - wc.x)
        let nd = fbm(a * 8, hypotf(fx - wc.x, fy - wc.y) * 0.4, 3, 98)
        var c = RGB(0.07, 0.17, 0.10) * (0.6 + 0.9 * nd)
        c = c * (0.7 + 0.6 * snowLitV(x, y, 3)) + RGB(0.5, 0.3, 0.1) * (warmLight(fx, fy) * 0.25)
        blend(idx(x, y), c, cov)
    })
    var rng = Rng(s: 12)
    for _ in 0..<9 {
        let a = rng.range(0, 2 * .pi), r = rng.range(15, 23)
        dot(wc.x + cosf(a) * r, wc.y + sinf(a) * r, 2.0, RGB(0.85, 0.12, 0.10), 0.95)
    }
    mask(wc.x - 12, wc.y + 10, wc.x + 12, wc.y + 34, { ctx in
        poly(ctx, [V2(wc.x, wc.y + 19), V2(wc.x - 11, wc.y + 13), V2(wc.x - 11, wc.y + 25)]); ctx.fillPath()
        poly(ctx, [V2(wc.x, wc.y + 19), V2(wc.x + 11, wc.y + 13), V2(wc.x + 11, wc.y + 25)]); ctx.fillPath()
        poly(ctx, [V2(wc.x - 2, wc.y + 19), V2(wc.x - 7, wc.y + 33), V2(wc.x - 3, wc.y + 31)]); ctx.fillPath()
        poly(ctx, [V2(wc.x + 2, wc.y + 19), V2(wc.x + 7, wc.y + 33), V2(wc.x + 3, wc.y + 31)]); ctx.fillPath()
    }, { x, y, cov in blend(idx(x, y), RGB(0.78, 0.12, 0.10) * (0.8 + 0.3 * fbm(Float(x) * 0.3, Float(y) * 0.3, 2, 99)), cov) })
}

// bench under the porch roof (behind the right railing)
do {
    mask(894, 1392, 1006, 1474, { ctx in
        ctx.fill(rect(896, 1396, 1004, 1404)); ctx.fill(rect(896, 1414, 1004, 1421))   // backrest slats
        ctx.fill(rect(892, 1436, 1008, 1444))                                           // seat
        ctx.fill(rect(900, 1444, 906, 1470)); ctx.fill(rect(994, 1444, 1000, 1470))     // legs
        ctx.fill(rect(900, 1396, 905, 1440)); ctx.fill(rect(995, 1396, 1000, 1440))     // back posts
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        var c = mixc(RGB(0.30, 0.17, 0.09), RGB(0.45, 0.27, 0.15), fbm(fx * 0.1, fy * 0.3, 2, 71))
        c = c * RGB(0.75, 0.75, 1.0) + RGB(0.6, 0.32, 0.12) * (warmLight(fx, fy) * 0.35)
        blend(idx(x, y), c, cov)
    })
    // a folded blanket on the bench
    mask(920, 1424, 960, 1440, vol: 2, { ctx in ctx.fill(rect(922, 1426, 958, 1438)) }, { x, y, cov in
        var c = RGB(0.62, 0.16, 0.12) * (0.75 + 0.5 * snowLitV(x, y, 2))
        if Int(Float(x) / 5) % 2 == 0 { c = c * 0.82 }
        blend(idx(x, y), c + RGB(0.4, 0.2, 0.05) * 0.2, cov)
    })
}

// porch deck, steps
let deckTop: Float = 1458, deckFront: Float = 1490, deckFace: Float = 1504
do {
    mask(560, deckTop, 1060, deckFace, { ctx in
        poly(ctx, [V2(wallL - 8, deckTop), V2(wallR + 8, deckTop), V2(1048, deckFront), V2(572, deckFront)]); ctx.fillPath()
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let pl = fract((fy - deckTop) / 6.4)
        var c = mixc(RGB(0.28, 0.16, 0.09), RGB(0.40, 0.24, 0.13), fbm(fx * 0.05, fy * 0.5, 2, 72))
        c = c * (1 - 0.4 * smoothstep(0.85, 1.0, pl))
        c = c * RGB(0.7, 0.72, 1.0) + RGB(0.6, 0.33, 0.12) * (warmLight(fx, fy) * 0.55)
        // thin drifted snow near the front edge and corners
        let sn = smoothstep(deckTop + 18, deckFront, fy) * smoothstep(0.45, 0.6, fbm(fx * 0.02, fy * 0.1, 3, 73))
        c = mixc(c, snowRamp(0.7) + warm * (warmLight(fx, fy) * 0.3), sn)
        blend(idx(x, y), c, cov)
    })
    mask(560, deckFront, 1060, deckFace, { ctx in ctx.fill(rect(572, deckFront, 1048, deckFace)) }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        var c = RGB(0.22, 0.12, 0.07) * (0.85 + 0.3 * fbm(fx * 0.04, fy * 0.4, 2, 74))
        c = c * RGB(0.7, 0.72, 1.0) + RGB(0.6, 0.33, 0.12) * (warmLight(fx, fy) * 0.3)
        blend(idx(x, y), c, cov)
    })
    // steps: two treads with risers, snow-dusted
    for (k, (yT, yR)) in [(deckFace, Float(1520)), (Float(1520), Float(1538))].enumerated() {
        let grow = Float(k) * 10
        let x0 = 752 - grow, x1 = 868 + grow
        mask(x0, yT, x1, yR, { ctx in ctx.fill(rect(x0, yT, x1, yR)) }, { x, y, cov in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let tread = fy < yT + 6
            var c = tread ? RGB(0.42, 0.25, 0.14) : RGB(0.22, 0.12, 0.07)
            c = c * RGB(0.72, 0.74, 1.0) + RGB(0.6, 0.33, 0.12) * (warmLight(fx, fy) * 0.5)
            blend(idx(x, y), c, cov)
        })
        mask(x0 - 4, yT - 8, x1 + 4, yT + 6, vol: 2, { ctx in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: CGFloat(x0 - 2), y: CGFloat(yT + 4)))
            p.addCurve(to: CGPoint(x: CGFloat(x0 + 40), y: CGFloat(yT + 2)), control1: CGPoint(x: CGFloat(x0), y: CGFloat(yT - 8)), control2: CGPoint(x: CGFloat(x0 + 30), y: CGFloat(yT - 6)))
            p.addLine(to: CGPoint(x: CGFloat(x1 - 30), y: CGFloat(yT + 3)))
            p.addCurve(to: CGPoint(x: CGFloat(x1 + 2), y: CGFloat(yT + 4)), control1: CGPoint(x: CGFloat(x1 - 26), y: CGFloat(yT - 7)), control2: CGPoint(x: CGFloat(x1), y: CGFloat(yT - 8)))
            p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
        }, { x, y, cov in
            var c = snowRamp(0.3 + 0.7 * snowLitV(x, y, 2))
            c = c + warm * (warmLight(Float(x), Float(y)) * 0.4)
            blend(idx(x, y), c, cov)
        })
    }
}

// porch posts and railings
let postXs: [Float] = [586, 742, 878, 1034]
let porchRoofFront: Float = 1290
do {
    for px in postXs {
        mask(px - 9, porchRoofFront, px + 9, deckFront + 2, { ctx in ctx.fill(rect(px - 8, porchRoofFront, px + 8, deckFront + 2)) }, { x, y, cov in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let u = (fx - (px - 8)) / 16
            var c = mixc(RGB(0.48, 0.30, 0.17), RGB(0.16, 0.09, 0.06), smoothstep(0.2, 1.0, u))
            c = c * (0.85 + 0.3 * fbm(fx * 0.3, fy * 0.03, 2, 75))
            c = c * RGB(0.75, 0.76, 1.0) + RGB(0.6, 0.33, 0.12) * (warmLight(fx, fy) * 0.45 * (1.2 - u))
            blend(idx(x, y), c, cov)
        })
    }
    for (a, b) in [(postXs[0], postXs[1]), (postXs[2], postXs[3])] {
        mask(a, 1420, b, 1488, { ctx in
            ctx.fill(rect(a, 1424, b, 1432)); ctx.fill(rect(a, 1476, b, 1482))
            var x = a + 14
            while x < b - 8 { ctx.fill(rect(x, 1432, x + 6, 1476)); x += 18 }
        }, { x, y, cov in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            var c = RGB(0.34, 0.20, 0.11) * (0.8 + 0.4 * fbm(fx * 0.2, fy * 0.2, 2, 76))
            c = c * RGB(0.75, 0.76, 1.0) + RGB(0.6, 0.33, 0.12) * (warmLight(fx, fy) * 0.45)
            blend(idx(x, y), c, cov)
        })
        // snow on the top rail, with a few drips
        mask(a - 4, 1408, b + 4, 1438, vol: 3, { ctx in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: CGFloat(a - 2), y: CGFloat(1428)))
            var x = a
            var r = Rng(s: UInt64(a))
            while x < b {
                let nx = min(x + r.range(18, 34), b + 2)
                p.addQuadCurve(to: CGPoint(x: CGFloat(nx), y: CGFloat(1426)), control: CGPoint(x: CGFloat((x + nx) / 2), y: CGFloat(1414 - r.range(0, 5))))
                x = nx
            }
            p.addLine(to: CGPoint(x: CGFloat(b + 2), y: CGFloat(1431)))
            p.addLine(to: CGPoint(x: CGFloat(a - 2), y: CGFloat(1431)))
            p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
            for k in 0..<3 { ctx.fillEllipse(in: ell(V2(a + (b - a) * (0.2 + 0.3 * Float(k)), 1433), 3, 4)) }
        }, { x, y, cov in
            var c = snowRamp(0.25 + 0.75 * snowLitV(x, y, 3))
            c = c + warm * (warmLight(Float(x), Float(y)) * 0.30)
            blend(idx(x, y), c, cov)
        })
    }
}

// porch roof: lean-to slab with a thick snow load and icicles
var icicleRoots: [(V2, Float)] = []
do {
    mask(560, 1228, 1064, 1300, { ctx in ctx.fill(rect(562, 1286, 1060, 1298)) }, { x, y, cov in
        blend(idx(x, y), RGB(0.13, 0.08, 0.06) + RGB(0.3, 0.16, 0.05) * (warmLight(Float(x), Float(y)) * 0.3), cov)
    })
    var rng = Rng(s: 321)
    mask(540, 1200, 1084, 1310, vol: 9, { ctx in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 548, y: 1292))
        // lumpy top surface
        var x: Float = 548
        while x < 1074 {
            let nx = min(x + rng.range(40, 80), 1076)
            p.addQuadCurve(to: CGPoint(x: CGFloat(nx), y: CGFloat(1236 - rng.range(-4, 6))),
                           control: CGPoint(x: CGFloat((x + nx) / 2), y: CGFloat(1222 - rng.range(0, 10))))
            x = nx
        }
        p.addQuadCurve(to: CGPoint(x: 1072, y: 1294), control: CGPoint(x: 1088, y: 1262))
        // front lip bulging down, with drips
        x = 1072
        while x > 552 {
            let nx = max(x - rng.range(26, 50), 550)
            if rng.next() < 0.5 {
                let mx = (x + nx) / 2, dl = rng.range(8, 20)
                p.addQuadCurve(to: CGPoint(x: CGFloat(mx + 5), y: CGFloat(1300)), control: CGPoint(x: CGFloat((x + mx) / 2), y: CGFloat(1306)))
                p.addCurve(to: CGPoint(x: CGFloat(mx - 5), y: CGFloat(1300)),
                           control1: CGPoint(x: CGFloat(mx + 6), y: CGFloat(1300 + dl)), control2: CGPoint(x: CGFloat(mx - 6), y: CGFloat(1300 + dl)))
                p.addQuadCurve(to: CGPoint(x: CGFloat(nx), y: CGFloat(1298)), control: CGPoint(x: CGFloat((mx + nx) / 2), y: CGFloat(1306)))
            } else {
                p.addQuadCurve(to: CGPoint(x: CGFloat(nx), y: CGFloat(1298)), control: CGPoint(x: CGFloat((x + nx) / 2), y: CGFloat(1310 + rng.range(0, 6))))
            }
            icicleRoots.append((V2(nx + 6, 1302), 1))
            x = nx
        }
        p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let lit = snowLitV(x, y, 9)
        var c = snowRamp(0.12 + 0.88 * lit)
        c = c * (0.95 + 0.10 * fbm(fx * 0.04, fy * 0.06, 3, 81))
        c = c + RGB(1.0, 0.62, 0.32) * (0.12 * smoothstep(1280, 1305, fy))
        blend(idx(x, y), c, cov)
    })
}

// porch lantern
let lanternP = V2(700, 1326)
do {
    let lp = lanternP
    mask(lp.x - 3, 1296, lp.x + 3, lp.y - 18, { ctx in
        ctx.setLineWidth(2); ctx.move(to: CGPoint(x: CGFloat(lp.x), y: 1298)); ctx.addLine(to: CGPoint(x: CGFloat(lp.x), y: CGFloat(lp.y - 18))); ctx.strokePath()
    }, { x, y, cov in blend(idx(x, y), RGB(0.08, 0.06, 0.06), cov) })
    mask(lp.x - 16, lp.y - 22, lp.x + 16, lp.y + 24, { ctx in
        poly(ctx, [V2(lp.x - 5, lp.y - 22), V2(lp.x + 5, lp.y - 22), V2(lp.x + 14, lp.y - 12), V2(lp.x - 14, lp.y - 12)]); ctx.fillPath()
        ctx.fill(rect(lp.x - 12, lp.y + 14, lp.x + 12, lp.y + 20))
    }, { x, y, cov in blend(idx(x, y), RGB(0.12, 0.08, 0.07), cov) })
    mask(lp.x - 11, lp.y - 12, lp.x + 11, lp.y + 14, { ctx in ctx.fill(rect(lp.x - 10, lp.y - 12, lp.x + 10, lp.y + 14)) }, { x, y, cov in
        let d = hypotf(Float(x) + 0.5 - lp.x, (Float(y) + 0.5 - lp.y - 3) * 0.8)
        var c = mixc(RGB(1.0, 0.94, 0.72), RGB(0.95, 0.55, 0.18), smoothstep(0, 11, d))
        let bar = smoothstep(1.6, 0.6, abs(Float(x) + 0.5 - lp.x))
        c = mixc(c, RGB(0.15, 0.09, 0.06), bar * 0.6)
        blend(idx(x, y), c, cov)
        emit(idx(x, y), c, cov * 1.2)
    })
    emitDot(lp.x, lp.y + 2, 8, warmHot, 1.6)
}

// main roof: dark boards, thick lumpy snow load, chimney, icicles
let ridgeB = proj(apex, sBack - 0.012)
let eaveRb = proj(eaveRf, sBack - 0.012)
do {
    let slope = [apex, ridgeB, eaveRb, eaveRf]
    let b = bbox(slope + [eaveLf])
    mask(b.0, b.1, b.2, b.3, { ctx in
        poly(ctx, slope); ctx.fillPath()
        ctx.setLineWidth(20)
        ctx.move(to: eaveLf.cg); ctx.addLine(to: apex.cg); ctx.addLine(to: eaveRf.cg); ctx.strokePath()
    }, { x, y, cov in blend(idx(x, y), RGB(0.11, 0.065, 0.06) * RGB(0.8, 0.8, 1.1), cov) })
    // eave shadow on the side wall
    mask(wallR - 10, eaveY - 10, backX + 10, eaveY + 50, blur: 10, { ctx in
        poly(ctx, [V2(wallR, eaveY), V2(backX, sideY(eaveY, backX)), V2(backX, sideY(eaveY + 40, backX)), V2(wallR, eaveY + 40)])
        ctx.fillPath()
    }, { x, y, cov in darken(idx(x, y), 0.5 * cov) })
}
func roofSnowColor(_ fx: Float, _ fy: Float, _ lit: Float) -> RGB {
    let p = V2(fx, fy)
    let dRidge = segDist(p, apex, ridgeB)
    let dEave = segDist(p, eaveRf, eaveRb)
    let across = dRidge / max(dRidge + dEave, 1)
    let h0 = fbm(fx * 0.012, fy * 0.02, 3, 334), h1 = fbm((fx - 4) * 0.012, (fy - 4) * 0.02, 3, 334)
    var c = snowRamp(clamp01(0.22 + 0.78 * lit - 0.22 * across + (h0 - h1) * 2.2))
    let n = fbm(fx * 0.03, fy * 0.04, 3, 333)
    c = c * (0.94 + 0.12 * n)
    let wind = fbm(fx * 0.004 - fy * 0.002, fy * 0.05, 3, 335)
    c = c * (1 - 0.05 * smoothstep(0.55, 0.7, wind))
    let below = fy - (eaveRf.y + (fx - eaveRf.x) * (eaveRb.y - eaveRf.y) / (eaveRb.x - eaveRf.x))
    let dEdge = min(segDist(p, eaveRf, apex), segDist(p, eaveLf, apex))
    let nearLights = max(smoothstep(-30, 16, below), 1 - smoothstep(4, 30, dEdge))
    c = c + RGB(1.0, 0.62, 0.32) * (0.10 * nearLights)
    return c
}
do {
    var rng = Rng(s: 4242)
    let b = bbox([eaveLf, apex, ridgeB, eaveRb, eaveRf])
    mask(b.0 - 50, b.1 - 70, b.2 + 50, b.3 + 60, vol: 13, { ctx in
        let p = CGMutablePath()
        let L = eaveLf + V2(-20, 10)
        p.move(to: L.cg)
        let aTop = apex + V2(-2, -46)
        p.addCurve(to: aTop.cg, control1: (L + V2(40, -84)).cg, control2: (aTop + V2(-150, 96)).cg)
        let rTop = ridgeB + V2(8, -40)
        var prev = aTop
        for k in 1...6 {
            let q = lerp(aTop, rTop, Float(k) / 6)
            p.addQuadCurve(to: q.cg, control: (lerp(prev, q, 0.5) + V2(0, -rng.range(8, 18))).cg)
            prev = q
        }
        let eb = eaveRb + V2(24, 12)
        p.addCurve(to: eb.cg, control1: (rTop + V2(56, 28)).cg, control2: (eb + V2(16, -84)).cg)
        let ef = eaveRf + V2(10, 20)
        let nD = 14
        var last = eb
        for k in 1...nD {
            let q = lerp(eb, ef, Float(k) / Float(nD))
            if rng.next() < 0.55 {
                let dlen = rng.range(12, 34)
                let dm = lerp(last, q, rng.range(0.35, 0.65)) + V2(0, 12)
                p.addQuadCurve(to: (dm + V2(-7, 0)).cg, control: (lerp(last, dm, 0.5) + V2(0, 11)).cg)
                p.addCurve(to: (dm + V2(7, 0)).cg, control1: (dm + V2(-8, dlen)).cg, control2: (dm + V2(8, dlen)).cg)
                p.addQuadCurve(to: q.cg, control: (lerp(dm, q, 0.5) + V2(0, 11)).cg)
            } else {
                p.addQuadCurve(to: q.cg, control: (lerp(last, q, 0.5) + V2(0, rng.range(14, 26))).cg)
            }
            icicleRoots.append((q + V2(0, 6), 2))
            last = q
        }
        let fr1 = apex + V2(0, -36)
        let mid = lerp(ef, fr1, 0.5)
        p.addCurve(to: mid.cg, control1: (ef + V2(-16, 3)).cg, control2: (mid + V2(6, 26)).cg)
        p.addCurve(to: (apex + V2(-10, 22)).cg, control1: (mid + V2(-84, -56)).cg, control2: (apex + V2(14, 12)).cg)
        p.addCurve(to: (L + V2(8, 16)).cg, control1: (apex + V2(-84, 115)).cg, control2: (L + V2(84, -28)).cg)
        p.addQuadCurve(to: L.cg, control: (L + V2(-14, 16)).cg)
        p.closeSubpath()
        ctx.addPath(p); ctx.fillPath()
        // extra pillows along the ridge and the front edges
        for _ in 0..<14 {
            let t = rng.next()
            let c = lerp(aTop, rTop, t) + V2(0, rng.range(4, 16))
            ctx.fillEllipse(in: ell(c, rng.range(22, 42), rng.range(14, 22)))
        }
        for _ in 0..<8 {
            let t = rng.range(0.1, 0.9)
            let c = lerp(L + V2(10, -6), aTop + V2(0, 20), t)
            ctx.fillEllipse(in: ell(c, rng.range(16, 28), rng.range(12, 18)))
        }
    }, { x, y, cov in
        let lit = snowLitV(x, y, 13)
        blend(idx(x, y), roofSnowColor(Float(x) + 0.5, Float(y) + 0.5, lit), cov)
    })
}
// chimney (fieldstone) with snow cap and banked drift
let chimB = lerp(proj(apex, 0.946), proj(eaveRf, 0.946), 0.24)
let chimW: Float = 64
let chimTop = chimB.y - 160
do {
    let x0 = chimB.x - chimW / 2, x1 = chimB.x + chimW / 2
    mask(x0, chimTop, x1, chimB.y - 2, { ctx in ctx.fill(rect(x0, chimTop, x1, chimB.y - 2)) }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        var c = stoneColor((fx - x0) / 21, (fy - chimTop) / 15, fx, fy, 203, ambient: RGB(0.78, 0.80, 1.05))
        c = c * (1.10 - 0.55 * smoothstep(x0, x1, fx))
        c = c + RGB(0.20, 0.21, 0.32) * smoothstep(x1 - 8, x1, fx) * 0.5     // moonlit right edge
        blend(idx(x, y), c, cov)
    })
    mask(x0 - 10, chimTop - 10, x1 + 10, chimTop + 8, { ctx in ctx.fill(rect(x0 - 8, chimTop - 6, x1 + 8, chimTop + 5)) },
         { x, y, cov in blend(idx(x, y), RGB(0.17, 0.14, 0.17), cov) })
    mask(x0 - 18, chimTop - 36, x1 + 18, chimTop, vol: 4, { ctx in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: CGFloat(x0 - 12), y: CGFloat(chimTop - 3)))
        p.addCurve(to: CGPoint(x: CGFloat(x1 + 12), y: CGFloat(chimTop - 3)),
                   control1: CGPoint(x: CGFloat(x0 - 14), y: CGFloat(chimTop - 34)), control2: CGPoint(x: CGFloat(x1 + 14), y: CGFloat(chimTop - 32)))
        p.addQuadCurve(to: CGPoint(x: CGFloat(x0 - 12), y: CGFloat(chimTop - 3)), control: CGPoint(x: CGFloat(chimB.x), y: CGFloat(chimTop + 6)))
        ctx.addPath(p); ctx.fillPath()
        ctx.fillEllipse(in: ell(V2(x0 - 6, chimTop + 1), 4, 7))
    }, { x, y, cov in blend(idx(x, y), snowRamp(0.2 + 0.8 * snowLitV(x, y, 4)), cov) })
    mask(x0 - 36, chimB.y - 30, x1 + 36, chimB.y + 14, vol: 6, { ctx in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: CGFloat(x0 - 34), y: CGFloat(chimB.y + 12)))
        p.addCurve(to: CGPoint(x: CGFloat(x1 + 34), y: CGFloat(chimB.y + 8)),
                   control1: CGPoint(x: CGFloat(x0 - 6), y: CGFloat(chimB.y - 38)), control2: CGPoint(x: CGFloat(x1 + 6), y: CGFloat(chimB.y - 34)))
        p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
    }, { x, y, cov in
        let lit = snowLitV(x, y, 6)
        blend(idx(x, y), roofSnowColor(Float(x) + 0.5, Float(y) + 0.5, lit), cov)
    })
}

// icicles of varied length along the eaves (glassy, catching warm light)
do {
    var rng = Rng(s: 777)
    for (root, kind) in icicleRoots {
        if rng.next() < (kind == 1 ? 0.45 : 0.25) { continue }
        let len = powf(rng.next(), 1.8) * (kind == 1 ? 34 : 60) + 6
        let w = rng.range(2.2, 4.5)
        let tipX = root.x + rng.range(-1.5, 1.5)
        mask(root.x - w - 2, root.y - 2, root.x + w + 2, root.y + len + 2, { ctx in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: CGFloat(root.x - w), y: CGFloat(root.y)))
            p.addQuadCurve(to: CGPoint(x: CGFloat(tipX), y: CGFloat(root.y + len)), control: CGPoint(x: CGFloat(root.x - w * 0.5), y: CGFloat(root.y + len * 0.5)))
            p.addQuadCurve(to: CGPoint(x: CGFloat(root.x + w), y: CGFloat(root.y)), control: CGPoint(x: CGFloat(root.x + w * 0.5), y: CGFloat(root.y + len * 0.5)))
            p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
        }, { x, y, cov in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let u = (fx - root.x) / w
            let t = (fy - root.y) / len
            var c = RGB(0.62, 0.70, 0.95) * (0.75 + 0.25 * t)
            c = c + RGB(0.9, 0.95, 1.0) * (smoothstep(0.6, 0.0, abs(u + 0.35)) * 0.5)   // specular streak
            c = c + RGB(1.0, 0.62, 0.3) * (warmLight(fx, fy) * 0.25 + 0.06)
            blend(idx(x, y), c, cov * 0.85)
        })
    }
}

// MARK: - 6. Fairy lights (amber, soft red, gold, warm white) with bloom + reflections

do {
    var rng = Rng(s: 8080)
    let palette = [RGB(1.0, 0.70, 0.30), RGB(1.0, 0.38, 0.28), RGB(1.0, 0.84, 0.42), RGB(1.0, 0.92, 0.74), RGB(1.0, 0.56, 0.24)]
    let strings: [(V2, V2, Float, Float)] = [
        (eaveLf + V2(22, 2), apex + V2(0, 14), 82, 11),
        (apex + V2(0, 14), eaveRf + V2(-18, 2), 82, 11),
        (eaveRf + V2(12, 34), eaveRb + V2(6, 34), 74, 12),
        (V2(560, 1306), V2(1068, 1306), 84, 12),
    ]
    var wire: [[V2]] = []
    var bulbs: [(V2, Int)] = []
    for (si, (a, b, hook, sag)) in strings.enumerated() {
        let len = (b - a).len
        let nh = max(1, Int(len / hook))
        var pts: [V2] = []
        let steps = nh * 16
        for j in 0...steps {
            let t = Float(j) / Float(steps)
            let ht = fract(t * Float(nh))
            pts.append(lerp(a, b, t) + V2(0, sag * 4 * ht * (1 - ht)))
        }
        wire.append(pts)
        var acc: Float = 0
        for j in 1..<pts.count {
            acc += (pts[j] - pts[j - 1]).len
            if acc >= 25 { acc = 0; bulbs.append((pts[j] + V2(0, 4), si)) }
        }
    }
    let wb = bbox(wire.flatMap { $0 })
    mask(wb.0, wb.1, wb.2, wb.3, { ctx in
        ctx.setLineWidth(1.8)
        for w in wire { ctx.move(to: w[0].cg); for p in w.dropFirst() { ctx.addLine(to: p.cg) }; ctx.strokePath() }
    }, { x, y, cov in blend(idx(x, y), RGB(0.06, 0.05, 0.07), cov * 0.85) })
    for (b, si) in bulbs {
        let c = palette[Int(rng.next() * Float(palette.count)) % palette.count]
        let k = rng.range(0.8, 1.2)
        // tiny cap + glass bulb (slightly elongated) + hot core
        dot(b.x, b.y - 3, 1.6, RGB(0.10, 0.10, 0.08), 0.8)
        dot(b.x, b.y, 4.4, mixc(c, RGB(1, 1, 0.9), 0.35), 1.0)
        dot(b.x, b.y + 0.5, 2.4, RGB(1.0, 0.98, 0.90), 0.9 * k)
        emitDot(b.x, b.y, 5.5, c, 1.5 * k)
        // reflection on the snow below
        var gy: Float = 0
        if si == 2 { gy = sideY(footBot, b.x) + 18 } else if si == 3 { gy = deckFront + 6 } else { gy = -1 }
        if gy > 0 { pool(V2(b.x, gy), 22, 6, c, 0.06 * k) }
    }
}

// MARK: - 7. Snowman, lamp post, fence, path, light on the snow

// trodden path from the steps, winding right along the fence toward the lamp post
let pathPts: [V2] = {
    var p: [V2] = []
    for j in 0...80 {
        let t = Float(j) / 80
        let x = 812 + 1150 * t
        let y = 1545 + 95 * sinf(min(t * 2.2, 1.0) * .pi / 2) - 45 * smoothstep(0.5, 1.0, t) + 6 * sinf(t * 11)
        p.append(V2(x, y))
    }
    return p
}()
do {
    let pb = bbox(pathPts)
    mask(pb.0 - 50, pb.1 - 20, pb.2 + 50, pb.3 + 30, blur: 4, { ctx in
        for j in 1..<pathPts.count {
            let t = Float(j) / Float(pathPts.count - 1)
            ctx.setLineWidth(CGFloat(56 - 34 * t))
            ctx.move(to: pathPts[j - 1].cg); ctx.addLine(to: pathPts[j].cg); ctx.strokePath()
        }
    }, { x, y, cov in
        let fade = 1 - smoothstep(1700, 1960, Float(x))
        darken(idx(x, y), 0.22 * cov * fade)
    })
    // lit far lip of the trench (the side facing the lights)
    mask(pb.0 - 50, pb.1 - 30, pb.2 + 50, pb.3 + 20, blur: 2, { ctx in
        for j in 1..<pathPts.count {
            let t = Float(j) / Float(pathPts.count - 1)
            let off = -(27 - 17 * t)
            ctx.setLineWidth(CGFloat(4 - 2 * t))
            ctx.move(to: (pathPts[j - 1] + V2(0, off)).cg); ctx.addLine(to: (pathPts[j] + V2(0, off)).cg); ctx.strokePath()
        }
    }, { x, y, cov in
        let fade = 1 - smoothstep(1700, 1960, Float(x))
        addLight(idx(x, y), RGB(0.12, 0.12, 0.16) + warm * (warmLight(Float(x), Float(y)) * 0.15), cov * fade)
    })
    // footprints with depth: shadowed hollow + bright raised rim on the lower edge
    var rng = Rng(s: 99)
    for j in stride(from: 1, to: pathPts.count - 4, by: 2) {
        let t = Float(j) / Float(pathPts.count - 1)
        let side: Float = (j / 2) % 2 == 0 ? -1 : 1
        let p = pathPts[j] + V2(rng.range(-2, 2), side * (6 - 4 * t))
        let r = 7.5 - 4.5 * t
        mask(p.x - r * 1.6, p.y - r, p.x + r * 1.6, p.y + r, vol: 2, { ctx in ctx.fillEllipse(in: ell(p, r * 1.25, r * 0.62)) }, { x, y, cov in
            let fy = Float(y) + 0.5
            let tt = (fy - (p.y - r * 0.62)) / (r * 1.24)
            darken(idx(x, y), cov * (0.30 - 0.22 * tt))
        })
        mask(p.x - r * 1.6, p.y, p.x + r * 1.6, p.y + r, { ctx in
            ctx.setLineWidth(CGFloat(max(1, r * 0.22)))
            ctx.addArc(center: p.cg, radius: CGFloat(r * 0.75), startAngle: 0.25, endAngle: .pi - 0.25, clockwise: false)
            ctx.strokePath()
        }, { x, y, cov in addLight(idx(x, y), RGB(0.10, 0.10, 0.14), cov) })
    }
}

// lamp post along the path
let postBase = V2(1452, 1606)
do {
    let px = postBase.x, top: Float = 1418
    pool(V2(px, postBase.y + 2), 26, 7, RGB(0, 0, 0), -0.4)
    mask(px - 12, top, px + 12, postBase.y + 2, { ctx in
        ctx.fill(rect(px - 3.5, top + 30, px + 3.5, postBase.y))
        ctx.fill(rect(px - 8, postBase.y - 22, px + 8, postBase.y))
        ctx.fill(rect(px - 6, top + 26, px + 6, top + 32))
    }, { x, y, cov in
        let fx = Float(x) + 0.5
        var c = mixc(RGB(0.20, 0.20, 0.26), RGB(0.05, 0.05, 0.08), smoothstep(px - 4, px + 4, fx))
        c = c + RGB(0.5, 0.3, 0.1) * (warmLight(fx, Float(y)) * 0.2)
        blend(idx(x, y), c, cov)
    })
    // lantern head
    mask(px - 20, top - 22, px + 20, top + 30, { ctx in
        poly(ctx, [V2(px - 6, top - 20), V2(px + 6, top - 20), V2(px + 18, top - 6), V2(px - 18, top - 6)]); ctx.fillPath()
        ctx.fill(rect(px - 12, top + 22, px + 12, top + 28))
    }, { x, y, cov in blend(idx(x, y), RGB(0.08, 0.08, 0.10), cov) })
    mask(px - 13, top - 6, px + 13, top + 22, { ctx in
        poly(ctx, [V2(px - 13, top - 6), V2(px + 13, top - 6), V2(px + 10, top + 22), V2(px - 10, top + 22)]); ctx.fillPath()
    }, { x, y, cov in
        let d = hypotf(Float(x) + 0.5 - px, (Float(y) + 0.5 - top - 9) * 0.9)
        var c = mixc(RGB(1.0, 0.95, 0.75), RGB(0.95, 0.58, 0.20), smoothstep(0, 13, d))
        let bar = smoothstep(1.6, 0.5, abs(Float(x) + 0.5 - px))
        c = mixc(c, RGB(0.1, 0.08, 0.08), bar * 0.6)
        blend(idx(x, y), c, cov); emit(idx(x, y), c, cov * 1.3)
    })
    emitDot(px, top + 8, 10, warmHot, 1.7)
    mask(px - 24, top - 34, px + 24, top - 12, vol: 3, { ctx in ctx.fillEllipse(in: ell(V2(px, top - 20), 18, 9)) },
         { x, y, cov in blend(idx(x, y), snowRamp(0.25 + 0.75 * snowLitV(x, y, 3)) + warm * 0.08, cov) })
    mask(px - 16, postBase.y - 18, px + 16, postBase.y + 6, vol: 3, { ctx in ctx.fillEllipse(in: ell(V2(px, postBase.y - 2), 15, 8)) },
         { x, y, cov in blend(idx(x, y), snowRamp(0.25 + 0.75 * snowLitV(x, y, 3)) + warm * (warmLight(Float(x), Float(y)) * 0.4), cov) })
}

// half-buried split-rail fence receding to the right beyond the lamp post
do {
    var posts: [(V2, Float)] = []
    for k in 0..<6 {
        let t = Float(k) / 5
        let x = 1530 + 360 * powf(t, 0.9)
        let y = 1592 - 26 * t
        posts.append((V2(x, y), 64 * (1 - 0.35 * t)))
    }
    var rng = Rng(s: 31)
    // rails first (behind posts)
    for k in 0..<(posts.count - 1) {
        let (a, ha) = posts[k], (b, hb) = posts[k + 1]
        for f in [Float(0.72), 0.38] {
            let p0 = a + V2(0, -ha * f), p1 = b + V2(0, -hb * f)
            let sag = rng.range(2, 6)
            mask(min(p0.x, p1.x) - 4, min(p0.y, p1.y) - 6, max(p0.x, p1.x) + 4, max(p0.y, p1.y) + sag + 6, vol: 2, { ctx in
                ctx.setLineWidth(CGFloat(5 - 2 * Float(k) / 5))
                ctx.move(to: p0.cg); ctx.addQuadCurve(to: p1.cg, control: (lerp(p0, p1, 0.5) + V2(0, sag)).cg); ctx.strokePath()
            }, { x, y, cov in
                let up = volAt(x, y - 2), dn = volAt(x, y + 2)
                var c = RGB(0.30, 0.20, 0.14) * (0.7 + 0.6 * clamp01(dn - up + 0.5))
                c = c * RGB(0.7, 0.72, 1.0) + RGB(0.5, 0.28, 0.1) * (warmLight(Float(x), Float(y)) * 0.25)
                blend(idx(x, y), c, cov)
            })
            mask(min(p0.x, p1.x) - 4, min(p0.y, p1.y) - 10, max(p0.x, p1.x) + 4, max(p0.y, p1.y) + sag + 2, vol: 2, { ctx in
                ctx.setLineWidth(3)
                ctx.move(to: (p0 + V2(0, -3)).cg); ctx.addQuadCurve(to: (p1 + V2(0, -3)).cg, control: (lerp(p0, p1, 0.5) + V2(0, sag - 3)).cg); ctx.strokePath()
            }, { x, y, cov in blend(idx(x, y), snowRamp(0.3 + 0.7 * snowLitV(x, y, 2)), cov * 0.95) })
        }
    }
    for (p, h) in posts {
        let w: Float = 7 * h / 64
        pool(V2(p.x, p.y + 2), w * 2.5, 4, RGB(0, 0, 0), -0.3)
        mask(p.x - w, p.y - h, p.x + w, p.y, { ctx in
            poly(ctx, [V2(p.x - w, p.y - h + 3), V2(p.x - 1, p.y - h), V2(p.x + w, p.y - h + 4), V2(p.x + w, p.y), V2(p.x - w, p.y)]); ctx.fillPath()
        }, { x, y, cov in
            let fx = Float(x) + 0.5
            var c = mixc(RGB(0.40, 0.29, 0.21), RGB(0.16, 0.11, 0.09), smoothstep(p.x - w, p.x + w, fx))
            c = c * (0.8 + 0.4 * fbm(fx * 0.4, Float(y) * 0.05, 2, 32)) * RGB(0.72, 0.74, 1.0)
            blend(idx(x, y), c, cov)
        })
        mask(p.x - w - 4, p.y - h - 8, p.x + w + 4, p.y - h + 4, vol: 2, { ctx in ctx.fillEllipse(in: ell(V2(p.x, p.y - h), w + 2, 4.5)) },
             { x, y, cov in blend(idx(x, y), snowRamp(0.3 + 0.7 * snowLitV(x, y, 2)), cov) })
        // drift banked against the post
        mask(p.x - 30, p.y - 22, p.x + 30, p.y + 6, vol: 4, { ctx in
            let q = CGMutablePath()
            q.move(to: CGPoint(x: CGFloat(p.x - 28), y: CGFloat(p.y + 4)))
            q.addCurve(to: CGPoint(x: CGFloat(p.x + 26), y: CGFloat(p.y + 4)),
                       control1: CGPoint(x: CGFloat(p.x - 10), y: CGFloat(p.y - 24 * h / 64)), control2: CGPoint(x: CGFloat(p.x + 6), y: CGFloat(p.y - 22 * h / 64)))
            q.closeSubpath(); ctx.addPath(q); ctx.fillPath()
        }, { x, y, cov in
            let fy = Float(y) + 0.5
            let c = snowRamp(0.35 + 0.6 * snowLitV(x, y, 4)) + warm * (warmLight(Float(x), fy) * 0.25)
            blend(idx(x, y), c, cov * (1 - smoothstep(p.y - 2, p.y + 4, fy)))
        })
    }
}

// snowman beside the path: volume-shaded snowballs, scarf, carrot, stick arms
do {
    let base = V2(1166, 1606)
    pool(V2(base.x, base.y), 50, 8, RGB(0, 0, 0), -0.35)
    let balls: [(V2, Float)] = [(base + V2(0, -42), 46), (base + V2(2, -110), 33), (base + V2(4, -160), 23)]
    mask(base.x - 60, base.y - 190, base.x + 60, base.y + 6, vol: 9, { ctx in
        for (c, r) in balls { ctx.fillEllipse(in: ell(c, r, r * 0.96)) }
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        var lit = snowLitV(x, y, 9)
        for (c, r) in balls {
            let d = hypotf(fx - c.x, fy - c.y) / r
            if d < 1 { lit = min(lit, 0.25 + 0.9 * clamp01(1 - ((fy - c.y) / r + 1) * 0.5 + 0.3 * (fx - c.x) / r)) }
        }
        var c = snowRamp(clamp01(lit))
        c = c * (0.95 + 0.1 * fbm(fx * 0.1, fy * 0.1, 3, 41))
        c = c + warm * (warmLight(fx, fy) * 0.55 * clamp01(0.4 + (base.x - fx) / 60))
        blend(idx(x, y), c, cov)
    })
    // scarf
    let sc = base + V2(2, -136)
    mask(sc.x - 30, sc.y - 10, sc.x + 34, sc.y + 44, vol: 2, { ctx in
        ctx.fillEllipse(in: ell(sc, 27, 8))
        poly(ctx, [sc + V2(8, 2), sc + V2(20, 2), sc + V2(26, 38), sc + V2(14, 40)]); ctx.fillPath()
    }, { x, y, cov in
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        var c = RGB(0.70, 0.13, 0.12) * (0.6 + 0.7 * snowLitV(x, y, 2))
        if Int((fx + fy) / 6) % 3 == 0 { c = c * 0.75 }
        c = c + warm * (warmLight(fx, fy) * 0.25)
        blend(idx(x, y), c, cov)
    })
    let head = balls[2].0
    for e in [V2(-8, -5), V2(5, -6)] { dot(head.x + e.x, head.y + e.y, 2.4, RGB(0.04, 0.04, 0.05), 1) }
    for k in 0..<5 { dot(head.x - 12 + Float(k) * 5, head.y + 9 + 2 * sinf(Float(k) * 0.8), 1.4, RGB(0.05, 0.05, 0.06), 1) }
    for k in 0..<3 { dot(balls[1].0.x - 2, balls[1].0.y - 8 + Float(k) * 13, 3, RGB(0.04, 0.04, 0.05), 1) }
    mask(head.x - 34, head.y - 6, head.x, head.y + 6, { ctx in
        poly(ctx, [V2(head.x - 3, head.y - 4), V2(head.x - 32, head.y + 1), V2(head.x - 3, head.y + 3)]); ctx.fillPath()
    }, { x, y, cov in blend(idx(x, y), RGB(0.95, 0.45, 0.10) * (Float(y) < head.y ? 1.05 : 0.8), cov) })
    mask(base.x - 90, base.y - 150, base.x + 90, base.y - 80, { ctx in
        ctx.setLineWidth(3)
        let l0 = balls[1].0 + V2(-28, -6), r0 = balls[1].0 + V2(30, -8)
        ctx.move(to: l0.cg); ctx.addLine(to: (l0 + V2(-48, -30)).cg); ctx.strokePath()
        ctx.move(to: (l0 + V2(-30, -19)).cg); ctx.addLine(to: (l0 + V2(-40, -38)).cg); ctx.strokePath()
        ctx.move(to: r0.cg); ctx.addLine(to: (r0 + V2(46, -20)).cg); ctx.strokePath()
        ctx.move(to: (r0 + V2(34, -15)).cg); ctx.addLine(to: (r0 + V2(42, -32)).cg); ctx.strokePath()
    }, { x, y, cov in blend(idx(x, y), RGB(0.16, 0.10, 0.08), cov) })
}

// door light cone over the steps and onto the snow, window glow pools, lantern pools
do {
    mask(640, 1458, 1060, 1720, blur: 10, { ctx in
        poly(ctx, [V2(838, 1458), V2(850, 1458), V2(1010, 1700), V2(800, 1700)]); ctx.fillPath()
    }, { x, y, cov in
        let t = clamp01((Float(y) - 1458) / 242)
        addLight(idx(x, y), RGB(0.62, 0.42, 0.18), cov * 0.55 * (1 - 0.7 * t))
    })
    pool(V2(820, 1540), 260, 70, RGB(1.0, 0.66, 0.30), 0.20, minY: 1500)
    pool(V2(700, 1512), 150, 30, RGB(1.0, 0.66, 0.30), 0.14, minY: 1495)
    pool(V2(950, 1512), 150, 30, RGB(1.0, 0.66, 0.30), 0.12, minY: 1495)
    pool(V2(1210, 1480), 200, 40, RGB(1.0, 0.66, 0.30), 0.12, minY: 1450)
    pool(V2(1452, 1612), 170, 44, RGB(1.0, 0.66, 0.30), 0.22, minY: 1560)
    // warm glints in the lit snow
    var rng = Rng(s: 6161)
    for _ in 0..<160 {
        let x = rng.range(560, 1700), y = rng.range(1505, 1660)
        let wl = warmLight(x, y)
        if wl < 0.22 { continue }
        dot(x, y, rng.range(0.8, 1.6), RGB(1.0, 0.86, 0.62), min(wl, 1) * rng.range(0.4, 1.0), additive: true)
    }
}

// MARK: - 8. Chimney smoke (drifting left, away from the calm right side)

do {
    let sx = chimB.x, sy = chimTop - 10
    let rise: Float = 480
    for y in max(Int(sy - rise - 120), 0)..<Int(sy + 4) {
        let fy = Float(y)
        let t = clamp01((sy - fy) / rise)
        let cx = sx - 200 * powf(t, 1.4) + 24 * sinf(t * 6.5)
        let r = 9 + 80 * powf(t, 0.85)
        let fade = smoothstep(0, 0.04, t) * (1 - smoothstep(0.30, 1.0, t))
        if fade <= 0 { continue }
        for x in max(Int(cx - r * 2.5), 0)..<min(Int(cx + r * 2.5), W) {
            let fx = Float(x)
            let wx = fbm(fx * 0.006, fy * 0.006, 3, 2025) - 0.5
            let dx = (fx + wx * r * 1.6 - cx) / r
            let wisp = fbm(fx * 0.010 + wx, fy * 0.007, 4, 2024)
            let v = expf(-dx * dx * 1.3) * (0.45 + 1.1 * smoothstep(0.35, 0.75, wisp))
            let lit = clamp01((fx - cx) / r * 0.5 + 0.5)        // moonlit right side
            blend(idx(x, y), mixc(RGB(0.50, 0.48, 0.68), RGB(0.74, 0.73, 0.88), lit), v * fade * 0.22)
        }
    }
}

// MARK: - 9. Foreground

let crest4 = { (x: Float) -> Float in
    1702 - 12 * smoothstep(1800, 2900, x) + 10 * sinf(x * 0.003) + 8 * (fbm(x * 0.002, 4.4, 3, 81) - 0.5)
}
snowLayer(crest: crest4, rim: RGB(0.72, 0.74, 0.96), body: RGB(0.50, 0.52, 0.83), deep: RGB(0.36, 0.38, 0.66),
          deepDist: 260, sculpt: 0.9, seed: 84, warmK: 0.18, calmBelow: dockCalm)

drawPine(cx: 405, base: 1730, h: 1000, hw: 200, tiers: 15, seed: 405,
         body: RGB(0.04, 0.075, 0.12), haze: 0.0, hazeC: hazeC, warmK: 0.7, droopK: 0.20)
drawPine(cx: 120, base: 1770, h: 1720, hw: 360, tiers: 21, seed: 120,
         body: RGB(0.035, 0.065, 0.11), haze: 0.0, hazeC: hazeC, warmK: 0.35)
// near drift burying the framing trunks, sloping out of frame toward the bottom
snowLayer(crest: { x in
    1665 + 0.00030 * powf(max(x - 300, 0), 2) + 0.00018 * powf(min(x - 300, 0), 2) + 10 * (fbm(x * 0.006, 2.2, 3, 91) - 0.5)
}, rim: RGB(0.74, 0.76, 0.97), body: RGB(0.52, 0.54, 0.84), deep: RGB(0.38, 0.40, 0.68),
   deepDist: 240, sculpt: 0.8, seed: 92, warmK: 0, calmBelow: dockCalm, x0: 0, x1: 1500)

// cold glints in the mid-ground snow (none in the Dock strip)
do {
    var rng = Rng(s: 4545)
    for _ in 0..<520 {
        let x = rng.range(200, Float(W) - 40), y = rng.range(1300, dockCalm - 50)
        if y < crest3(x) + 6 { continue }
        let a = powf(rng.next(), 2.5) * 0.7 + 0.08
        let r = rng.range(0.6, 1.3)
        dot(x, y, r, RGB(0.85, 0.90, 1.0), a, additive: true)
        if a > 0.6 { for k in -4...4 { let f = Float(k); dot(x + f, y, 0.6, RGB(0.8, 0.85, 1), 0.08 * (1 - abs(f) / 5), additive: true) } }
    }
}

// MARK: - 10. Snowy pine bough hanging into the top-left corner

do {
    var rng = Rng(s: 6060)
    func limb(_ t: Float) -> V2 { V2(-40 + 860 * t, 22 + 110 * t + 80 * t * t) }
    // side shoots: drooping forward, each with its own sub-shoots
    var shoots: [[V2]] = []
    var t: Float = 0.02
    while t < 0.97 {
        let p = limb(t)
        for sd in [Float(-1), 1] {
            if rng.next() < 0.15 { continue }
            let len = (200 - 140 * t) * rng.range(0.6, 1.0)
            let ang: Float = sd < 0 ? rng.range(-0.75, -0.35) : rng.range(0.55, 1.15)
            var pts: [V2] = [p]
            for k in 1...8 {
                let f = Float(k) / 8
                let droop = len * 0.25 * f * f
                pts.append(p + V2(cosf(ang) * len * f, sinf(ang) * len * f * 0.8 + droop))
            }
            shoots.append(pts)
        }
        t += rng.range(0.045, 0.08)
    }
    var segs: [(V2, V2, Float)] = []
    for k in 0..<48 {
        segs.append((limb(Float(k) / 48), limb(Float(k + 1) / 48), 14 - 10 * Float(k) / 48))
    }
    for sh in shoots { for k in 1..<sh.count { segs.append((sh[k - 1], sh[k], 3.2 - 2.2 * Float(k) / Float(sh.count))) } }
    var needles: [(V2, V2)] = []
    for (a, b, w) in segs {
        let d = b - a, L = d.len, dir = d.norm
        let n = max(Int(L / 2.6), 1)
        for j in 0..<n {
            let p = a + dir * (Float(j) / Float(n) * L)
            for sd in [Float(-1), 1] {
                let nl = rng.range(18, 32) * (w > 6 ? 1.15 : 1.0)
                let ang = atan2f(dir.y, dir.x) + sd * rng.range(0.55, 1.05) + 0.30
                needles.append((p, p + V2(cosf(ang) * nl, sinf(ang) * nl)))
            }
        }
    }
    mask(0, 0, 1060, 520, vol: 5, { ctx in
        for (a, b, w) in segs { ctx.setLineWidth(CGFloat(w)); ctx.move(to: a.cg); ctx.addLine(to: b.cg); ctx.strokePath() }
        ctx.setLineWidth(2.4)
        for (a, b) in needles { ctx.move(to: a.cg); ctx.addLine(to: b.cg) }
        ctx.strokePath()
    }, { x, y, cov in
        let fx = Float(x), fy = Float(y)
        let n = fbm(fx * 0.09, fy * 0.09, 3, 6061)
        var c = RGB(0.045, 0.085, 0.11) * (0.6 + 0.9 * n)
        let up = volAt(x, y - 5), dn = volAt(x, y + 5)
        let lf = volAt(x - 5, y), rt = volAt(x + 5, y)
        c = c + RGB(0.16, 0.19, 0.34) * clamp01((dn - up) * 1.2 + (lf - rt) * 0.9)      // moon rim
        c = c + RGB(0.70, 0.40, 0.16) * (clamp01((up - dn) * 1.4) * 0.30)              // warm rim from below
        blend(idx(x, y), c, cov)
    })
    // heavy snow: a lumpy mantle along the limb top, lighter strips on the shoots
    mask(0, 0, 1060, 520, vol: 6, { ctx in
        var r2 = Rng(s: 6063)
        for k in 0..<48 {
            let t0 = Float(k) / 48, t1 = Float(k + 1) / 48
            let a = limb(t0), b = limb(t1)
            let w = (34 - 22 * t1) * r2.range(0.8, 1.2)
            let off = V2(0, -w * 0.32 - 4)
            ctx.setLineWidth(CGFloat(w)); ctx.move(to: (a + off).cg); ctx.addLine(to: (b + off).cg); ctx.strokePath()
            if r2.next() < 0.35 { ctx.fillEllipse(in: ell(lerp(a, b, 0.5) + V2(0, -w * 0.55), w * 0.9, w * 0.5)) }
        }
        for sh in shoots {
            if r2.next() < 0.2 { continue }
            let n = Int(r2.range(2, 4))
            for k in 1..<min(n, sh.count) {
                let w = r2.range(6, 10) * (1.1 - Float(k) / Float(sh.count))
                let off = V2(0, -w * 0.45)
                ctx.setLineWidth(CGFloat(w)); ctx.move(to: (sh[k - 1] + off).cg); ctx.addLine(to: (sh[k] + off).cg); ctx.strokePath()
            }
        }
    }, { x, y, cov in
        let fx = Float(x), fy = Float(y)
        let lit = snowLitV(x, y, 6)
        var c = snowRamp(clamp01(0.08 + 0.95 * lit + 0.12 * (fbm(fx * 0.05, fy * 0.05, 3, 6062) - 0.5)))
        let under = clamp01((volAt(x, y - 6) - volAt(x, y + 6)) * 1.3)
        c = c + RGB(0.45, 0.25, 0.10) * (under * 0.22)
        blend(idx(x, y), c, cov)
    })
}

// MARK: - 11. Bloom

do {
    let s0 = alloc(), s1 = alloc(), s2 = alloc()
    memcpy(s0, Lr, N * 4); memcpy(s1, Lg, N * 4); memcpy(s2, Lb, N * 4)
    for b in [s0, s1, s2] { boxBlur(b, W, H, 4) }
    let m0 = alloc(), m1 = alloc(), m2 = alloc()
    memcpy(m0, Lr, N * 4); memcpy(m1, Lg, N * 4); memcpy(m2, Lb, N * 4)
    for b in [m0, m1, m2] { boxBlur(b, W, H, 14) }
    for b in [Lr, Lg, Lb] { boxBlur(b, W, H, 46) }
    for i in 0..<N {
        Rb[i] += s0[i] * 0.80 + m0[i] * 0.70 + Lr[i] * 1.5
        Gb[i] += s1[i] * 0.80 + m1[i] * 0.70 + Lg[i] * 1.5
        Bb[i] += s2[i] * 0.80 + m2[i] * 0.70 + Lb[i] * 1.5
    }
    // wide cozy halo around the cabin (warm vs. the cool night)
    for y in 850..<1800 {
        for x in 250..<2000 {
            let dx = (Float(x) - 900) / 620, dy = (Float(y) - 1380) / 320
            let v = expf(-(dx * dx + dy * dy))
            addLight(idx(x, y), RGB(0.9, 0.5, 0.25), v * 0.05)
        }
    }
}

// MARK: - 12. Falling snow (sparse, soft; kept out of the Dock strip and notch)

do {
    var rng = Rng(s: 3131)
    for _ in 0..<260 {
        let x = rng.range(0, Float(W)), y = rng.range(0, dockCalm - 40)
        if y < 110 && abs(x - 1470) < 440 { continue }
        let r = powf(rng.next(), 2) * 2.4 + 0.9
        dot(x, y, r, RGB(0.88, 0.90, 1.0), rng.range(0.35, 0.75))
    }
    for _ in 0..<10 {
        let x = rng.range(40, 1000), y = rng.range(480, 1300)
        dot(x, y, rng.range(5, 9), RGB(0.80, 0.84, 1.0), rng.range(0.10, 0.22))
    }
}

// MARK: - 13. Painterly finish, vignette, dither, encode

let out = UnsafeMutablePointer<UInt8>.allocate(capacity: N * 4)
do {
    var rng = Rng(s: 1)
    let ca: Float = cosf(0.5), sa: Float = sinf(0.5)
    for y in 0..<H {
        for x in 0..<W {
            let i = y * W + x
            let fx = Float(x), fy = Float(y)
            let nx = (fx / Float(W) - 0.45) * 2, ny = (fy / Float(H) - 0.5) * 2
            let v = 1 - 0.20 * smoothstep(0.6, 1.8, nx * nx * 0.7 + ny * ny * 0.9)
            // brush-stroke texture: anisotropic noise along a diagonal stroke direction
            let ru = fx * ca + fy * sa, rv = -fx * sa + fy * ca
            let brush = fbm(ru * 0.006, rv * 0.045, 3, 7) - 0.5
            let bristle = fbm(ru * 0.02, rv * 0.25, 2, 8) - 0.5
            let paper = fbm(fx * 0.09, fy * 0.09, 2, 9) - 0.5
            let lum = 1 + brush * 0.050 + bristle * 0.022 + paper * 0.016
            let tint = brush * 0.02
            let dith = (rng.next() + rng.next() - 1) / 255
            func q(_ c: Float, _ k: Float) -> UInt8 {
                let m = c * v * lum * k
                let s = m < 0.82 ? m : 0.82 + (1 - expf(-(m - 0.82) * 4)) * 0.18
                return UInt8(clamp01(s + dith) * 255 + 0.5)
            }
            out[i * 4] = q(Rb[i], 1 + tint); out[i * 4 + 1] = q(Gb[i], 1); out[i * 4 + 2] = q(Bb[i], 1 - tint); out[i * 4 + 3] = 255
        }
    }
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("winter-cabin.png").path
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let octx = CGContext(data: out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                     space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let img = octx.makeImage()!
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot create \(outPath)")
}
CGImageDestinationAddImage(dest, img, nil)
if !CGImageDestinationFinalize(dest) { fatalError("PNG write failed") }
print("wrote \(outPath) (\(W)x\(H))")
