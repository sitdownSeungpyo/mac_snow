import AppKit
import SpriteKit

/// Chibi Santa in a candy sleigh pulled by three reindeer. Flies across the sky periodically,
/// sometimes lands on the Dock / snow, slides, and takes off again. Art comes from `SantaArt`
/// (cached textures); personality is a few cheap transforms per frame plus SKActions.
/// Local art faces +x; `visual.xScale = dir` flips it toward the travel direction.
final class Santa: SKNode {
    enum Phase { case waiting, flying, descending, sliding, ascending, held }

    private(set) var phase: Phase = .waiting
    private var savedPhase: Phase = .flying
    private(set) var dir: CGFloat = 1
    private let visual = SKNode()
    /// Hop / happy-tilt layer under `visual` (whose rotation follows climbs and descents).
    private let rig = SKNode()
    /// Santa himself (torso, head, arm, sack) for his own gentle bob.
    private let santaRig = SKNode()
    private let head: SKSpriteNode
    private let arm: SKSpriteNode
    private let pompom: SKSpriteNode
    private let eyesOpen: SKSpriteNode
    private let eyesClosed: SKSpriteNode
    private var deer: [(node: SKNode, head: SKNode, legs: [SKNode])] = []
    /// Sparkle trail: a small ring of sprites kept fixed in the world while Santa moves on.
    private var sparkles: [SKSpriteNode] = []
    private var sparkleIndex = 0
    private var sparkleTimer: CGFloat = 0
    private var lastPos: CGPoint?
    private var timer: CGFloat = 4
    private var clock: CGFloat = 0
    private var gallop: CGFloat = 0
    private var pomOffset = CGVector.zero
    private var pomVel = CGVector.zero
    private var lastHeadY: CGFloat?
    private var cruiseY: CGFloat = 0
    private var willLand = false
    private var descendStartX: CGFloat = 0
    private var startX: CGFloat = 0
    private var startY: CGFloat = 0
    private var velocity: CGFloat = 150
    private var giftDropX: CGFloat?

    private let cruiseSpeed: CGFloat = 150
    private let descendLength: CGFloat = 320
    private let ascendLength: CGFloat = 380
    private let armRest: CGFloat = -0.6

    override init() {
        head = SantaArt.head.sprite(z: 0.5)
        arm = SantaArt.arm.sprite(z: 0.7)
        pompom = SantaArt.pompom.sprite(z: 0.1, origin: SantaArt.head.pivot)
        eyesOpen = SantaArt.eyesOpen.sprite(z: 0.05, origin: SantaArt.head.pivot)
        eyesClosed = SantaArt.eyesClosed.sprite(z: 0.06, origin: SantaArt.head.pivot)
        super.init()
        isHidden = true
        addChild(visual)
        visual.addChild(rig)

        rig.addChild(SantaArt.sleigh.sprite(z: 0.2))
        rig.addChild(santaRig)
        santaRig.addChild(SantaArt.sack.sprite(z: -0.4))
        santaRig.addChild(SantaArt.torso.sprite(z: 0.1))
        santaRig.addChild(head)
        santaRig.addChild(arm)
        arm.zRotation = armRest
        head.addChild(eyesOpen)
        head.addChild(eyesClosed)
        head.addChild(pompom)
        eyesClosed.isHidden = true

        let xs: [CGFloat] = [72, 124, 176]
        for (k, x) in xs.enumerated() {
            let lead = k == xs.count - 1
            let n = SKNode()
            n.position = CGPoint(x: x, y: 0)
            var legs: [SKNode] = []
            for (i, hip) in SantaArt.hips.enumerated() {
                let far = i % 2 == 1
                let l = SantaArt.leg(far: far).sprite(z: far ? -0.3 : -0.2)
                l.position = hip
                n.addChild(l)
                legs.append(l)
            }
            n.addChild(SantaArt.deerBody.sprite(z: 0))
            let h = SantaArt.deerHead(lead: lead).sprite(z: 0.2)
            n.addChild(h)
            if lead {
                let glow = SantaArt.noseGlow.sprite(z: 0.1, origin: SantaArt.neck)
                glow.blendMode = .add
                h.addChild(glow)
                glow.run(.repeatForever(.sequence([.fadeAlpha(to: 0.55, duration: 0.7), .fadeAlpha(to: 1, duration: 0.7)])))
            }
            rig.addChild(n)
            deer.append((n, h, legs))
        }
        rig.addChild(SantaArt.reins(xs.map { CGPoint(x: $0 + 9, y: 19) }).sprite(z: -0.5))

        for k in 0..<16 {
            let sp = SKSpriteNode(texture: SantaArt.sparkle, size: CGSize(width: 14, height: 14))
            sp.color = k % 3 == 0 ? rgb(0.85, 0.95, 1) : rgb(1, 0.88, 0.5)
            sp.colorBlendFactor = 1
            sp.blendMode = .add
            sp.alpha = 0
            sp.zPosition = -1
            addChild(sp)
            sparkles.append(sp)
        }

        // Personality: blinks every few seconds, an occasional wave while cruising.
        run(.repeatForever(.sequence([.wait(forDuration: 4, withRange: 3), .run { [weak self] in self?.blink() }])))
        run(.repeatForever(.sequence([.wait(forDuration: 11, withRange: 8),
                                      .run { [weak self] in if self?.phase == .flying { self?.wave() } }])))
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Personality

    private func setEyes(open: Bool, for seconds: CGFloat) {
        eyesOpen.isHidden = !open
        eyesClosed.isHidden = open
        eyesClosed.removeAction(forKey: "eyes")
        eyesClosed.run(.sequence([.wait(forDuration: seconds), .run { [weak self] in
            self?.eyesOpen.isHidden = false
            self?.eyesClosed.isHidden = true
        }]), withKey: "eyes")
    }

    private func blink() { setEyes(open: false, for: 0.13) }

    private func wave() {
        let swing = SKAction.sequence([.rotate(toAngle: 1.2, duration: 0.13), .rotate(toAngle: 0.55, duration: 0.13)])
        swing.timingMode = .easeInEaseOut
        arm.run(.sequence([.rotate(toAngle: 0.95, duration: 0.16), .repeat(swing, count: 3),
                           .rotate(toAngle: armRest, duration: 0.25)]), withKey: "wave")
    }

    /// Happy hop with a little nose-up tilt, closed happy eyes and a wave (gift drop / click).
    private func celebrate() {
        let up = SKAction.group([.moveTo(y: 7, duration: 0.14), .rotate(toAngle: 0.07, duration: 0.14)])
        up.timingMode = .easeOut
        let down = SKAction.group([.moveTo(y: 0, duration: 0.22), .rotate(toAngle: 0, duration: 0.3)])
        down.timingMode = .easeIn
        rig.run(.sequence([up, down]), withKey: "hop")
        setEyes(open: false, for: 0.5)
        wave()
    }

    /// Brings the next pass forward (used when Santa is switched back on).
    func scheduleNextPass(in seconds: CGFloat) {
        if phase == .waiting { timer = seconds }
    }

    // MARK: Interaction

    var giftOrigin: CGPoint { CGPoint(x: position.x - dir * 30, y: position.y + 30) }

    func isHit(_ p: CGPoint) -> Bool {
        guard !isHidden, parent != nil else { return false }
        let lx = (p.x - position.x) * dir
        let ly = p.y - position.y
        return lx > -62 && lx < 206 && ly > -4 && ly < 74
    }

    func beginHold() {
        if phase != .held { savedPhase = phase }
        phase = .held
    }

    func endHold(click: Bool) {
        if click {
            phase = savedPhase
            if phase == .flying { cruiseY = position.y - sin(clock * 1.8) * 14 }
        } else {
            beginAscent()
            velocity = 70
        }
    }

    func say(_ text: String) {
        childNode(withName: "bubble")?.removeFromParent()
        let label = SKLabelNode(text: text)
        label.fontName = "Helvetica-Bold"
        label.fontSize = 14
        label.fontColor = rgb(0.75, 0.08, 0.1)
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        let w = label.frame.width + 20, h: CGFloat = 26
        let bubble = SKShapeNode(rect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 10)
        bubble.fillColor = .white
        bubble.strokeColor = rgb(0.7, 0.7, 0.75)
        bubble.lineWidth = 1
        let tail = SKShapeNode(path: polyPath([P(-6, -h / 2 + 1), P(0, -h / 2 - 8), P(6, -h / 2 + 1)]))
        tail.fillColor = .white
        tail.strokeColor = .clear
        let node = SKNode()
        node.name = "bubble"
        node.addChild(bubble)
        node.addChild(tail)
        node.addChild(label)
        node.position = CGPoint(x: -10 * dir, y: 84)
        node.zPosition = 5
        node.setScale(0.1)
        addChild(node)
        node.run(.sequence([.scale(to: 1, duration: 0.15), .wait(forDuration: 1.8),
                            .fadeOut(withDuration: 0.4), .removeFromParent()]))
        celebrate()
    }

    // MARK: Motion

    private func smooth(_ p: CGFloat) -> CGFloat { p * p * (3 - 2 * p) }

    private func beginAscent() {
        phase = .ascending
        startX = position.x
        startY = position.y
    }

    private func startPass(size: CGSize, landing: ClosedRange<CGFloat>?) {
        dir = Bool.random() ? 1 : -1
        visual.xScale = dir
        cruiseY = size.height * CGFloat.random(in: 0.6...0.85)
        position = CGPoint(x: dir > 0 ? -210 : size.width + 210, y: cruiseY)
        velocity = cruiseSpeed
        willLand = CGFloat.random(in: 0...1) < 0.5
        let touchdown: CGFloat
        if let r = landing, r.upperBound - r.lowerBound > 120 {
            touchdown = dir > 0 ? r.lowerBound + 30 : r.upperBound - 30
        } else {
            touchdown = dir > 0 ? size.width * 0.2 : size.width * 0.8
        }
        descendStartX = touchdown - dir * descendLength
        giftDropX = CGFloat.random(in: 0...1) < 0.2 ? CGFloat.random(in: (size.width * 0.15)...(size.width * 0.85)) : nil
        phase = .flying
        isHidden = false
        lastHeadY = nil
        lastPos = nil
    }

    private func endPass() {
        phase = .waiting
        isHidden = true
        for sp in sparkles {
            sp.removeAllActions()
            sp.alpha = 0
        }
        timer = CGFloat.random(in: 20...45)
        childNode(withName: "bubble")?.removeFromParent()
    }

    /// Advances the state machine. Returns true when a gift should be dropped.
    func step(dt: CGFloat, size: CGSize, surface: (CGFloat, CGFloat) -> CGFloat, landing: ClosedRange<CGFloat>?) -> Bool {
        clock += dt
        switch phase {
        case .waiting:
            timer -= dt
            if timer <= 0 { startPass(size: size, landing: landing) }
            return false
        case .held:
            animate(dt: dt)
            return false
        case .flying:
            position.x += dir * velocity * dt
            position.y = cruiseY + sin(clock * 1.8) * 14
            if willLand && (position.x - descendStartX) * dir >= 0 {
                willLand = false
                phase = .descending
                startX = position.x
                startY = position.y
            }
        case .descending:
            position.x += dir * velocity * dt
            let p = min(1, abs(position.x - startX) / descendLength)
            position.y = startY + (surface(position.x, startY) - startY) * smooth(p)
            if p >= 1 {
                phase = .sliding
                timer = CGFloat.random(in: 2.5...4.5)
            }
        case .sliding:
            velocity = max(50, velocity - 35 * dt)
            position.x += dir * velocity * dt
            let ground = surface(position.x, position.y + 4)
            if ground < position.y - 12 {
                // Slid off a window edge: take off again.
                beginAscent()
            } else {
                position.y = ground
            }
            timer -= dt
            let nearEdge = dir > 0 ? position.x + 200 > size.width : position.x - 200 < 0
            if timer <= 0 || nearEdge { beginAscent() }
        case .ascending:
            velocity = min(cruiseSpeed, velocity + 60 * dt)
            position.x += dir * velocity * dt
            let p = min(1, abs(position.x - startX) / ascendLength)
            position.y = startY + (size.height * 0.72 - startY) * smooth(p)
            if p >= 1 {
                phase = .flying
                cruiseY = position.y - sin(clock * 1.8) * 14
            }
        }

        var drop = false
        if let gx = giftDropX, (position.x - gx) * dir >= 0 {
            giftDropX = nil
            drop = true
        }

        let off = dir > 0 ? position.x - 70 > size.width : position.x + 70 < 0
        if off { endPass() }

        if drop { celebrate() }
        animate(dt: dt)
        let tilt: CGFloat = phase == .ascending ? 0.06 : (phase == .descending ? -0.05 : 0)
        visual.zRotation += (tilt * dir - visual.zRotation) * min(1, 4 * dt)
        return drop
    }

    /// Gallop cycle, head bobs, Santa's idle bob, the lagging pompom and the sparkle trail.
    private func animate(dt: CGFloat) {
        let sliding = phase == .sliding
        gallop += dt * (sliding ? 7 : phase == .held ? 16 : 11)
        for (k, d) in deer.enumerated() {
            let g = gallop + CGFloat(k) * 1.1
            let swing: CGFloat = sliding ? 0.3 : 0.6
            // front pair and back pair move in opposition; the far leg trails its near twin
            for (i, leg) in d.legs.enumerated() {
                leg.zRotation = sin(g + (i < 2 ? 0 : .pi) + (i % 2 == 1 ? 0.6 : 0)) * swing
            }
            d.node.position.y = max(0, sin(2 * g)) * (sliding ? 0.8 : 2) + sin(clock * 2 + CGFloat(k)) * 0.8
            d.head.zRotation = sin(2 * g - 1.6) * 0.07
        }
        santaRig.position.y = sin(clock * 2.6) * 0.9
        head.zRotation = sin(clock * 1.7) * 0.06

        // Pompom: damped spring that lags behind the head's vertical motion.
        let dtc = min(max(dt, 0.001), 0.05)
        let headY = position.y + rig.position.y + santaRig.position.y
        let vy = lastHeadY.map { (headY - $0) / dtc } ?? 0
        lastHeadY = headY
        let target = CGVector(dx: sin(clock * 3.1) * 0.6, dy: clamp(-vy * 0.03, -3, 3))
        pomVel.dx += ((target.dx - pomOffset.dx) * 160 - pomVel.dx * 9) * dtc
        pomVel.dy += ((target.dy - pomOffset.dy) * 160 - pomVel.dy * 9) * dtc
        pomOffset.dx += pomVel.dx * dtc
        pomOffset.dy += pomVel.dy * dtc
        pompom.position = SantaArt.pompomRest - SantaArt.head.pivot + CGPoint(x: pomOffset.dx, y: pomOffset.dy)

        if let lp = lastPos {
            let d = position - lp
            for sp in sparkles where sp.alpha > 0 { sp.position = sp.position - d }
        }
        lastPos = position
        sparkleTimer -= dt
        if sparkleTimer <= 0 && !isHidden && phase != .held {
            sparkleTimer = sliding ? 0.2 : 0.07
            emitSparkle()
        }
    }

    private func emitSparkle() {
        let sp = sparkles[sparkleIndex]
        sparkleIndex = (sparkleIndex + 1) % sparkles.count
        sp.removeAllActions()
        sp.position = CGPoint(x: dir * (-54 + .random(in: -4...4)), y: rig.position.y + .random(in: 4...30))
        sp.alpha = 1
        sp.setScale(.random(in: 0.55...1.1))
        sp.zRotation = .random(in: 0...1)
        let life = TimeInterval.random(in: 0.6...0.95)
        sp.run(.group([.fadeOut(withDuration: life), .scale(to: 0.15, duration: life),
                       .moveBy(x: 0, y: -10, duration: life), .rotate(byAngle: 1.5, duration: life)]))
    }
}
