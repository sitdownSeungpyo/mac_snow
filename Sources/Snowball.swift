import AppKit
import SpriteKit

/// A snowball. Visuals are authored at radius 50 ("ball units") and scaled to `radius`.
final class Snowball: SKNode {
    static let unit: CGFloat = 50
    static let maxRadius: CGFloat = 80

    private(set) var radius: CGFloat
    var vy: CGFloat = 0
    var held = false
    /// Window id whose snow cap this (root) ball rests on, if any.
    var restingOn: Int?
    /// Wobble while riding a moving window (root ball only): tilt angle (rad) and its velocity.
    var tilt: CGFloat = 0
    var tiltVel: CGFloat = 0
    /// Horizontal velocity (only after being thrown off a shaken window; damped on landing).
    var vx: CGFloat = 0
    weak var below: Snowball?
    weak var above: Snowball?
    /// Meaningful on the root (bottom) ball of a stack.
    var outfit = Outfit()

    private let body = SKNode()
    private let spin = SKNode()
    private let decor = SKNode()
    private let shadow = SKShapeNode(ellipseOf: CGSize(width: 86, height: 14))
    private var decorKey = ""
    private let speckles = SKNode()
    private var rasterized = false

    init(radius: CGFloat) {
        self.radius = radius
        super.init()
        shadow.fillColor = rgb(0.2, 0.3, 0.5, 0.16)
        shadow.strokeColor = .clear
        shadow.position = CGPoint(x: 0, y: -47)
        shadow.zPosition = -3
        body.addChild(shadow)

        let sprite = SKSpriteNode(texture: Textures.ball, size: CGSize(width: 100, height: 100))
        body.addChild(sprite)

        // Faint speckles that rotate with rolling so the spin is visible.
        spin.zPosition = 0.1
        for _ in 0..<10 {
            let r = CGFloat.random(in: 1.6...3.0)
            let d = 40 * sqrt(CGFloat.random(in: 0...1))
            let a = CGFloat.random(in: 0...(2 * .pi))
            let dot = SKShapeNode(circleOfRadius: r)
            dot.fillColor = rgb(0.76, 0.83, 0.94, 0.55)
            dot.strokeColor = .clear
            dot.position = CGPoint(x: d * cos(a), y: d * sin(a))
            speckles.addChild(dot)
        }
        spin.addChild(speckles)
        body.addChild(spin)
        body.addChild(decor)
        addChild(body)
        setRadius(radius)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Flattens the speckle dots into one sprite.
    func rasterize(view: SKView) {
        guard !rasterized else { return }
        rasterized = true
        Raster.replace(speckles, view: view)
    }

    func setRadius(_ r: CGFloat) {
        radius = clamp(r, 4, Snowball.maxRadius)
        body.setScale(radius / Snowball.unit)
    }

    func roll(_ dx: CGFloat) {
        spin.zRotation -= dx / radius
    }

    func setDecor(_ prims: [Prim], key: String, showShadow: Bool) {
        shadow.isHidden = !showShadow
        guard key != decorKey else { return }
        decorKey = key
        decor.removeAllChildren()
        for p in prims { decor.addChild(PrimRender.node(p)) }
    }
}
