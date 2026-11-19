import AppKit
import SpriteKit

/// Drawn red gift box with gold ribbon and bow, plus a hover-only ✕ delete button.
final class Gift: SKNode {
    let hw: CGFloat = 15
    let hh: CGFloat = 12
    var vel = CGVector.zero
    var angVel: CGFloat = 0
    var held = false
    /// Window id whose snow cap this gift rests on, if any.
    var restingOn: Int?
    /// 0 = on snow / a window cap, 1 = on one gift, 2 = on two stacked gifts, ...
    var stackLevel = 0
    var radius: CGFloat { 14 }
    /// Box color variant (0 red, 1 green, 2 blue, 3 purple); ribbon is always gold.
    let variant: Int
    static let variantCount = 4
    private static let bodies: [(NSColor, NSColor, NSColor)] = [
        (rgb(0.86, 0.12, 0.15), rgb(0.93, 0.18, 0.2), rgb(0.6, 0.05, 0.08)),
        (rgb(0.13, 0.6, 0.3), rgb(0.18, 0.68, 0.35), rgb(0.06, 0.38, 0.17)),
        (rgb(0.18, 0.4, 0.85), rgb(0.24, 0.47, 0.92), rgb(0.08, 0.22, 0.55)),
        (rgb(0.55, 0.22, 0.75), rgb(0.62, 0.28, 0.82), rgb(0.34, 0.1, 0.5)),
    ]

    private let deleteButton = SKNode()
    private var art = SKNode()
    private var rasterized = false

    init(variant: Int = 0) {
        self.variant = ((variant % Gift.variantCount) + Gift.variantCount) % Gift.variantCount
        super.init()
        let (red, lid, edge) = Gift.bodies[self.variant]
        let gold = rgb(1, 0.8, 0.22)
        let darkGold = rgb(0.78, 0.55, 0.08)
        let prims: [Prim] = [
            .shape(rectPath(-hw, -hh, 2 * hw, 2 * hh - 4, 2), red, z: 0, stroke: edge, width: 1.2),
            .shape(rectPath(-hw - 2, hh - 7, 2 * hw + 4, 8, 2), lid, z: 0.1, stroke: edge, width: 1.2),
            .shape(rectPath(-2.5, -hh, 5, 2 * hh + 1), gold, z: 0.2),
            .shape(rectPath(-hw, -3, 2 * hw, 4), gold, z: 0.2),
            .shape(ellipsePath(-7, hh + 5, 13, 9), gold, z: 0.3, stroke: darkGold, width: 1),
            .shape(ellipsePath(7, hh + 5, 13, 9), gold, z: 0.3, stroke: darkGold, width: 1),
            .shape(circlePath(0, hh + 3, 3.2), darkGold, z: 0.4),
        ]
        for p in prims { art.addChild(PrimRender.node(p)) }
        addChild(art)

        let circle = SKShapeNode(circleOfRadius: 8)
        circle.fillColor = rgb(0.15, 0.15, 0.18, 0.88)
        circle.strokeColor = rgb(1, 1, 1, 0.9)
        circle.lineWidth = 1
        let x = SKLabelNode(text: "✕")
        x.fontName = "Helvetica-Bold"
        x.fontSize = 10
        x.fontColor = .white
        x.verticalAlignmentMode = .center
        x.horizontalAlignmentMode = .center
        deleteButton.addChild(circle)
        deleteButton.addChild(x)
        deleteButton.position = CGPoint(x: -hw - 1, y: hh + 1)
        deleteButton.zPosition = 2
        deleteButton.isHidden = true
        addChild(deleteButton)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func local(_ p: CGPoint) -> CGPoint? {
        guard let parent else { return nil }
        return convert(p, from: parent)
    }

    /// Flattens the box art into one sprite.
    func rasterize(view: SKView) {
        guard !rasterized else { return }
        rasterized = true
        art = Raster.replace(art, view: view)
    }

    /// Shows / hides the ✕; `onRight` puts it at the top-right corner (away from a window's
    /// traffic-light buttons when the gift sits near the window's left edge).
    func setDeleteVisible(_ v: Bool, onRight: Bool = false) {
        deleteButton.isHidden = !v
        deleteButton.position = CGPoint(x: onRight ? hw + 1 : -hw - 1, y: hh + 1)
    }

    func deleteHit(_ p: CGPoint) -> Bool {
        guard !deleteButton.isHidden, let l = local(p) else { return false }
        return hypot(l.x - deleteButton.position.x, l.y - deleteButton.position.y) <= 10
    }

    /// Box hit (including the bow); `includeDelete` also accepts the ✕ button area.
    func isHit(_ p: CGPoint, includeDelete: Bool = false) -> Bool {
        guard let l = local(p) else { return false }
        if abs(l.x) <= hw + 2 && l.y >= -hh - 1 && l.y <= hh + 10 { return true }     // tight to the visible box, lid and bow
        if includeDelete && hypot(l.x - deleteButton.position.x, l.y - deleteButton.position.y) <= 11 { return true }
        return false
    }
}
