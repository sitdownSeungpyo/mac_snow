import AppKit

enum HatStyle: Int, CaseIterable {
    case none, santa, topHat, beanie, earmuffs, crown, flowerPot, pomPom
    static let titles = ["None", "Santa hat", "Top hat", "Beanie", "Earmuffs", "Crown", "Flower pot", "Pom-pom"]
}

enum FaceStyle: Int, CaseIterable {
    case classic, happy, wink, cool, surprised, sleepy, grumpy, inLove
    static let titles = ["Classic", "Happy", "Wink", "Cool", "Surprised", "Sleepy", "Grumpy", "In love"]
}

enum BodyStyle: Int, CaseIterable {
    case sticks, waving, mittens, broom, candyCane, cocoa, gift, flowers
    static let titles = ["Sticks", "Waving", "Mittens", "Broom", "Candy cane", "Cocoa", "Gift", "Flowers"]
}

enum ClothesStyle: Int, CaseIterable {
    case none, redScarf, greenScarf, stripedScarf, bowTie, vest, sweater, cape
    static let titles = ["None", "Red scarf", "Green scarf", "Striped scarf", "Bow tie", "Vest", "Sweater", "Cape"]
}

/// Per-snowman customization, stored on the bottom (root) ball of the stack.
struct Outfit: Equatable {
    var hat: HatStyle = .none
    var face: FaceStyle = .classic
    var body: BodyStyle = .sticks
    var clothes: ClothesStyle = .none

    var key: String { "\(hat.rawValue)\(face.rawValue)\(body.rawValue)\(clothes.rawValue)" }
}

/// Snowman art in ball units (radius 50, centred on origin). z < 0 draws behind the ball.
enum OutfitArt {
    static let coal = rgb(0.12, 0.12, 0.14)
    static let carrotColor = rgb(1, 0.55, 0.12)
    static let stick = rgb(0.42, 0.27, 0.13)
    static let red = rgb(0.84, 0.12, 0.16)
    static let darkRed = rgb(0.6, 0.06, 0.1)
    static let green = rgb(0.13, 0.55, 0.28)
    static let gold = rgb(1, 0.8, 0.22)
    static let darkGold = rgb(0.8, 0.55, 0.05)
    static let white = rgb(1, 1, 1)
    static let pink = rgb(1, 0.5, 0.6, 0.45)
    static let blueZ = rgb(0.35, 0.55, 0.95)

    // MARK: Face (head ball)

    static func eye(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Prim { .shape(circlePath(x, y, r), coal, z: 2) }
    static func carrot() -> Prim { .shape(polyPath([P(-2, 7), P(32, 1), P(-2, -4)]), carrotColor, z: 2.2) }
    static func dotSmile() -> [Prim] {
        (0..<5).map { k in
            let a = (220 + 25 * CGFloat(k)) * .pi / 180
            return .shape(circlePath(22 * cos(a), 4 + 22 * sin(a), 3.2), coal, z: 2)
        }
    }
    static func wideSmile() -> Prim { .line(arcPath(0, -2, 20, 205, 335), coal, 4, z: 2) }
    static func cheeks() -> [Prim] {
        [.shape(circlePath(-28, -4, 6), pink, z: 1.5), .shape(circlePath(28, -4, 6), pink, z: 1.5)]
    }
    static func heart(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> [Prim] {
        let c = rgb(0.92, 0.15, 0.3)
        return [
            .shape(circlePath(x - s * 0.24, y + s * 0.12, s * 0.28), c, z: 2),
            .shape(circlePath(x + s * 0.24, y + s * 0.12, s * 0.28), c, z: 2),
            .shape(polyPath([P(x - s * 0.5, y + s * 0.06), P(x + s * 0.5, y + s * 0.06), P(x, y - s * 0.5)]), c, z: 2),
        ]
    }

    static func face(_ f: FaceStyle) -> [Prim] {
        switch f {
        case .classic:
            return [eye(-15, 15, 5.5), eye(15, 15, 5.5), carrot()] + dotSmile()
        case .happy:
            return [.line(arcPath(-15, 12, 6, 0, 180), coal, 3.5, z: 2),
                    .line(arcPath(15, 12, 6, 0, 180), coal, 3.5, z: 2),
                    carrot(), wideSmile()] + cheeks()
        case .wink:
            return [eye(-15, 15, 5.5), .line(arcPath(15, 12, 6, 0, 180), coal, 3.5, z: 2), carrot()] + dotSmile()
        case .cool:
            let black = rgb(0.05, 0.05, 0.07)
            return [.shape(rectPath(-30, 7, 24, 14, 5), black, z: 2),
                    .shape(rectPath(6, 7, 24, 14, 5), black, z: 2),
                    .line(polyPath([P(-6, 16), P(6, 16)], closed: false), black, 3, z: 2),
                    .line(polyPath([P(-30, 17), P(-42, 21)], closed: false), black, 3, z: 2),
                    .line(polyPath([P(30, 17), P(42, 21)], closed: false), black, 3, z: 2),
                    .line(polyPath([P(-26, 17), P(-21, 12)], closed: false), rgb(1, 1, 1, 0.55), 2, z: 2.1),
                    .line(polyPath([P(10, 17), P(15, 12)], closed: false), rgb(1, 1, 1, 0.55), 2, z: 2.1),
                    carrot(),
                    .line(polyPath([P(-12, -20), P(2, -19), P(14, -13)], closed: false), coal, 3.5, z: 2)]
        case .surprised:
            return [eye(-15, 15, 6.5), eye(15, 15, 6.5),
                    .line(arcPath(-15, 20, 11, 55, 125), coal, 3, z: 2),
                    .line(arcPath(15, 20, 11, 55, 125), coal, 3, z: 2),
                    carrot(),
                    .shape(circlePath(0, -22, 7), rgb(0.3, 0.1, 0.1), z: 2, stroke: coal, width: 3)]
        case .sleepy:
            return [.line(arcPath(-15, 18, 6, 200, 340), coal, 3.5, z: 2),
                    .line(arcPath(15, 18, 6, 200, 340), coal, 3.5, z: 2),
                    carrot(),
                    .shape(circlePath(0, -21, 3.5), coal, z: 2),
                    .label("z", 36, 40, 13, color: blueZ, z: 2),
                    .label("Z", 48, 57, 19, color: blueZ, z: 2)]
        case .grumpy:
            return [eye(-15, 13, 5), eye(15, 13, 5),
                    .line(polyPath([P(-25, 27), P(-7, 21)], closed: false), coal, 4, z: 2),
                    .line(polyPath([P(25, 27), P(7, 21)], closed: false), coal, 4, z: 2),
                    carrot(),
                    .line(arcPath(0, -34, 16, 35, 145), coal, 4, z: 2)]
        case .inLove:
            return heart(-15, 15, 15) + heart(15, 15, 15) + [carrot(), wideSmile()] + cheeks()
        }
    }

    // MARK: Hats (head ball)

    static func dome(_ c: NSColor) -> Prim {
        let p = CGMutablePath()
        p.move(to: P(-40, 36))
        p.addCurve(to: P(40, 36), control1: P(-40, 96), control2: P(40, 96))
        p.closeSubpath()
        return .shape(p, c, z: 3)
    }

    static func hat(_ h: HatStyle) -> [Prim] {
        switch h {
        case .none:
            return []
        case .santa:
            let p = CGMutablePath()
            p.move(to: P(-36, 38))
            p.addQuadCurve(to: P(44, 80), control: P(0, 122))
            p.addQuadCurve(to: P(36, 38), control: P(24, 66))
            p.closeSubpath()
            return [.shape(p, red, z: 3),
                    .shape(rectPath(-42, 30, 84, 14, 7), white, z: 3.1),
                    .shape(circlePath(46, 77, 9), white, z: 3.1)]
        case .topHat:
            let black = rgb(0.08, 0.08, 0.1)
            return [.shape(rectPath(-26, 42, 52, 50, 3), black, z: 3),
                    .shape(rectPath(-26, 46, 52, 9), red, z: 3.1),
                    .shape(rectPath(-40, 36, 80, 8, 4), black, z: 3.2)]
        case .beanie:
            return [dome(rgb(0.2, 0.45, 0.85)),
                    .shape(rectPath(-42, 30, 84, 14, 6), rgb(0.12, 0.3, 0.65), z: 3.1)]
        case .earmuffs:
            return [.line(arcPath(0, 6, 50, 15, 165), rgb(0.3, 0.3, 0.35), 6, z: 3),
                    .shape(circlePath(-47, 18, 12), rgb(1, 0.62, 0.75), z: 3.1, stroke: white, width: 3),
                    .shape(circlePath(47, 18, 12), rgb(1, 0.62, 0.75), z: 3.1, stroke: white, width: 3)]
        case .crown:
            return [.shape(polyPath([P(-30, 40), P(30, 40), P(36, 84), P(18, 64), P(0, 92), P(-18, 64), P(-36, 84)]),
                           gold, z: 3, stroke: darkGold, width: 2),
                    .shape(circlePath(0, 52, 4), red, z: 3.1),
                    .shape(circlePath(-18, 50, 3), rgb(0.2, 0.4, 0.95), z: 3.1),
                    .shape(circlePath(18, 50, 3), green, z: 3.1)]
        case .flowerPot:
            return [.shape(polyPath([P(-24, 40), P(24, 40), P(31, 78), P(-31, 78)]), rgb(0.8, 0.42, 0.25), z: 3),
                    .shape(rectPath(-35, 74, 70, 11, 3), rgb(0.66, 0.32, 0.18), z: 3.1),
                    .label("🌷", 0, 100, 28, z: 2.9)]
        case .pomPom:
            return [dome(red),
                    .shape(rectPath(-36, 50, 72, 7, 3), white, z: 3.05),
                    .shape(rectPath(-28, 64, 56, 6, 3), white, z: 3.05),
                    .shape(rectPath(-42, 30, 84, 13, 6), white, z: 3.1),
                    .shape(circlePath(0, 90, 11), white, z: 3.1)]
        }
    }

    // MARK: Arms / held items (body ball)

    static func stickArm(_ s: CGFloat) -> [Prim] {
        [.line(polyPath([P(s * 40, 12), P(s * 104, 44)], closed: false), stick, 5, z: -1),
         .line(polyPath([P(s * 86, 35), P(s * 94, 58)], closed: false), stick, 3.5, z: -1),
         .line(polyPath([P(s * 96, 39), P(s * 114, 36)], closed: false), stick, 3.5, z: -1)]
    }

    static func body(_ b: BodyStyle) -> [Prim] {
        let sticks = stickArm(-1) + stickArm(1)
        switch b {
        case .sticks:
            return sticks
        case .waving:
            return stickArm(-1) + [
                .line(polyPath([P(40, 14), P(86, 88)], closed: false), stick, 5, z: -1),
                .line(polyPath([P(78, 75), P(66, 94)], closed: false), stick, 3.5, z: -1),
                .line(polyPath([P(86, 88), P(104, 96)], closed: false), stick, 3.5, z: -1),
                .line(polyPath([P(86, 88), P(88, 106)], closed: false), stick, 3.5, z: -1)]
        case .mittens:
            return sticks + [-1, 1].flatMap { (s: CGFloat) -> [Prim] in
                [.shape(circlePath(s * 106, 44, 11), red, z: 1),
                 .shape(circlePath(s * 98, 55, 5.5), red, z: 1),
                 .shape(rectPath(s * 106 - 10, 30, 20, 6, 3), white, z: 1.1)]
            }
        case .broom:
            return stickArm(-1) + [
                .line(polyPath([P(40, 12), P(96, 36)], closed: false), stick, 5, z: -1),
                .line(polyPath([P(112, 104), P(84, -50)], closed: false), rgb(0.6, 0.42, 0.2), 5, z: 1),
                .shape(polyPath([P(72, -48), P(94, -52), P(100, -96), P(60, -90)]), rgb(0.88, 0.72, 0.36), z: 1.1,
                       stroke: rgb(0.7, 0.55, 0.25), width: 1.5),
                .line(polyPath([P(72, -54), P(95, -58)], closed: false), red, 4, z: 1.2)]
        case .candyCane:
            let cane = CGMutablePath()
            cane.move(to: P(102, -46))
            cane.addLine(to: P(102, 52))
            cane.addArc(center: P(90, 52), radius: 12, startAngle: 0, endAngle: .pi, clockwise: false)
            cane.addLine(to: P(78, 42))
            var prims = sticks + [Prim.line(cane, red, 7, z: 1)]
            for y in stride(from: CGFloat(-36), through: 36, by: 18) {
                prims.append(.line(polyPath([P(99, y - 3), P(105, y + 3)], closed: false), white, 2.5, z: 1.1))
            }
            return prims
        case .cocoa:
            return sticks + [.label("☕️", 114, 50, 26, z: 1)]
        case .gift:
            return sticks + [
                .shape(rectPath(94, 30, 26, 22, 2), red, z: 1),
                .shape(rectPath(105, 30, 4, 22), gold, z: 1.1),
                .shape(rectPath(94, 39, 26, 4), gold, z: 1.1),
                .shape(circlePath(103, 55, 4), gold, z: 1.2),
                .shape(circlePath(111, 55, 4), gold, z: 1.2)]
        case .flowers:
            return sticks + [.label("💐", 114, 54, 28, z: 1)]
        }
    }

    // MARK: Clothes

    static func scarf(_ c: NSColor, striped: Bool) -> [Prim] {
        var p: [Prim] = [.shape(rectPath(-37, -49, 74, 15, 7), c, z: 1.5),
                         .shape(rectPath(12, -88, 15, 44, 5), c, z: 1.4)]
        if striped {
            for x in [CGFloat(-22), -4, 14] { p.append(.shape(rectPath(x, -49, 6, 15), white, z: 1.55)) }
            for y in [CGFloat(-70), -82] { p.append(.shape(rectPath(12, y, 15, 5), white, z: 1.45)) }
        }
        return p
    }

    /// Clothes drawn on the head ball (neckwear).
    static func neckClothes(_ c: ClothesStyle) -> [Prim] {
        switch c {
        case .redScarf: return scarf(red, striped: false)
        case .greenScarf: return scarf(green, striped: false)
        case .stripedScarf: return scarf(red, striped: true)
        case .bowTie:
            return [.shape(polyPath([P(0, -44), P(-20, -33), P(-20, -56)]), red, z: 1.5),
                    .shape(polyPath([P(0, -44), P(20, -33), P(20, -56)]), red, z: 1.5),
                    .shape(circlePath(0, -44, 5), darkRed, z: 1.6)]
        case .none, .vest, .sweater, .cape: return []
        }
    }

    /// Clothes drawn on the body ball.
    static func bodyClothes(_ c: ClothesStyle) -> [Prim] {
        switch c {
        case .vest:
            let v = rgb(0.38, 0.24, 0.16)
            return [.shape(polyPath([P(-44, 22), P(-14, 40), P(-10, -34), P(-28, -42), P(-48, -10)]), v, z: 0.4),
                    .shape(polyPath([P(44, 22), P(14, 40), P(10, -34), P(28, -42), P(48, -10)]), v, z: 0.4)]
        case .sweater:
            var zig1: [CGPoint] = []
            var zig2: [CGPoint] = []
            for (k, x) in stride(from: CGFloat(-42), through: 42, by: 12).enumerated() {
                zig1.append(P(x, 12 + (k % 2 == 0 ? 5 : -5)))
                zig2.append(P(x, -16 + (k % 2 == 0 ? 5 : -5)))
            }
            return [.shape(circlePath(0, -1, 47), rgb(0.78, 0.15, 0.2), z: 0.3),
                    .line(polyPath(zig1, closed: false), white, 3, z: 0.35),
                    .line(polyPath(zig2, closed: false), white, 3, z: 0.35),
                    .shape(rectPath(-20, 36, 40, 10, 5), darkRed, z: 0.36)]
        case .cape:
            return [.shape(polyPath([P(-34, 50), P(34, 50), P(72, -40), P(-72, -40)]), rgb(0.75, 0.1, 0.15), z: -2),
                    .shape(circlePath(0, 47, 5), gold, z: 0.5)]
        case .none, .redScarf, .greenScarf, .stripedScarf, .bowTie:
            return []
        }
    }

    static func buttons() -> [Prim] {
        [CGFloat(24), 2, -20].map { .shape(circlePath(0, $0, 5), coal, z: 0.6) }
    }
}
