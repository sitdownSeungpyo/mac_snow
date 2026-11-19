import AppKit
import SpriteKit

/// A small yellow toy snowplow (~36pt long) drawn in code. Art faces +x; `xScale = dir` flips it.
/// The scene drives it along the ground/Dock snow, lets the user drag it, and toggles the beacon
/// with a honk-bounce on click.
final class Snowplow: SKNode {
    static let length: CGFloat = 36
    private(set) var dir: CGFloat = 1
    var held = false
    var vy: CGFloat = 0
    /// Falling after being dropped (driving resumes on landing).
    var airborne = false
    var beaconOn = true
    private let visual = SKNode()
    private let art = SKNode()
    private let beacon = SKShapeNode(circleOfRadius: 2.4)
    private let beaconGlow = SKSpriteNode(texture: LightTextures.glow, size: CGSize(width: 14, height: 14))
    private var rasterized = false

    override init() {
        super.init()
        addChild(visual)
        visual.addChild(art)
        let yellow = rgb(1, 0.8, 0.14), edge = rgb(0.78, 0.56, 0.05), dark = rgb(0.2, 0.2, 0.22), steel = rgb(0.62, 0.66, 0.72)
        let prims: [Prim] = [
            // white blade at the front with its arm
            .shape(polyPath([P(13, 0), P(18, 0), P(19.5, 15), P(14.5, 13)]), rgb(0.97, 0.98, 1), z: 0.3,
                   stroke: rgb(0.7, 0.75, 0.82), width: 1),
            .shape(rectPath(9, 7, 6, 2.5), dark, z: 0.1),
            // tracks with bogie wheels
            .shape(rectPath(-16, 0, 27, 8.5, 4.2), dark, z: 0.35),
            .shape(circlePath(-11.5, 4.2, 2.2), steel, z: 0.4),
            .shape(circlePath(-5.5, 4.2, 2.2), steel, z: 0.4),
            .shape(circlePath(0.5, 4.2, 2.2), steel, z: 0.4),
            .shape(circlePath(6.5, 4.2, 2.2), steel, z: 0.4),
            // body + cab with a window
            .shape(rectPath(-14, 8, 24, 8, 2.5), yellow, z: 0.2, stroke: edge, width: 1),
            .shape(rectPath(-10, 15, 14, 11, 2.5), yellow, z: 0.25, stroke: edge, width: 1),
            .shape(rectPath(-7.5, 17.5, 9, 6, 1.5), rgb(0.62, 0.84, 0.96), z: 0.3),
            .shape(rectPath(-14, 11, 3.5, 2), rgb(0.95, 0.3, 0.2), z: 0.3),
        ]
        for p in prims { art.addChild(PrimRender.node(p)) }
        beacon.fillColor = rgb(1, 0.55, 0.1)
        beacon.strokeColor = rgb(0.6, 0.3, 0.05)
        beacon.lineWidth = 0.6
        beacon.position = CGPoint(x: -3, y: 28)
        beacon.zPosition = 1
        visual.addChild(beacon)
        beaconGlow.color = rgb(1, 0.55, 0.1)
        beaconGlow.colorBlendFactor = 1
        beaconGlow.blendMode = .add
        beaconGlow.position = beacon.position
        beaconGlow.zPosition = 0.9
        visual.addChild(beaconGlow)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func rasterize(view: SKView) {
        guard !rasterized else { return }
        rasterized = true
        Raster.replace(art, view: view)
    }

    func turnAround() {
        dir = -dir
        visual.xScale = dir
    }

    /// Hands the drift over (volume) and empties it.
    func releaseDrift() -> CGFloat {
        let v = driftVolume
        driftVolume = 0
        updateDriftTexture(scale: 2)
        return v
    }

    /// Front of the blade in scene coordinates.
    var bladeX: CGFloat { position.x + dir * 20 }

    func isHit(_ p: CGPoint) -> Bool {
        abs(p.x - position.x) <= 22 && p.y >= position.y - 2 && p.y <= position.y + 31
    }

    // MARK: Drift (the snow pile pushed ahead of the blade)

    /// Snow volume in the drift (pt² of profile area). Height ≈ √(volume / 0.88), capped.
    var driftVolume: CGFloat = 0
    static let driftMaxHeight: CGFloat = 38          // ≈ 1.4 × the plow's height
    let drift = SKSpriteNode()
    private var renderedDriftHeight: CGFloat = -1

    var driftHeight: CGFloat { min(Snowplow.driftMaxHeight, sqrt(max(0, driftVolume) / 0.88)) }
    var driftLength: CGFloat { max(4, driftHeight * 2.2) }
    var driftFull: Bool { driftHeight >= Snowplow.driftMaxHeight - 0.5 }

    /// Smooth wedge-shaped drift texture (tallest at the blade, curving down ahead); redrawn only
    /// when its height changed noticeably.
    func updateDriftTexture(scale: CGFloat) {
        let h = driftHeight
        guard abs(h - renderedDriftHeight) >= 0.6 || (h < 0.5) != (renderedDriftHeight < 0.5) else { return }
        renderedDriftHeight = h
        guard h >= 0.5 else { drift.isHidden = true; return }
        drift.isHidden = false
        let L = driftLength
        let wpt = L + 4, hpt = h + 4
        let wpx = Int(ceil(wpt * scale)), hpx = Int(ceil(hpt * scale))
        guard wpx > 0, hpx > 0, wpx < 4000, hpx < 1000,
              let ctx = CGContext(data: nil, width: wpx, height: hpx, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h * 0.82))
        // rounded crest against the blade, then a long smooth curve down to the ground
        path.addQuadCurve(to: CGPoint(x: L * 0.16, y: h), control: CGPoint(x: L * 0.02, y: h * 1.02))
        path.addCurve(to: CGPoint(x: L, y: 0), control1: CGPoint(x: L * 0.45, y: h * 0.98), control2: CGPoint(x: L * 0.7, y: h * 0.12))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        if let g = CGGradient(colorsSpace: cs, colors: [rgb(0.74, 0.82, 0.96).cgColor, rgb(0.93, 0.96, 1).cgColor, rgb(1, 1, 1).cgColor] as CFArray,
                              locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: L * 0.7, y: 0), end: CGPoint(x: L * 0.15, y: h), options: [.drawsAfterEndLocation])
        }
        guard let img = ctx.makeImage() else { return }
        drift.texture = SKTexture(cgImage: img)
        drift.size = CGSize(width: wpt, height: hpt)
        drift.anchorPoint = .zero
    }

    /// Beacon flashing (called per frame).
    func animate(time: CGFloat) {
        let on = beaconOn && sin(time * 11) > 0
        beacon.fillColor = beaconOn ? (on ? rgb(1, 0.6, 0.1) : rgb(0.7, 0.35, 0.08)) : rgb(0.45, 0.4, 0.35)
        beaconGlow.alpha = on ? 0.9 : 0
    }

    /// Click: toggle the beacon and do a little honk bounce.
    func honk() {
        beaconOn.toggle()
        visual.removeAction(forKey: "honk")
        visual.run(.sequence([.group([.scaleY(to: 0.82, duration: 0.07), .moveBy(x: 0, y: -1, duration: 0.07)]),
                              .group([.scaleY(to: 1.12, duration: 0.09), .moveBy(x: 0, y: 6, duration: 0.09)]),
                              .group([.scaleY(to: 1, duration: 0.12), .moveBy(x: 0, y: -5, duration: 0.12)])]),
                   withKey: "honk")
        let note = SKLabelNode(text: "빵!")
        note.fontName = "Helvetica-Bold"
        note.fontSize = 11
        note.fontColor = rgb(1, 0.85, 0.3)
        note.position = CGPoint(x: dir * 14, y: 30)
        note.zPosition = 2
        addChild(note)
        note.run(.sequence([.group([.moveBy(x: dir * 6, y: 14, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
    }
}
