// generate_wallpaper.swift
// Procedural "winter night" desktop wallpaper (original composition).
// Build & run:
//   swiftc -O generate_wallpaper.swift -o /tmp/genwall && /tmp/genwall [output.png]
// Output: 2940x1912 PNG (MacBook Air 1470x956pt @2x).
// Everything is deterministic (fixed seeds), so the image is reproducible.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let W = 2940
let H = 1912
let N = W * H

// MARK: - Basic math

struct RGB { var r: Float; var g: Float; var b: Float
    init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    static func * (a: RGB, s: Float) -> RGB { RGB(a.r * s, a.g * s, a.b * s) }
    static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
}
@inline(__always) func clamp01(_ v: Float) -> Float { v < 0 ? 0 : (v > 1 ? 1 : v) }
@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func mixc(_ a: RGB, _ b: RGB, _ t: Float) -> RGB {
    RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
}
@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clamp01((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
}
@inline(__always) func fract(_ x: Float) -> Float { x - floorf(x) }

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

// MARK: - Canvas

let Rb = UnsafeMutablePointer<Float>.allocate(capacity: N)
let Gb = UnsafeMutablePointer<Float>.allocate(capacity: N)
let Bb = UnsafeMutablePointer<Float>.allocate(capacity: N)
Rb.initialize(repeating: 0, count: N); Gb.initialize(repeating: 0, count: N); Bb.initialize(repeating: 0, count: N)

@inline(__always) func blend(_ i: Int, _ c: RGB, _ a: Float) {
    if a <= 0 { return }
    let t = a > 1 ? 1 : a
    Rb[i] += (c.r - Rb[i]) * t; Gb[i] += (c.g - Gb[i]) * t; Bb[i] += (c.b - Bb[i]) * t
}
@inline(__always) func addLight(_ i: Int, _ c: RGB, _ a: Float) {
    Rb[i] += c.r * a; Gb[i] += c.g * a; Bb[i] += c.b * a
}
@inline(__always) func getc(_ i: Int) -> RGB { RGB(Rb[i], Gb[i], Bb[i]) }

/// Separable box blur, repeated `passes` times (~gaussian).
func boxBlur(_ buf: UnsafeMutablePointer<Float>, _ w: Int, _ h: Int, _ r: Int, passes: Int = 3) {
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

// MARK: - Layout constants

let shoreY: Float = 1096          // far shore of the frozen lake
let moonX: Float = 2240, moonY: Float = 318, moonR: Float = 74
let dockLine: Float = Float(H) * 0.88   // bottom 12% stays calm

// MARK: - 1. Sky

do {
    let top = RGB(0.030, 0.040, 0.120)
    let mid = RGB(0.085, 0.080, 0.230)
    let low = RGB(0.235, 0.190, 0.420)
    let hor = RGB(0.360, 0.290, 0.540)
    for y in 0..<Int(shoreY) + 2 {
        let t = Float(y) / shoreY
        var c: RGB
        if t < 0.45 { c = mixc(top, mid, smoothstep(0, 0.45, t)) }
        else if t < 0.8 { c = mixc(mid, low, smoothstep(0.45, 0.8, t)) }
        else { c = mixc(low, hor, smoothstep(0.8, 1.0, t)) }
        for x in 0..<W {
            let fx = Float(x), fy = Float(y)
            // soft violet cloud veils, very low contrast
            let n = fbm(fx * 0.0011, fy * 0.0028, 5, 11)
            let veil = smoothstep(0.45, 0.75, n) * 0.06 * (0.4 + t)
            // moon glow
            let dx = fx - moonX, dy = fy - moonY
            let d = sqrtf(dx * dx + dy * dy)
            let glow = 0.30 * expf(-max(d - moonR, 0) / 70) + 0.14 * expf(-d / 380)
            let i = y * W + x
            Rb[i] = c.r + veil * 0.55 + glow * 0.55
            Gb[i] = c.g + veil * 0.45 + glow * 0.58
            Bb[i] = c.b + veil * 0.90 + glow * 0.85
        }
    }
}

// MARK: - 2. Stars

do {
    var rng = Rng(s: 20261118)
    for _ in 0..<2300 {
        let x = rng.range(0, Float(W))
        let y = powf(rng.next(), 1.5) * 880
        let dm = hypotf(x - moonX, y - moonY)
        var b = powf(rng.next(), 3.2)
        b *= smoothstep(moonR + 40, moonR + 320, dm) * (1 - smoothstep(500, 900, y))
        if b < 0.02 { continue }
        let rad: Float = 0.6 + b * 1.6
        let tintT = rng.next()
        let col = tintT < 0.2 ? RGB(1.0, 0.88, 0.75) : (tintT < 0.6 ? RGB(0.80, 0.86, 1.0) : RGB(0.95, 0.95, 1.0))
        let ext = Int(rad * 5 + 2)
        let cx = Int(x), cy = Int(y)
        for py in max(cy - ext, 0)...min(cy + ext, H - 1) {
            for px in max(cx - ext, 0)...min(cx + ext, W - 1) {
                let dx = Float(px) + 0.5 - x, dy = Float(py) + 0.5 - y
                let d2 = dx * dx + dy * dy
                let core = expf(-d2 / (rad * rad * 0.7))
                let halo = b > 0.55 ? 0.12 * expf(-sqrtf(d2) / (rad * 2.2)) : 0
                addLight(py * W + px, col, (core * 0.95 + halo) * b)
            }
        }
    }
}

// MARK: - 3. Crescent moon

do {
    let sx = moonX - 34, sy = moonY - 22, sr = moonR * 0.93   // shadow disc
    let lit = RGB(1.0, 0.965, 0.86)
    for y in Int(moonY - moonR - 3)...Int(moonY + moonR + 3) {
        for x in Int(moonX - moonR - 3)...Int(moonX + moonR + 3) {
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let d = hypotf(fx - moonX, fy - moonY)
            let inDisc = clamp01(moonR - d + 0.5)
            if inDisc <= 0 { continue }
            let ds = hypotf(fx - sx, fy - sy)
            let inShadow = smoothstep(-1.5, 1.5, sr - ds)
            let i = y * W + x
            // faint earthshine on the dark limb
            blend(i, RGB(0.17, 0.17, 0.33), inDisc * inShadow * 0.35)
            let tex = 0.92 + 0.08 * fbm(fx * 0.05, fy * 0.05, 3, 5)
            blend(i, lit * tex, inDisc * (1 - inShadow))
        }
    }
}

// MARK: - 4. Mountain ranges (fractal ridgelines, moonlit faces)

/// Mountain ridgeline height (0..~1.2): a few big massifs (jittered triangles,
/// combined with max so summits stay sharp) plus ridged fractal detail.
func ridgeHeight(_ x: Float, _ freq: Float, _ seed: UInt32) -> Float {
    // massifs on a jittered grid of cells
    let cell: Float = 0.55 / freq
    let ci = Int(floorf(x / cell))
    var m: Float = 0
    for k in (ci - 3)...(ci + 3) {
        let hk = Int32(truncatingIfNeeded: k)
        let px = (Float(k) + 0.2 + 0.6 * hash2(hk, 1, seed)) * cell
        let ph = 0.35 + 0.65 * powf(hash2(hk, 2, seed), 1.4)
        let pw = cell * (0.9 + 1.1 * hash2(hk, 3, seed))
        let skew: Float = hash2(hk, 4, seed) < 0.5 ? 0.8 : 1.25    // asymmetric flanks
        let xj = x + (fbm(x * freq * 2.5, 5.5, 3, seed &+ 40) - 0.5) * pw * 0.35
        let dx = xj - px
        let d = dx < 0 ? -dx * skew : dx / skew
        let v = max(0, 1 - d / pw)
        m = max(m, ph * powf(v, 1.25))
    }
    // ridged detail, stronger near summits
    var r: Float = 0, amp: Float = 1, f = freq * 3, sum: Float = 0
    for o in 0..<6 {
        let n = vnoise(x * f, Float(o) * 3.7, seed &+ UInt32(o))
        let rr = 1 - abs(n * 2 - 1)
        r += rr * rr * amp; sum += amp
        amp *= 0.5; f *= 2.1
    }
    r /= sum
    return m + (r - 0.35) * (0.10 + 0.22 * m)
}

struct RangeStyle {
    var baseY: Float; var amp: Float; var freq: Float; var seed: UInt32
    var lit: RGB; var shadow: RGB; var rock: RGB; var mist: RGB
    var haze: Float; var mistDepth: Float; var bottomY: Int
}

func drawRange(_ s: RangeStyle) {
    let margin = 700
    var top = [Float](repeating: 0, count: W + 2 * margin)
    for k in 0..<top.count {
        top[k] = s.baseY - s.amp * ridgeHeight(Float(k - margin), s.freq, s.seed)
    }
    @inline(__always) func topAt(_ x: Float) -> Float {
        let k = min(max(Int(x) + margin, 0), top.count - 1); return top[k]
    }
    for x in 0..<W {
        let ty = top[x + margin]
        let y0 = max(Int(ty) - 1, 0)
        for y in y0..<s.bottomY {
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let cov = clamp01(fy - ty + 0.5)
            if cov <= 0 { continue }
            let d = max(fy - ty, 0)
            // follow the ridge structure down the face, wandering with depth
            let jit = (fbm(fx * 0.0045, fy * 0.006, 3, s.seed &+ 7) - 0.5) * d * 0.9
            let xs = fx + jit
            let e: Float = 2 + d * 0.22
            let slope = (topAt(xs + e) - topAt(xs - e)) / (2 * e)
            let micro = (fbm(fx * 0.02, fy * 0.035, 3, s.seed &+ 13) - 0.5) * 0.5
            let light = smoothstep(-0.12, 0.22, slope + micro)
            var c = mixc(s.shadow, s.lit, light)
            // rock streaks: vertical-ish gullies, mostly on shadow faces
            let gully = fbm(fx * 0.03, fy * 0.007, 4, s.seed &+ 21)
            let rockAmt = smoothstep(0.58, 0.72, gully) * (0.85 - 0.55 * light) * smoothstep(6, 40, d)
            c = mixc(c, s.rock, rockAmt * 0.8)
            // brighter near summit
            c = c * (1.0 + 0.10 * (1 - smoothstep(0, 120, d)) * light)
            // atmospheric mist toward the base and overall haze
            let m = smoothstep(s.mistDepth * 0.25, s.mistDepth, d)
            c = mixc(c, s.mist, clamp01(s.haze + m * 0.85))
            blend(y * W + x, c, cov)
        }
    }
}

drawRange(RangeStyle(baseY: 930, amp: 470, freq: 0.0011, seed: 101,
                     lit: RGB(0.62, 0.64, 0.88), shadow: RGB(0.30, 0.29, 0.56),
                     rock: RGB(0.25, 0.23, 0.46), mist: RGB(0.33, 0.29, 0.56),
                     haze: 0.38, mistDepth: 380, bottomY: 1000))

// soft mist band between ranges
func mistBand(_ cy: Float, _ height: Float, _ c: RGB, _ amt: Float, _ seed: UInt32) {
    for y in max(Int(cy - height * 2), 0)..<min(Int(cy + height * 2), H) {
        let fy = Float(y)
        let v = expf(-powf((fy - cy) / height, 2))
        for x in 0..<W {
            let n = fbm(Float(x) * 0.0018, fy * 0.01, 4, seed)
            blend(y * W + x, c, v * amt * (0.55 + 0.9 * (n - 0.5) + 0.45))
        }
    }
}
mistBand(900, 55, RGB(0.36, 0.32, 0.60), 0.45, 301)

drawRange(RangeStyle(baseY: 1050, amp: 360, freq: 0.0016, seed: 202,
                     lit: RGB(0.64, 0.68, 0.90), shadow: RGB(0.19, 0.21, 0.43),
                     rock: RGB(0.14, 0.15, 0.32), mist: RGB(0.29, 0.27, 0.53),
                     haze: 0.10, mistDepth: 330, bottomY: 1080))

mistBand(985, 40, RGB(0.32, 0.30, 0.57), 0.40, 302)

// MARK: - 5. Near forested hills + pine forest

/// Draws a snow-laden pine/fir. Tiered drooping silhouette with 2D-noise edges;
/// snow sits on every upward-facing surface (pixels whose "above" neighbour is outside).
func drawPine(cx: Float, base: Float, h: Float, halfW: Float, body: RGB, snowC: RGB,
              snowAmt: Float, tiers: Int, seed: UInt32, edgeNoise: Float = 0.14, trunk: RGB? = nil) {
    let foliageEnd: Float = 0.92
    let tierF = Float(tiers)
    let scale = max(h / 600, 0.22)
    // tier phase (0 at the top of a tier, 1 at its drooping lower edge) and base half-width
    let tierPx = h * foliageEnd / tierF
    @inline(__always) func shape(_ fy: Float, _ adx: Float) -> (w: Float, f: Float) {
        let t = (base - fy) / h
        if t < 0 || t > 1 { return (-1, 0) }
        let u = 1 - t
        if u > foliageEnd { return (-1, 0) }
        let uu = u / foliageEnd
        let env = halfW * powf(uu, 0.9)
        // branch tips droop: outer pixels belong to the tier above for longer
        let rel = min(adx / max(env, 1), 1.3)
        let fyE = fy - 0.45 * tierPx * rel * rel
        let uE = max((1 - (base - fyE) / h) / foliageEnd, 0)
        let f = fract(powf(uE, 0.85) * tierF)
        return (env * (0.48 + 0.52 * powf(f, 0.65)), f)
    }
    // signed distance-ish: >0 inside the silhouette
    @inline(__always) func inside(_ fx: Float, _ fy: Float) -> Float {
        let (w, _) = shape(fy, abs(fx - cx))
        if w < 0 { return -1e3 }
        let n1 = fbm(fx * 0.022 / scale, fy * 0.03 / scale, 3, seed) - 0.5
        let n2 = vnoise(fx * 0.12 / scale, fy * 0.12 / scale, seed &+ 3) - 0.5
        let n3 = vnoise(fx * 0.35, fy * 0.35, seed &+ 6) - 0.5
        let wn = w * (1 + edgeNoise * (n1 * 1.8 + n2 * 1.1)) + n3 * min(4, 1 + scale * 1.5)
        return wn - abs(fx - cx)
    }
    let x0 = max(Int(cx - halfW * 1.3 - 2), 0), x1 = min(Int(cx + halfW * 1.3 + 2), W - 1)
    let y0 = max(Int(base - h - 2), 0), y1 = min(Int(base + 1), H - 1)
    if x0 > x1 || y0 > y1 { return }
    let snowK = max(1.6, h * 0.016)    // nominal snow thickness in px
    let trunkW = max(1.0, halfW * 0.07)
    let trunkC = trunk ?? body * 0.9
    for y in y0...y1 {
        let fy = Float(y) + 0.5
        let t = (base - fy) / h
        if t < 0 || t > 1 { continue }
        let (wc, _) = shape(fy, 0)
        for x in x0...x1 {
            let fx = Float(x) + 0.5
            let dx = fx - cx
            let (w0, f) = wc < 0 ? (wc, 0) : shape(fy, abs(dx))
            let i = y * W + x
            if w0 < 0 {
                let cov = clamp01(trunkW - abs(dx) + 0.5)
                if cov > 0 {
                    let lit = smoothstep(-trunkW, trunkW, dx)
                    blend(i, mixc(trunkC, trunkC * 1.8, lit * 0.6), cov)
                }
                continue
            }
            if abs(dx) > w0 * (1 + edgeNoise * 1.4) + 1 { continue }
            let ins = inside(fx, fy)
            let cov = clamp01(ins + 0.5)
            if cov <= 0 { continue }
            // body: darker under the overhang of the tier above, lighter toward drooping tips
            let rel = clamp01(abs(dx) / max(w0, 1))
            var c = body * (0.78 + 0.45 * f * rel)
            if dx > 0 { c = mixc(c, body * 1.9, smoothstep(0.55, 1.0, rel) * 0.35) }   // moonlit side
            let needle = vnoise(fx * 0.18 / scale, fy * 0.3 / scale, seed &+ 4)
            c = c * (0.9 + 0.2 * needle)
            // snow
            let sn = fbm(fx * 0.03 / scale, fy * 0.06 / scale, 3, seed &+ 5)
            let k = snowK * (0.45 + 1.3 * sn)
            let above = inside(fx, fy - k)
            var snow = clamp01(-above + 0.5)
            snow *= smoothstep(0.30, 0.48, sn + (snowAmt - 0.5) * 0.4)
            if snow > 0 {
                let topness = clamp01(-inside(fx, fy - k * 0.45) + 0.5)    // upper crust is brightest
                let side = smoothstep(-w0 * 0.3, w0 * 0.6, dx)
                var sc = mixc(snowC * 0.62, snowC * 0.92, side)
                sc = mixc(sc, snowC * 1.12, topness * (0.4 + 0.6 * side))
                c = mixc(c, sc, snow)
            }
            blend(i, c, cov)
        }
    }
}

let hillBase: Float = 1010
var hillTop = [Float](repeating: 0, count: W)
for x in 0..<W {
    let fx = Float(x)
    hillTop[x] = hillBase - 70 * fbm(fx * 0.0012, 0.7, 4, 404) - 30 * sinf(fx * 0.0016 + 0.8)
}
// hill body (dark, mostly hidden by forest)
for x in 0..<W {
    for y in max(Int(hillTop[x]), 0)..<Int(shoreY) {
        let cov = clamp01(Float(y) + 0.5 - hillTop[x])
        blend(y * W + x, RGB(0.10, 0.11, 0.24), cov)
    }
}

// village clearing range (fewer near-shore trees here)
let villageX0: Float = 880, villageX1: Float = 1520

do {
    var rng = Rng(s: 777)
    // far forest row on hill crest (hazy)
    var x: Float = -20
    while x < Float(W) + 20 {
        let xi = min(max(Int(x), 0), W - 1)
        let base = hillTop[xi] + rng.range(14, 50)
        let h = rng.range(34, 74)
        drawPine(cx: x, base: base, h: h, halfW: h * rng.range(0.22, 0.30),
                 body: RGB(0.13, 0.14, 0.29), snowC: RGB(0.42, 0.44, 0.70),
                 snowAmt: 0.55, tiers: Int(rng.range(5, 8)), seed: UInt32(rng.next() * 1e6))
        x += rng.range(5, 12)
    }
    // middle rows filling the slope down to the shore
    for row in 0..<3 {
        x = -20 + Float(row) * 4
        let rf = Float(row)
        while x < Float(W) + 20 {
            let xi = min(max(Int(x), 0), W - 1)
            let span = shoreY - hillTop[xi]
            let base = hillTop[xi] + span * (0.42 + 0.22 * rf) + rng.range(-8, 14)
            let inVillage = x > villageX0 && x < villageX1
            let h = rng.range(42, 96) * (1 + rf * 0.18) * (inVillage ? 0.75 : 1)
            let shade = 0.10 - rf * 0.018
            drawPine(cx: x, base: base, h: h, halfW: h * rng.range(0.22, 0.30),
                     body: RGB(shade, shade + 0.015, shade * 2.1 + 0.02), snowC: RGB(0.44, 0.47, 0.73),
                     snowAmt: 0.6, tiers: Int(rng.range(6, 9)), seed: UInt32(rng.next() * 1e6))
            x += rng.range(6, 13) + rf * 2
        }
    }
}

// MARK: - 6. Shore bank + village

// snowy shore bank
for y in Int(shoreY - 16)..<Int(shoreY + 3) {
    for x in 0..<W {
        let fx = Float(x)
        let edge = shoreY - 9 - 6 * fbm(fx * 0.01, 2, 3, 505)
        let cov = clamp01(Float(y) + 0.5 - edge)
        let shade = 0.85 + 0.15 * fbm(fx * 0.05, Float(y) * 0.2, 2, 506)
        blend(y * W + x, RGB(0.40, 0.43, 0.70) * shade, cov)
    }
}

struct Light { var x: Float; var y: Float; var w: Float; var h: Float; var power: Float }
var lights: [Light] = []
let glowBuf = UnsafeMutablePointer<Float>.allocate(capacity: N)
glowBuf.initialize(repeating: 0, count: N)

func fillRect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: RGB) {
    for y in max(Int(y0) - 1, 0)...min(Int(y1) + 1, H - 1) {
        for x in max(Int(x0) - 1, 0)...min(Int(x1) + 1, W - 1) {
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let cx = clamp01(min(fx - x0, x1 - fx) + 0.5), cy = clamp01(min(fy - y0, y1 - fy) + 0.5)
            blend(y * W + x, c, cx * cy)
        }
    }
}
/// Triangle roof (apex at top) between x0..x1, from baseY up to apexY.
func fillRoof(_ x0: Float, _ x1: Float, _ baseY: Float, _ apexY: Float, _ c: RGB, overhang: Float = 3) {
    let cx = (x0 + x1) / 2, half = (x1 - x0) / 2 + overhang
    for y in max(Int(apexY) - 1, 0)...min(Int(baseY) + 1, H - 1) {
        let fy = Float(y) + 0.5
        let t = (fy - apexY) / (baseY - apexY)
        if t < 0 || t > 1.02 { continue }
        let w = half * t
        let cyc = clamp01(baseY - fy + 0.5)
        for x in max(Int(cx - half) - 1, 0)...min(Int(cx + half) + 1, W - 1) {
            let fx = Float(x) + 0.5
            blend(y * W + x, c, clamp01(w - abs(fx - cx) + 0.5) * cyc)
        }
    }
}
func window(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ power: Float) {
    let warm = RGB(1.0, 0.74, 0.38)
    fillRect(x, y, x + w, y + h, warm * (0.85 + 0.15 * power))
    // tiny muntin cross for larger windows
    if w >= 6 && h >= 7 {
        fillRect(x + w / 2 - 0.5, y, x + w / 2 + 0.5, y + h, RGB(0.45, 0.25, 0.15))
    }
    lights.append(Light(x: x + w / 2, y: y + h / 2, w: w, h: h, power: power))
    for yy in Int(y)..<Int(y + h) { for xx in Int(x)..<Int(x + w) {
        if xx >= 0 && xx < W && yy >= 0 && yy < H { glowBuf[yy * W + xx] += power }
    } }
}

let wall = RGB(0.17, 0.14, 0.24), wallLit = RGB(0.24, 0.19, 0.30)
let roofSnow = RGB(0.68, 0.71, 0.92)

func house(_ x: Float, _ base: Float, _ w: Float, _ wh: Float, _ rh: Float, _ rng: inout Rng) {
    fillRect(x, base - wh, x + w, base, wall)
    fillRect(x + w * 0.62, base - wh, x + w, base, wallLit)   // moonlit side
    fillRoof(x, x + w, base - wh + 1, base - wh - rh, RGB(0.12, 0.10, 0.18), overhang: 4)
    fillRoof(x, x + w, base - wh - 1.5, base - wh - rh, roofSnow, overhang: 3.5)
    // chimney
    if rng.next() < 0.6 {
        let chx = x + w * rng.range(0.6, 0.75)
        fillRect(chx, base - wh - rh * 0.85, chx + 4, base - wh - rh * 0.35, RGB(0.15, 0.12, 0.2))
        fillRect(chx - 0.5, base - wh - rh * 0.85 - 2, chx + 4.5, base - wh - rh * 0.85, roofSnow)
    }
    // windows
    let nWin = w > 44 ? 3 : (w > 30 ? 2 : 1)
    let ww: Float = 6, wwh: Float = 7
    for k in 0..<nWin {
        if rng.next() < 0.18 { continue }   // some dark windows
        let fx = x + (w / Float(nWin + 1)) * Float(k + 1) - ww / 2
        window(fx, base - wh * 0.68, ww, wwh, rng.range(0.6, 1.0))
    }
    // snow piled at base
    fillRect(x - 3, base - 3, x + w + 3, base + 1, RGB(0.42, 0.45, 0.72))
}

do {
    var rng = Rng(s: 4242)
    let base = shoreY - 6
    // houses left of church
    let specs: [(Float, Float, Float, Float, Float)] = [
        (905, 0, 34, 22, 16), (952, 3, 46, 26, 18), (1012, -2, 30, 20, 14),
        (1052, 2, 40, 28, 18), (1335, 1, 42, 26, 17), (1390, -1, 32, 21, 15),
        (1434, 2, 48, 28, 19), (1494, 0, 30, 20, 14)]
    for (x, dy, w, wh, rh) in specs { house(x, base + dy, w, wh, rh, &rng) }
    // church
    let cX: Float = 1150, cW: Float = 92, cH: Float = 40
    fillRect(cX, base - cH, cX + cW, base, wall)
    fillRect(cX + cW * 0.6, base - cH, cX + cW, base, wallLit)
    fillRoof(cX, cX + cW, base - cH + 1, base - cH - 24, RGB(0.12, 0.10, 0.18), overhang: 4)
    fillRoof(cX, cX + cW, base - cH - 1.5, base - cH - 24, roofSnow, overhang: 3.5)
    for k in 0..<3 {
        let wx = cX + 30 + Float(k) * 20
        window(wx, base - cH * 0.75, 6, 13, 0.9)
    }
    // tower
    let tX: Float = cX - 6, tW: Float = 30, tH: Float = 96
    fillRect(tX, base - tH, tX + tW, base, RGB(0.18, 0.15, 0.25))
    fillRect(tX + tW * 0.6, base - tH, tX + tW, base, wallLit)
    window(tX + tW / 2 - 4, base - tH + 18, 8, 14, 1.0)     // belfry
    window(tX + tW / 2 - 3, base - 30, 6, 12, 0.8)
    fillRect(tX - 2, base - tH - 3, tX + tW + 2, base - tH, roofSnow)  // ledge
    // steeple
    fillRoof(tX, tX + tW, base - tH - 2, base - tH - 78, RGB(0.13, 0.11, 0.20), overhang: 1)
    // moonlit right half of steeple: lighter snow dusting
    do {
        let cx = tX + tW / 2
        let apex = base - tH - 78, sb = base - tH - 2
        for y in Int(apex)...Int(sb) {
            let t = (Float(y) + 0.5 - apex) / (sb - apex)
            let w = (tW / 2 + 1) * t
            for x in Int(cx)...Int(cx + w + 1) {
                let fx = Float(x) + 0.5
                let cov = clamp01(cx + w - fx + 0.5) * clamp01(fx - cx)
                let streak = 0.5 + 0.5 * vnoise(fx * 0.6, Float(y) * 0.08, 77)
                blend(y * W + x, RGB(0.50, 0.53, 0.80), cov * 0.55 * streak)
            }
        }
        // cross
        fillRect(cx - 0.8, apex - 14, cx + 0.8, apex + 1, RGB(0.55, 0.50, 0.55))
        fillRect(cx - 4, apex - 10, cx + 4, apex - 8.5, RGB(0.55, 0.50, 0.55))
    }
    // a couple of isolated cabins in the forest
    house(620, shoreY - 4, 30, 19, 13, &rng)
    house(1880, shoreY - 3, 36, 21, 15, &rng)
    house(2240, shoreY - 5, 28, 18, 12, &rng)
    // a few small pines in front of the village for depth
    for px: Float in [940, 1105, 1290, 1470, 1545] {
        let h = rng.range(36, 58)
        drawPine(cx: px, base: shoreY - 2, h: h, halfW: h * 0.26, body: RGB(0.07, 0.08, 0.17),
                 snowC: RGB(0.46, 0.49, 0.76), snowAmt: 0.65, tiers: 6, seed: UInt32(px))
    }
}

// MARK: - 7. Frozen lake with reflections

let fgTop: [Float] = (0..<W).map { x in
    let fx = Float(x)
    return 1405 + (fbm(fx * 0.0016, 4.2, 4, 606) - 0.5) * 80 + 22 * sinf(fx * 0.0023 + 1.1)
        - 150 * expf(-powf(fx / 520, 2))
}

do {
    // blurred snapshot of the scene above the shore for soft reflections
    let refl = [UnsafeMutablePointer<Float>.allocate(capacity: N),
                UnsafeMutablePointer<Float>.allocate(capacity: N),
                UnsafeMutablePointer<Float>.allocate(capacity: N)]
    refl[0].update(from: Rb, count: N); refl[1].update(from: Gb, count: N); refl[2].update(from: Bb, count: N)
    for b in refl { boxBlur(b, W, H, 3, passes: 2) }

    // light glow buffers (village halo)
    let glowWide = UnsafeMutablePointer<Float>.allocate(capacity: N)
    glowWide.update(from: glowBuf, count: N)
    boxBlur(glowBuf, W, H, 6)
    boxBlur(glowWide, W, H, 26)

    let ice = RGB(0.20, 0.21, 0.42), iceSnow = RGB(0.40, 0.42, 0.68)
    let warm = RGB(1.0, 0.62, 0.28)
    for y in Int(shoreY)..<H {
        let fy = Float(y) + 0.5
        let dist = fy - shoreY
        let my = shoreY - dist * 1.0 - 2
        for x in 0..<W {
            if fy > fgTop[x] + 20 { continue }   // hidden under foreground
            let fx = Float(x) + 0.5
            let i = y * W + x
            // horizontal ice texture
            let streak = fbm(fx * 0.0015, fy * 0.045, 4, 707)
            let wob = (vnoise(fx * 0.01, fy * 0.2, 708) - 0.5) * 6
            var c = RGB(0, 0, 0)
            let sx = min(max(Int(fx + wob), 0), W - 1)
            let syI = min(max(Int(my), 0), H - 1)
            let ri = syI * W + sx
            c = RGB(refl[0][ri], refl[1][ri], refl[2][ri])
            c = RGB(c.r * 0.62, c.g * 0.66, c.b * 0.80)
            // ice surface with snowy patches
            let patch = smoothstep(0.52, 0.72, fbm(fx * 0.0022, fy * 0.010, 5, 709))
            let base = mixc(ice, iceSnow, patch * 0.8 + 0.12 * streak)
            let reflAmt = (0.52 - 0.30 * patch) * (1 - 0.35 * smoothstep(0, 300, dist))
            c = mixc(base, c, reflAmt)
            c = c * (0.94 + 0.12 * streak)
            // light streaks: glow stretched vertically below each light
            let gy = shoreY - dist * 0.22 - 6
            let gyI = min(max(Int(gy), 0), H - 1)
            let ripple = 0.35 + 0.65 * smoothstep(0.3, 0.75, vnoise(fx * 0.06, fy * 0.33, 710))
            let gl = glowBuf[gyI * W + x] * 3.2 + glowWide[gyI * W + x] * 1.2
            let fade = expf(-dist / 200) * (1 - 0.6 * patch)
            c = c + warm * (gl * ripple * fade)
            Rb[i] = c.r; Gb[i] = c.g; Bb[i] = c.b
        }
    }
    // thin bright ice edge at the shore
    for y in Int(shoreY)..<Int(shoreY + 4) { for x in 0..<W {
        blend(y * W + x, RGB(0.46, 0.49, 0.76), 0.35 * (1 - Float(y - Int(shoreY)) / 4))
    } }
    // village halo above lights
    for y in 0..<Int(shoreY + 4) { for x in 0..<W {
        let i = y * W + x
        let g = glowBuf[i] * 0.5 + glowWide[i] * 2.2
        if g > 0.0005 { addLight(i, RGB(1.0, 0.62, 0.30), g) }
    } }
    for b in refl { b.deallocate() }
    glowWide.deallocate()
}

// MARK: - 8. Foreground snow with drifts

do {
    let snowTop = RGB(0.47, 0.50, 0.78), snowLow = RGB(0.33, 0.35, 0.60)
    let drifts: [(Float, Float, Float, UInt32)] = [  // (baseY, amp, freq, seed)
        (1470, 26, 0.0021, 801), (1560, 30, 0.0016, 802), (1640, 22, 0.0012, 803)]
    for x in 0..<W {
        let ft = fgTop[x]
        for y in max(Int(ft) - 1, 0)..<H {
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let cov = clamp01(fy - ft + 0.5)
            let i = y * W + x
            let t = smoothstep(ft, Float(H), fy)
            var c = mixc(snowTop, snowLow, powf(t, 0.8))
            // rim highlight along the top of the bank
            let rim = expf(-(fy - ft) / 6) * 0.25
            c = c * (1 + rim)
            // drift ridges: highlight above crest, soft shadow below
            let calm = 1 - smoothstep(dockLine - 70, dockLine + 10, fy)
            for (dy, amp, fr, sd) in drifts {
                let crest = dy + amp * (fbm(fx * fr, 1.0, 3, sd) - 0.5) * 2 + 14 * sinf(fx * fr * 2.2 + Float(sd))
                let d = fy - crest
                let strength = 0.35 + 0.65 * fbm(fx * 0.0012, 2.0, 2, sd &+ 50)
                if d < 0 { c = c * (1 + 0.07 * expf(d / 10) * strength * calm) }
                else { c = c * (1 - 0.10 * expf(-d / 34) * (1 - expf(-d / 3)) * strength * calm) }
            }
            // gentle large-scale undulation + fine grain
            let und = fbm(fx * 0.0012, fy * 0.003, 4, 820) - 0.5
            c = c * (1 + und * (0.10 * calm + 0.03))
            blend(i, c, cov)
        }
    }
    // sparkles
    var rng = Rng(s: 9090)
    for _ in 0..<420 {
        let x = Int(rng.range(0, Float(W)))
        let ft = fgTop[min(max(x, 0), W - 1)]
        let y = Int(rng.range(ft + 6, dockLine - 30))
        if y <= Int(ft) { continue }
        let b = powf(rng.next(), 2) * 0.6
        addLight(y * W + x, RGB(0.85, 0.9, 1.0), b)
        if b > 0.3 {
            for (ox, oy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                addLight((y + oy) * W + x + ox, RGB(0.85, 0.9, 1.0), b * 0.3)
            }
        }
    }
}

// MARK: - 9. Wooden fence

do {
    var rng = Rng(s: 3131)
    // snapshot of the bare snow so the base drift can bury the posts cleanly
    let snapR = UnsafeMutablePointer<Float>.allocate(capacity: N); snapR.update(from: Rb, count: N)
    let snapG = UnsafeMutablePointer<Float>.allocate(capacity: N); snapG.update(from: Gb, count: N)
    let snapB = UnsafeMutablePointer<Float>.allocate(capacity: N); snapB.update(from: Bb, count: N)
    defer { snapR.deallocate(); snapG.deallocate(); snapB.deallocate() }
    let wood = RGB(0.16, 0.11, 0.16), woodLit = RGB(0.30, 0.21, 0.23)
    let snow = RGB(0.62, 0.66, 0.92)
    var posts: [(Float, Float, Float, Float)] = []   // x, baseY, height, width
    var x: Float = 640
    while x < 1640 {
        let t = (x - 640) / 1000
        let base = mixf(1585, 1488, t) + rng.range(-4, 4)
        let ph = mixf(118, 66, t) * rng.range(0.92, 1.06)
        let pw = mixf(15, 9, t)
        posts.append((x, base, ph, pw))
        x += mixf(118, 84, t) * rng.range(0.92, 1.08)
    }
    // rails between posts
    for k in 0..<(posts.count - 1) {
        let (xa, ba, ha, wa) = posts[k], (xb, bb, hb, _) = posts[k + 1]
        for frac: Float in [0.38, 0.76] {
            let ya = ba - ha * frac, yb = bb - hb * frac
            let th = wa * 0.5
            for xi in Int(xa)...Int(xb) {
                let fx = Float(xi) + 0.5
                let tt = (fx - xa) / (xb - xa)
                let sag = sinf(tt * .pi) * 3
                let yc = mixf(ya, yb, tt) + sag
                for yi in Int(yc - th - 2)...Int(yc + th + 2) {
                    let fy = Float(yi) + 0.5
                    let cov = clamp01(th - abs(fy - yc) + 0.5)
                    let grain = 0.9 + 0.2 * vnoise(fx * 0.08, fy * 0.9, 31)
                    var c = mixc(wood, woodLit, smoothstep(yc + th, yc - th, fy) * 0.5) * grain
                    // snow line on top of rail
                    let snowTop = yc - th
                    let sCov = clamp01(snowTop - fy + 0.5) * clamp01(fy - (snowTop - 3.2) + 0.5)
                    let lump = vnoise(fx * 0.07, 2, 33)
                    if lump > 0.3 { c = mixc(c, snow, 0) }
                    blend(yi * W + xi, c, cov)
                    if lump > 0.3 { blend(yi * W + xi, snow, sCov) }
                }
            }
        }
    }
    // posts
    for (px, base, ph, pw) in posts {
        let tilt = rng.range(-0.04, 0.04)
        let top = base - ph
        for yi in Int(top - 8)...Int(base + 2) {
            let fy = Float(yi) + 0.5
            let cxp = px + (base - fy) * tilt
            for xi in Int(cxp - pw)...Int(cxp + pw) {
                let fx = Float(xi) + 0.5
                let dx = fx - cxp
                let i = yi * W + xi
                // rounded snow cap
                let capC = top - pw * 0.25
                let capD = hypotf(dx / (pw * 0.62), (fy - capC) / (pw * 0.42))
                if fy < top + 1 {
                    blend(i, mixc(snow, snow * 1.12, dx > 0 ? 1 : 0.3), clamp01((1 - capD) * pw * 0.5))
                    continue
                }
                let cov = clamp01(pw / 2 - abs(dx) + 0.5)
                let grain = 0.85 + 0.3 * vnoise(fx * 0.25, fy * 0.03, 41)
                let c = mixc(wood, woodLit, smoothstep(-pw * 0.1, pw * 0.4, dx)) * grain
                blend(i, c, cov)
            }
        }
    }
    // snow drifted along the fence base, burying the post feet
    for xi in 560..<1720 {
        let fx = Float(xi) + 0.5
        let t = (fx - 640) / 1000
        let line = mixf(1585, 1488, t) - 8 + 8 * (vnoise(fx * 0.012, 5, 51) - 0.5) * 2
        let fade = smoothstep(560, 640, fx) * (1 - smoothstep(1620, 1720, fx))
        for yi in Int(line - 2)...Int(line + 40) {
            let fy = Float(yi) + 0.5
            let i = yi * W + xi
            let cov = clamp01(fy - line + 0.5) * fade * (1 - smoothstep(line + 10, line + 40, fy))
            let below = RGB(snapR[i], snapG[i], snapB[i])
            let c = mixc(RGB(0.50, 0.53, 0.82), below, smoothstep(line, line + 30, fy))
            blend(i, c, cov)
        }
    }
}

// MARK: - 10. Big framing pines (left)

drawPine(cx: 520, base: 1610, h: 1060, halfW: 190, body: RGB(0.055, 0.075, 0.15),
         snowC: RGB(0.56, 0.60, 0.88), snowAmt: 0.75, tiers: 13, seed: 9001, edgeNoise: 0.26,
         trunk: RGB(0.08, 0.06, 0.10))
drawPine(cx: 170, base: 1700, h: 1610, halfW: 300, body: RGB(0.035, 0.05, 0.11),
         snowC: RGB(0.60, 0.64, 0.92), snowAmt: 0.8, tiers: 16, seed: 9002, edgeNoise: 0.28,
         trunk: RGB(0.06, 0.045, 0.08))
// snow mound burying the trunks
for xi in 0..<900 {
    let fx = Float(xi) + 0.5
    let line = min(1640 + 0.00018 * powf(fx - 120, 2), 1596 + 0.0011 * powf(fx - 525, 2))
        + 10 * (vnoise(fx * 0.01, 7, 61) - 0.5)
    if line > Float(H) { continue }
    for yi in max(Int(line - 2), 0)..<H {
        let fy = Float(yi) + 0.5
        let cov = clamp01(fy - line + 0.5)
        let i = yi * W + xi
        let tt = smoothstep(line, Float(H), fy)
        let c = mixc(RGB(0.46, 0.49, 0.77), RGB(0.33, 0.35, 0.60), powf(tt, 0.8)) * (1 + 0.2 * expf(-(fy - line) / 6))
        let edgeFade = 1 - smoothstep(700, 900, fx)
        blend(i, c, cov * max(edgeFade, smoothstep(line + 40, line + 120, fy) * 0) )
    }
}

// MARK: - 11. Falling snow (sparse, soft)

do {
    var rng = Rng(s: 5150)
    for _ in 0..<260 {
        let x = rng.range(0, Float(W)), y = rng.range(0, dockLine - 60)
        let r = rng.range(1.0, 3.2)
        let a = rng.range(0.25, 0.7) * (r > 2.5 ? 0.7 : 1)
        let ext = Int(r * 3)
        for py in max(Int(y) - ext, 0)...min(Int(y) + ext, H - 1) {
            for px in max(Int(x) - ext, 0)...min(Int(x) + ext, W - 1) {
                let d = hypotf(Float(px) + 0.5 - x, Float(py) + 0.5 - y)
                blend(py * W + px, RGB(0.85, 0.88, 1.0), a * expf(-d * d / (r * r)))
            }
        }
    }
}

// MARK: - 12. Vignette, dither, encode

let out = UnsafeMutablePointer<UInt8>.allocate(capacity: N * 4)
do {
    var rng = Rng(s: 1)
    for y in 0..<H {
        for x in 0..<W {
            let i = y * W + x
            let nx = (Float(x) / Float(W) - 0.5) * 2, ny = (Float(y) / Float(H) - 0.45) * 2
            let v = 1 - 0.16 * smoothstep(0.5, 1.6, nx * nx * 0.8 + ny * ny * 0.9)
            let dith = (rng.next() + rng.next() - 1) / 255   // triangular dither
            func q(_ c: Float) -> UInt8 {
                // gentle filmic shoulder so highlights don't clip harshly
                let m = c * v
                let s = m < 0.85 ? m : 0.85 + (1 - expf(-(m - 0.85) * 4)) * 0.15
                let g = clamp01(s + dith)
                return UInt8(g * 255 + 0.5)
            }
            out[i * 4] = q(Rb[i]); out[i * 4 + 1] = q(Gb[i]); out[i * 4 + 2] = q(Bb[i]); out[i * 4 + 3] = 255
        }
    }
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("winter-night.png").path
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let img = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot create \(outPath)")
}
CGImageDestinationAddImage(dest, img, nil)
if !CGImageDestinationFinalize(dest) { fatalError("PNG write failed") }
print("wrote \(outPath) (\(W)x\(H))")
