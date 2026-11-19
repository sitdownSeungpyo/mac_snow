import AppKit
import SpriteKit

/// Chibi sticker-style art for Santa's team, drawn once with Core Graphics at Retina 2x and
/// cached in statics (no per-frame path drawing). Coordinates are points in the owning node's
/// local space: art faces +x, y up. Each part is a sprite anchored at its pivot.
enum SantaArt {
    struct Part {
        let texture: SKTexture
        let rect: CGRect
        let pivot: CGPoint

        /// A sprite for this part; `origin` is the parent's pivot when nested in another part.
        func sprite(z: CGFloat, origin: CGPoint = .zero) -> SKSpriteNode {
            let s = SKSpriteNode(texture: texture, size: rect.size)
            s.anchorPoint = CGPoint(x: (pivot.x - rect.minX) / rect.width, y: (pivot.y - rect.minY) / rect.height)
            s.position = pivot - origin
            s.zPosition = z
            return s
        }
    }

    private static func part(_ rect: CGRect, pivot: CGPoint? = nil, _ draw: (CGContext) -> Void) -> Part {
        let sc: CGFloat = 2
        let tex = Textures.make(width: Int((rect.width * sc).rounded(.up)), height: Int((rect.height * sc).rounded(.up))) { ctx in
            ctx.scaleBy(x: sc, y: sc)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            draw(ctx)
        }
        return Part(texture: tex, rect: rect, pivot: pivot ?? CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: Palette and ink helpers

    private static let red = rgb(0.92, 0.2, 0.25)
    private static let fur = rgb(1, 0.98, 0.96)
    private static let skin = rgb(1, 0.86, 0.76)
    private static let blush = rgb(1, 0.45, 0.5, 0.55)
    private static let gold = rgb(1, 0.8, 0.3)
    private static let mitten = rgb(0.25, 0.68, 0.45)
    private static let eyeInk = rgb(0.22, 0.12, 0.14)
    private static let coat = rgb(0.76, 0.52, 0.33)
    private static let cream = rgb(1, 0.92, 0.78)
    private static let hoof = rgb(0.42, 0.26, 0.2)

    /// Darker shade of the same hue (soft outline / shading colour, never black).
    static func shade(_ c: NSColor, _ f: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return rgb(s.redComponent * (1 - f), s.greenComponent * (1 - f * 1.15), max(0, s.blueComponent * (1 - f * 0.75)), s.alphaComponent)
    }

    private static func union(_ circles: [(CGFloat, CGFloat, CGFloat)], dx: CGFloat = 0, dy: CGFloat = 0) -> CGPath {
        let p = CGMutablePath()
        for (x, y, r) in circles { p.addPath(circlePath(x + dx, y + dy, r)) }
        return p
    }

    /// Sticker blob: outside-only darker outline, flat fill, soft bottom shading and an optional gloss spot.
    private static func blob(_ ctx: CGContext, _ path: CGPath, _ fill: NSColor, line: CGFloat = 1.1,
                             shading: CGFloat = 0.16, gloss: CGFloat = 0) {
        if line > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(shade(fill, 0.42).cgColor)
            ctx.setLineWidth(line * 2)
            ctx.strokePath()
        }
        ctx.addPath(path)
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        let bb = path.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if shading > 0, let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                           colors: [shade(fill, shading).withAlphaComponent(0).cgColor, shade(fill, shading).cgColor] as CFArray,
                                           locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: P(bb.midX, bb.minY + bb.height * 0.55), end: P(bb.midX, bb.minY + bb.height * 0.05),
                                   options: [.drawsAfterEndLocation])
        }
        if gloss > 0 {
            ctx.addEllipse(in: CGRect(x: bb.minX + bb.width * 0.2, y: bb.minY + bb.height * 0.6, width: bb.width * 0.3, height: bb.height * 0.2))
            ctx.setFillColor(rgb(1, 1, 1, gloss).cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: NSColor, _ width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    private static func dot(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
        ctx.addPath(circlePath(x, y, r))
        ctx.setFillColor(c.cgColor)
        ctx.fillPath()
    }

    private static func shinyEye(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        ctx.addPath(ellipsePath(x, y, w, h))
        ctx.setFillColor(eyeInk.cgColor)
        ctx.fillPath()
        dot(ctx, x - w * 0.17, y + h * 0.2, w * 0.27, rgb(1, 1, 1))
        dot(ctx, x + w * 0.2, y - h * 0.22, w * 0.12, rgb(1, 1, 1, 0.9))
    }

    private static func giftBox(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                                _ angle: CGFloat, _ color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: angle)
        blob(ctx, rectPath(-w / 2, -h / 2, w, h, 1.5), color, line: 0.9)
        ctx.setFillColor(gold.cgColor)
        ctx.fill(CGRect(x: -1, y: -h / 2, width: 2, height: h))
        ctx.fill(CGRect(x: -w / 2, y: -1, width: w, height: 2))
        blob(ctx, union([(-2, h / 2 + 1.3, 1.8), (2, h / 2 + 1.3, 1.8)]), gold, line: 0.6, shading: 0)
        ctx.restoreGState()
    }

    // MARK: Santa (sleigh space; Santa sits around x = -16)

    static let sack = part(CGRect(x: -62, y: 22, width: 34, height: 44)) { ctx in
        blob(ctx, ellipsePath(-44, 47, 21, 6), shade(rgb(0.84, 0.66, 0.46), 0.3), line: 0.8, shading: 0)
        giftBox(ctx, -49, 51, 10, 9, 0.25, rgb(0.3, 0.6, 0.95))
        giftBox(ctx, -40, 52, 9, 10, -0.18, rgb(0.62, 0.36, 0.86))
        let bag = CGMutablePath()
        bag.move(to: P(-55, 47))
        bag.addCurve(to: P(-44, 25), control1: P(-60, 36), control2: P(-55, 25))
        bag.addCurve(to: P(-33, 47), control1: P(-33, 25), control2: P(-28, 36))
        bag.addQuadCurve(to: P(-55, 47), control: P(-44, 43))
        bag.closeSubpath()
        blob(ctx, bag, rgb(0.84, 0.66, 0.46))
        stroke(ctx, polyPath([P(-50, 41), P(-47, 39.5)], closed: false), shade(rgb(0.84, 0.66, 0.46), 0.3), 1)
    }

    static let torso = part(CGRect(x: -34, y: 10, width: 36, height: 34)) { ctx in
        blob(ctx, ellipsePath(-16, 27, 27, 27), red)
    }

    static let sleigh = part(CGRect(x: -62, y: -4, width: 104, height: 54)) { ctx in
        // candy-cane runner and struts
        let runner = CGMutablePath()
        runner.move(to: P(-57, 6))
        runner.addQuadCurve(to: P(-51, 2), control: P(-57, 2))
        runner.addLine(to: P(18, 2))
        runner.addQuadCurve(to: P(33, 10), control: P(32, 2))
        runner.addQuadCurve(to: P(28, 14.5), control: P(35, 15.5))
        for x: CGFloat in [-38, 4] {
            let strut = polyPath([P(x, 2), P(x, 11)], closed: false)
            stroke(ctx, strut, shade(gold, 0.45), 5)
            stroke(ctx, strut, gold, 3)
        }
        stroke(ctx, runner, rgb(0.6, 0.12, 0.2), 6)
        stroke(ctx, runner, rgb(1, 0.97, 0.95), 4)
        ctx.saveGState()
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: [2.6, 2.6])
        stroke(ctx, runner, rgb(0.93, 0.18, 0.25), 4)
        ctx.restoreGState()
        // rounded tub: low dip where Santa sits, a high backrest and a curled front
        let tub = CGMutablePath()
        tub.move(to: P(-52, 16))
        tub.addQuadCurve(to: P(-44, 8), control: P(-52, 8))
        tub.addLine(to: P(14, 8))
        tub.addQuadCurve(to: P(29, 22), control: P(29, 8))
        tub.addQuadCurve(to: P(-27, 22), control: P(0, 15))
        tub.addQuadCurve(to: P(-42, 42), control: P(-29, 41))
        tub.addQuadCurve(to: P(-53, 36), control: P(-53, 43))
        tub.closeSubpath()
        blob(ctx, tub, red, line: 1.2, shading: 0.2)
        // gold rim along the top edge
        let rim = CGMutablePath()
        rim.move(to: P(28, 22))
        rim.addQuadCurve(to: P(-27, 22), control: P(0, 15))
        rim.addQuadCurve(to: P(-42, 42), control: P(-29, 41))
        stroke(ctx, rim, shade(gold, 0.4), 3.6)
        stroke(ctx, rim, gold, 2.2)
        // front scroll
        blob(ctx, circlePath(28, 23, 4.2), gold, line: 0.9, shading: 0.1)
        dot(ctx, 28.6, 23.4, 1.6, shade(gold, 0.25))
        // gloss highlights
        stroke(ctx, polyPath([P(-48, 18), P(-46.5, 33)], closed: false), rgb(1, 1, 1, 0.4), 2.4)
        stroke(ctx, polyPath([P(-30, 12.5), P(4, 12.5)], closed: false), rgb(1, 1, 1, 0.22), 2)
        // side emblem: a little gold star
        let star = CGMutablePath()
        for k in 0..<10 {
            let a = CGFloat(k) * .pi / 5 + .pi / 2
            let rr: CGFloat = k % 2 == 0 ? 5 : 2.3
            let pt = P(-12 + cos(a) * rr, 15 + sin(a) * rr)
            if k == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
        }
        star.closeSubpath()
        blob(ctx, star, gold, line: 0.7, shading: 0)
    }

    /// Near arm, drawn pointing along +x from the shoulder pivot.
    static let arm = part(CGRect(x: -10, y: 24, width: 24, height: 14), pivot: P(-6, 31)) { ctx in
        blob(ctx, rectPath(-9, 27, 13, 8, 4), red, line: 1, shading: 0.1)
        blob(ctx, rectPath(2, 26.5, 4, 9, 2), fur, line: 0.8, shading: 0)
        blob(ctx, union([(8.5, 31, 4.1), (6.8, 34.4, 1.9)]), mitten, line: 1, shading: 0.12)
    }

    static let headCenter = P(-15, 45)

    static let head = part(CGRect(x: -42, y: 24, width: 54, height: 50), pivot: P(-15, 34)) { ctx in
        let c = headCenter
        // fluffy side hair (behind the face)
        blob(ctx, union([(-12.5, 4.5, 4), (-13, -0.5, 4), (12.5, 4, 3.4)], dx: c.x, dy: c.y), fur, line: 1, shading: 0.08)
        blob(ctx, circlePath(c.x, c.y, 12.5), skin, line: 1, shading: 0.08)
        // cheeks
        ctx.setFillColor(blush.cgColor)
        ctx.addPath(ellipsePath(c.x - 7.5, c.y - 2, 5.5, 3.6))
        ctx.addPath(ellipsePath(c.x + 9.5, c.y - 2, 5, 3.6))
        ctx.fillPath()
        // cloud beard
        let beard = union([(-10, -5, 5), (-6, -10, 5.5), (0, -12.5, 6), (6, -11, 5.5), (10.5, -6, 5), (12, -1.5, 3.4),
                           (-12, -0.5, 3.6)], dx: c.x, dy: c.y)
        let fill = CGMutablePath()
        fill.addPath(beard)
        fill.addPath(ellipsePath(c.x + 0.5, c.y - 8.5, 20, 9))
        blob(ctx, fill, fur, line: 1, shading: 0.1)
        // little open smile under the moustache
        let mouth = CGMutablePath()
        mouth.move(to: P(c.x - 1.4, c.y - 7))
        mouth.addQuadCurve(to: P(c.x + 3.6, c.y - 7), control: P(c.x + 1.1, c.y - 11.5))
        mouth.closeSubpath()
        blob(ctx, mouth, rgb(0.75, 0.25, 0.3), line: 0, shading: 0)
        // moustache and button nose
        blob(ctx, union([(-2.4, -5, 3.3), (4.4, -5, 3.3)], dx: c.x, dy: c.y), fur, line: 0.9, shading: 0.1)
        blob(ctx, circlePath(c.x + 1, c.y - 1.8, 2.5), rgb(1, 0.58, 0.55), line: 0.8, shading: 0)
        dot(ctx, c.x + 0.3, c.y - 1.1, 0.8, rgb(1, 1, 1, 0.8))
        // floppy hat leaning back, with a fluffy brim
        let hat = CGMutablePath()
        hat.move(to: P(c.x + 13, c.y + 8))
        hat.addCurve(to: P(c.x - 18, c.y + 21), control1: P(c.x + 13, c.y + 26), control2: P(c.x - 5, c.y + 34))
        hat.addQuadCurve(to: P(c.x - 6, c.y + 16), control: P(c.x - 11, c.y + 23))
        hat.addQuadCurve(to: P(c.x - 12, c.y + 8), control: P(c.x - 9, c.y + 12))
        hat.closeSubpath()
        blob(ctx, hat, red, line: 1.1, shading: 0.12, gloss: 0.3)
        blob(ctx, union([(-11, 8.5, 3.8), (-5.5, 9, 4), (0.5, 9.2, 4), (6.5, 9, 4), (11.5, 8.5, 3.7)], dx: c.x, dy: c.y),
             fur, line: 1, shading: 0.12)
    }

    /// Pompom tip (head-relative rest position).
    static let pompomRest = P(-33, 66)
    static let pompom = part(CGRect(x: -40, y: 59, width: 14, height: 14), pivot: pompomRest) { ctx in
        blob(ctx, union([(0, 0, 4.4), (-2, 1.5, 2.6), (2, 1.8, 2.4)], dx: pompomRest.x, dy: pompomRest.y), fur, line: 1, shading: 0.15)
    }

    static let eyesOpen = part(CGRect(x: -22, y: 43, width: 16, height: 8)) { ctx in
        shinyEye(ctx, -18.4, 47, 3.9, 5)
        shinyEye(ctx, -9.6, 47, 3.9, 5)
    }

    /// Happy closed eyes (blink and joy), covering the open eyes with skin first.
    static let eyesClosed = part(CGRect(x: -22, y: 43, width: 16, height: 8)) { ctx in
        dot(ctx, -18.4, 47, 2.9, skin)
        dot(ctx, -9.6, 47, 2.9, skin)
        for x: CGFloat in [-18.4, -9.6] {
            let arc = CGMutablePath()
            arc.move(to: P(x - 2.1, 46.2))
            arc.addQuadCurve(to: P(x + 2.1, 46.2), control: P(x, 49.4))
            stroke(ctx, arc, eyeInk, 1.2)
        }
    }

    // MARK: Reindeer (deer space: feet at y 0, body centred on x 0)

    static let hips: [CGPoint] = [P(6, 14), P(4, 14.5), P(-7, 14), P(-9, 14.5)]   // front near, front far, back near, back far

    static func leg(far: Bool) -> Part { far ? legFar : legNear }
    private static func drawLeg(_ ctx: CGContext, far: Bool) {
        let c = far ? shade(coat, 0.18) : coat
        blob(ctx, rectPath(-2.6, -10.5, 5.2, 12, 2.6), c, line: 0.9, shading: 0.1)
        blob(ctx, rectPath(-2.8, -11.5, 5.6, 3.6, 1.8), far ? shade(hoof, 0.15) : hoof, line: 0.7, shading: 0)
    }
    private static let legNear = part(CGRect(x: -4, y: -13, width: 8, height: 15), pivot: .zero) { drawLeg($0, far: false) }
    private static let legFar = part(CGRect(x: -4, y: -13, width: 8, height: 15), pivot: .zero) { drawLeg($0, far: true) }

    static let deerBody = part(CGRect(x: -20, y: 6, width: 36, height: 24)) { ctx in
        blob(ctx, union([(-14.5, 21, 3.3), (-16.5, 22.5, 2)]), cream, line: 0.9, shading: 0.1)
        blob(ctx, ellipsePath(0, 17, 28, 17), coat, line: 1.1, shading: 0.18)
        ctx.saveGState()
        ctx.addPath(ellipsePath(0, 17, 28, 17))
        ctx.clip()
        ctx.addPath(ellipsePath(2, 11.5, 18, 8))
        ctx.setFillColor(cream.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // red collar with a gold bell
        stroke(ctx, polyPath([P(8, 25), P(11.5, 14)], closed: false), rgb(0.6, 0.1, 0.18), 4.2)
        stroke(ctx, polyPath([P(8, 25), P(11.5, 14)], closed: false), red, 2.8)
        blob(ctx, circlePath(11.5, 13.5, 2.4), gold, line: 0.7, shading: 0.15)
    }

    static let neck = P(9, 23)
    static func deerHead(lead: Bool) -> Part { lead ? leadHead : plainHead }
    private static let leadHead = part(CGRect(x: -2, y: 16, width: 36, height: 40), pivot: neck) { drawDeerHead($0, lead: true) }
    private static let plainHead = part(CGRect(x: -2, y: 16, width: 36, height: 40), pivot: neck) { drawDeerHead($0, lead: false) }

    static let nose = P(27.5, 29.5)

    private static func drawDeerHead(_ ctx: CGContext, lead: Bool) {
        let antler = rgb(0.98, 0.86, 0.62)
        for (k, far) in [true, false].enumerated() {
            let dx: CGFloat = far ? -4.5 : 0
            let p = CGMutablePath()
            p.move(to: P(15.5 + dx, 39))
            p.addQuadCurve(to: P(12 + dx, 53.5), control: P(17 + dx, 47))
            p.move(to: P(15.8 + dx, 45.5))
            p.addQuadCurve(to: P(20.5 + dx, 50.5), control: P(19.5 + dx, 46))
            p.move(to: P(14.6 + dx, 50))
            p.addLine(to: P(10.5 + dx, 51.5))
            let col = k == 0 ? shade(antler, 0.15) : antler
            stroke(ctx, p, shade(antler, 0.5), 4.6)
            stroke(ctx, p, col, 2.8)
        }
        // ear
        let ear = CGMutablePath()
        ear.move(to: P(8, 35))
        ear.addQuadCurve(to: P(0, 42), control: P(1, 35))
        ear.addQuadCurve(to: P(10, 39), control: P(7, 43))
        ear.closeSubpath()
        blob(ctx, ear, coat, line: 1, shading: 0.1)
        blob(ctx, ellipsePath(5, 39.5, 4.5, 2), rgb(1, 0.7, 0.7), line: 0, shading: 0)
        // head and muzzle
        blob(ctx, circlePath(15, 32, 10.5), coat, line: 1.1, shading: 0.15)
        blob(ctx, ellipsePath(22.5, 28.2, 12.5, 9.5), cream, line: 0.9, shading: 0.1)
        ctx.setFillColor(blush.cgColor)
        ctx.addPath(ellipsePath(16.5, 27.6, 5, 3.2))
        ctx.fillPath()
        shinyEye(ctx, 18, 33.8, 4.6, 5.8)
        let smile = CGMutablePath()
        smile.move(to: P(22.2, 25.6))
        smile.addQuadCurve(to: P(26, 25.8), control: P(24.2, 23.6))
        stroke(ctx, smile, shade(coat, 0.45), 0.9)
        if lead {
            blob(ctx, circlePath(nose.x, nose.y, 3.4), rgb(1, 0.18, 0.22), line: 0.9, shading: 0.1)
        } else {
            blob(ctx, ellipsePath(nose.x, nose.y, 5.4, 4.4), rgb(0.42, 0.24, 0.2), line: 0.8, shading: 0)
        }
        dot(ctx, nose.x - 0.9, nose.y + 1, 1, rgb(1, 1, 1, 0.85))
    }

    static let noseGlow = part(CGRect(x: nose.x - 13, y: nose.y - 13, width: 26, height: 26)) { ctx in
        let cols = [rgb(1, 0.3, 0.3, 0.75).cgColor, rgb(1, 0.2, 0.25, 0.25).cgColor, rgb(1, 0.2, 0.25, 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.4, 1]) {
            ctx.drawRadialGradient(g, startCenter: nose, startRadius: 0, endCenter: nose, endRadius: 13, options: [])
        }
    }

    /// Reins from the sleigh front through each reindeer's chest, sagging a little between them.
    static func reins(_ chests: [CGPoint]) -> Part {
        part(CGRect(x: 20, y: 6, width: 180, height: 24)) { ctx in
            let p = CGMutablePath()
            var prev = P(30, 21)
            p.move(to: prev)
            for c in chests {
                p.addQuadCurve(to: c, control: P((prev.x + c.x) / 2, min(prev.y, c.y) - 4))
                prev = c
            }
            stroke(ctx, p, rgb(0.45, 0.12, 0.16), 2.4)
            stroke(ctx, p, rgb(0.86, 0.26, 0.3), 1.2)
        }
    }

    /// Four-point sparkle for the trail (white; tinted by the emitter).
    static let sparkle: SKTexture = Textures.make(width: 32, height: 32) { ctx in
        let cols = [rgb(1, 1, 1, 0.55).cgColor, rgb(1, 1, 1, 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: P(16, 16), startRadius: 0, endCenter: P(16, 16), endRadius: 9, options: [])
        }
        let s = CGMutablePath()
        s.move(to: P(16, 31))
        s.addQuadCurve(to: P(31, 16), control: P(17.5, 17.5))
        s.addQuadCurve(to: P(16, 1), control: P(17.5, 14.5))
        s.addQuadCurve(to: P(1, 16), control: P(14.5, 14.5))
        s.addQuadCurve(to: P(16, 31), control: P(14.5, 17.5))
        ctx.addPath(s)
        ctx.setFillColor(rgb(1, 1, 1).cgColor)
        ctx.fillPath()
    }
}
