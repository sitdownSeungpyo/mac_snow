import AppKit
import SpriteKit

// MARK: - Geometry helpers

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}

func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }

func circlePath(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func ellipsePath(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), transform: nil)
}

func rectPath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> CGPath {
    let rect = CGRect(x: x, y: y, width: w, height: h)
    let rr = min(r, w / 2 - 0.01, h / 2 - 0.01)
    if rr <= 0 { return CGPath(rect: rect, transform: nil) }
    return CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil)
}

func polyPath(_ pts: [CGPoint], closed: Bool = true) -> CGPath {
    let p = CGMutablePath()
    guard let first = pts.first else { return p }
    p.move(to: first)
    for q in pts.dropFirst() { p.addLine(to: q) }
    if closed { p.closeSubpath() }
    return p
}

/// Arc in degrees, counter-clockwise (y-up coordinates).
func arcPath(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
             startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
    return p
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: - Primitive drawing description shared by SpriteKit and Core Graphics

/// A drawing primitive in "ball units" (ball radius 50, centred on the origin).
/// The same description renders into SpriteKit nodes (in-scene) and into NSImages (panel previews).
struct Prim {
    var path: CGPath?
    var text: String?
    var at: CGPoint = .zero
    var size: CGFloat = 0
    var textColor: NSColor?
    var fillColor: NSColor?
    var strokeColor: NSColor?
    var lineWidth: CGFloat = 0
    var z: CGFloat = 1

    static func shape(_ p: CGPath, _ fill: NSColor, z: CGFloat = 1, stroke: NSColor? = nil, width: CGFloat = 0) -> Prim {
        Prim(path: p, fillColor: fill, strokeColor: stroke, lineWidth: width, z: z)
    }

    static func line(_ p: CGPath, _ color: NSColor, _ width: CGFloat, z: CGFloat = 1) -> Prim {
        Prim(path: p, strokeColor: color, lineWidth: width, z: z)
    }

    /// Emoji label when `color` is nil, bold text otherwise.
    static func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, color: NSColor? = nil, z: CGFloat = 1) -> Prim {
        Prim(text: s, at: CGPoint(x: x, y: y), size: size, textColor: color, z: z)
    }

    var bounds: CGRect {
        if let p = path {
            return p.boundingBoxOfPath.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
        return CGRect(x: at.x - size * 0.6, y: at.y - size * 0.6, width: size * 1.2, height: size * 1.2)
    }
}

enum PrimRender {
    static func node(_ p: Prim) -> SKNode {
        if let path = p.path {
            let n = SKShapeNode(path: path)
            n.fillColor = p.fillColor ?? .clear
            n.strokeColor = p.strokeColor ?? .clear
            n.lineWidth = p.strokeColor == nil ? 0 : p.lineWidth
            n.lineCap = .round
            n.lineJoin = .round
            n.isAntialiased = true
            n.zPosition = p.z
            return n
        }
        let l = SKLabelNode(text: p.text ?? "")
        if let c = p.textColor {
            l.fontName = "Helvetica-Bold"
            l.fontColor = c
        } else {
            l.fontName = "Apple Color Emoji"
        }
        l.fontSize = p.size
        l.verticalAlignmentMode = .center
        l.horizontalAlignmentMode = .center
        l.position = p.at
        l.zPosition = p.z
        return l
    }

    static func draw(_ p: Prim, in ctx: CGContext) {
        if let path = p.path {
            if let f = p.fillColor {
                ctx.addPath(path)
                ctx.setFillColor(f.cgColor)
                ctx.fillPath()
            }
            if let s = p.strokeColor, p.lineWidth > 0 {
                ctx.addPath(path)
                ctx.setStrokeColor(s.cgColor)
                ctx.setLineWidth(p.lineWidth)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
        } else if let t = p.text {
            let font = p.textColor != nil ? NSFont.boldSystemFont(ofSize: p.size) : NSFont.systemFont(ofSize: p.size)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: p.textColor ?? NSColor.black]
            let s = NSAttributedString(string: t, attributes: attrs)
            let sz = s.size()
            s.draw(at: CGPoint(x: p.at.x - sz.width / 2, y: p.at.y - sz.height / 2))
        }
    }

    static func drawBall(at c: CGPoint, radius r: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [rgb(1, 1, 1).cgColor, rgb(0.95, 0.97, 1).cgColor, rgb(0.82, 0.87, 0.96).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - r * 0.25, y: c.y + r * 0.3), startRadius: 0,
                                   endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    /// Renders prims (plus white balls) into an image, auto-fitting the content bounds.
    static func preview(balls: [CGPoint], prims: [Prim], size: NSSize) -> NSImage {
        var bb = CGRect.null
        for b in balls { bb = bb.union(CGRect(x: b.x - 50, y: b.y - 50, width: 100, height: 100)) }
        for p in prims { bb = bb.union(p.bounds) }
        let content = bb.insetBy(dx: -4, dy: -4)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = min(rect.width / content.width, rect.height / content.height)
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -content.midX, y: -content.midY)
            let sorted = prims.sorted { $0.z < $1.z }
            for p in sorted where p.z < 0 { draw(p, in: ctx) }
            for b in balls { drawBall(at: b, radius: 50, in: ctx) }
            for p in sorted where p.z >= 0 { draw(p, in: ctx) }
            return true
        }
    }
}

// MARK: - Textures generated in code

enum Textures {
    static func make(width: Int, height: Int, _ draw: (CGContext) -> Void) -> SKTexture {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SKTexture()
        }
        draw(ctx)
        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }

    static let snowflake: SKTexture = make(width: 32, height: 32) { ctx in
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [rgb(1, 1, 1, 1).cgColor, rgb(1, 1, 1, 0.55).cgColor, rgb(1, 1, 1, 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.45, 1]) {
            let c = CGPoint(x: 16, y: 16)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 16, options: [])
        }
    }

    static let ball: SKTexture = make(width: 256, height: 256) { ctx in
        PrimRender.drawBall(at: CGPoint(x: 128, y: 128), radius: 127, in: ctx)
        ctx.setStrokeColor(rgb(0.78, 0.84, 0.95, 0.45).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: 252, height: 252))
    }
}

// MARK: - Rasterization (fewer SKShapeNodes = less CPU per frame)

enum Raster {
    /// Renders a parentless `node` (at the origin) into one sprite at 2x resolution.
    /// The returned sprite sits in the same local coordinates the node's children used.
    static func sprite(from node: SKNode, view: SKView) -> SKNode {
        let frame = node.calculateAccumulatedFrame()
        guard frame.width > 0, frame.height > 0 else { return node }
        node.setScale(2)
        let tex = view.texture(from: node)
        node.setScale(1)
        guard let tex else { return node }
        let s = SKSpriteNode(texture: tex, size: frame.size)
        s.position = CGPoint(x: frame.midX, y: frame.midY)
        return s
    }

    /// Replaces `child` (a direct child of its parent) with a rasterized copy; returns the wrapper.
    @discardableResult
    static func replace(_ child: SKNode, view: SKView) -> SKNode {
        guard let parent = child.parent else { return child }
        let pos = child.position, z = child.zPosition
        child.removeFromParent()
        child.position = .zero
        child.zPosition = 0
        let wrapper = SKNode()
        wrapper.position = pos
        wrapper.zPosition = z
        wrapper.addChild(sprite(from: child, view: view))
        parent.addChild(wrapper)
        return wrapper
    }
}
