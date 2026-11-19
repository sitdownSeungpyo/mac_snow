import AppKit

/// Base view that reacts to clicks even when its (non-activating) panel is not key.
class ClickableView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { clicked(at: p) }
    }
    func clicked(at p: NSPoint) {}
}

private func drawCentered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let sz = s.size()
    s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
}

final class IconButton: ClickableView {
    private let symbol: String
    private let onClick: () -> Void

    init(symbol: String, frame: NSRect, onClick: @escaping () -> Void) {
        self.symbol = symbol
        self.onClick = onClick
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        drawCentered(symbol, in: bounds, font: .systemFont(ofSize: 12, weight: .semibold), color: NSColor(white: 1, alpha: 0.9))
    }

    override func clicked(at p: NSPoint) { onClick() }
}

final class TabBar: ClickableView {
    let titles: [String]
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: (Int) -> Void = { _ in }

    init(frame: NSRect, titles: [String]) {
        self.titles = titles
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2).fill()
        let w = bounds.width / CGFloat(titles.count)
        for (i, t) in titles.enumerated() {
            let r = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
            if i == selected {
                NSColor(white: 1, alpha: 0.24).setFill()
                let rr = r.insetBy(dx: 2, dy: 2)
                NSBezierPath(roundedRect: rr, xRadius: rr.height / 2, yRadius: rr.height / 2).fill()
            }
            drawCentered(t, in: r, font: .systemFont(ofSize: 12, weight: .medium),
                         color: NSColor(white: 1, alpha: i == selected ? 1 : 0.7))
        }
    }

    override func clicked(at p: NSPoint) {
        let w = bounds.width / CGFloat(titles.count)
        let i = min(max(Int(p.x / w), 0), titles.count - 1)
        selected = i
        onSelect(i)
    }
}

final class OptionTile: ClickableView {
    var image: NSImage?
    var title = ""
    var selected = false
    var onClick: () -> Void = {}

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor(white: 1, alpha: selected ? 0.18 : 0.07).setFill()
        path.fill()
        if selected {
            NSColor(srgbRed: 0.55, green: 0.82, blue: 1, alpha: 1).setStroke()
            path.lineWidth = 2
        } else {
            NSColor(white: 1, alpha: 0.12).setStroke()
            path.lineWidth = 1
        }
        path.stroke()
        if let image {
            image.draw(in: NSRect(x: 6, y: 20, width: bounds.width - 12, height: bounds.height - 25))
        }
        drawCentered(title, in: NSRect(x: 2, y: 3, width: bounds.width - 4, height: 15),
                     font: .systemFont(ofSize: 10.5, weight: .medium), color: NSColor(white: 1, alpha: 0.9))
    }

    override func clicked(at p: NSPoint) { onClick() }
}

private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor(white: 1, alpha: 0.2).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Frosted-glass snowman customization panel ("Fashion week, but colder.").
/// A separate key-capable non-activating panel, so it is clickable regardless of the overlay's click-through state.
final class CustomizePanel: NSPanel {
    static let shared = CustomizePanel()

    private static let W: CGFloat = 340
    private static let H: CGFloat = 266

    private weak var scene: WinterScene?
    private(set) weak var root: Snowball?
    private var currentTab = 0
    private var tabBar: TabBar?
    private var tiles: [OptionTile] = []
    private var previews: [[NSImage]] = []

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: CustomizePanel.W, height: CustomizePanel.H),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        buildUI()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    private func buildUI() {
        let W = CustomizePanel.W, H = CustomizePanel.H
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.maskImage = CustomizePanel.roundedMask(radius: 16)
        contentView = fx

        let title = NSTextField(labelWithString: "Fashion week, but colder.")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 16, y: H - 38, width: 230, height: 22)
        fx.addSubview(title)

        fx.addSubview(IconButton(symbol: "↺", frame: NSRect(x: W - 70, y: H - 40, width: 24, height: 24)) { [weak self] in
            self?.resetOutfit()
        })
        fx.addSubview(IconButton(symbol: "✕", frame: NSRect(x: W - 40, y: H - 40, width: 24, height: 24)) { [weak self] in
            self?.dismiss()
        })

        let bar = TabBar(frame: NSRect(x: 16, y: 194, width: W - 32, height: 26), titles: ["Hat", "Face", "Body", "Clothes"])
        bar.onSelect = { [weak self] i in
            self?.currentTab = i
            self?.refreshTiles()
        }
        fx.addSubview(bar)
        tabBar = bar

        let tw = (W - 32 - 24) / 4, th: CGFloat = 78
        for i in 0..<8 {
            let row = i / 4, colm = i % 4
            let tile = OptionTile(frame: NSRect(x: 16 + CGFloat(colm) * (tw + 8), y: row == 0 ? 104 : 18, width: tw, height: th))
            tile.onClick = { [weak self] in self?.choose(i) }
            fx.addSubview(tile)
            tiles.append(tile)
        }

        let border = BorderView(frame: fx.bounds)
        fx.addSubview(border)
    }

    private func buildPreviews() -> [[NSImage]] {
        let sz = NSSize(width: 59, height: 53)
        let hats = HatStyle.allCases.map {
            PrimRender.preview(balls: [.zero], prims: OutfitArt.face(.classic) + OutfitArt.hat($0), size: sz)
        }
        let faces = FaceStyle.allCases.map { PrimRender.preview(balls: [.zero], prims: OutfitArt.face($0), size: sz) }
        let bodies = BodyStyle.allCases.map { PrimRender.preview(balls: [.zero], prims: OutfitArt.body($0), size: sz) }
        let clothes = ClothesStyle.allCases.map { c -> NSImage in
            let neck = OutfitArt.neckClothes(c)
            if !neck.isEmpty {
                return PrimRender.preview(balls: [.zero], prims: OutfitArt.face(.classic) + neck, size: sz)
            }
            return PrimRender.preview(balls: [.zero], prims: OutfitArt.bodyClothes(c), size: sz)
        }
        return [hats, faces, bodies, clothes]
    }

    private func selectedIndex() -> Int {
        guard let o = root?.outfit else { return -1 }
        switch currentTab {
        case 0: return o.hat.rawValue
        case 1: return o.face.rawValue
        case 2: return o.body.rawValue
        default: return o.clothes.rawValue
        }
    }

    private func refreshTiles() {
        if previews.isEmpty { previews = buildPreviews() }
        let titles = [HatStyle.titles, FaceStyle.titles, BodyStyle.titles, ClothesStyle.titles][currentTab]
        let sel = selectedIndex()
        for (i, t) in tiles.enumerated() {
            t.image = previews[currentTab][i]
            t.title = titles[i]
            t.selected = i == sel
            t.needsDisplay = true
        }
        tabBar?.selected = currentTab
    }

    private func choose(_ i: Int) {
        guard let root, let scene else { return }
        var o = root.outfit
        switch currentTab {
        case 0: o.hat = HatStyle(rawValue: i) ?? .none
        case 1: o.face = FaceStyle(rawValue: i) ?? .classic
        case 2: o.body = BodyStyle(rawValue: i) ?? .sticks
        default: o.clothes = ClothesStyle(rawValue: i) ?? .none
        }
        root.outfit = o
        scene.outfitChanged(root)
        refreshTiles()
    }

    private func resetOutfit() {
        guard let root, let scene else { return }
        root.outfit = Outfit()
        scene.outfitChanged(root)
        refreshTiles()
    }

    /// Opens next to `anchor` (snowman bounds in global screen coordinates).
    func show(for root: Snowball, scene: WinterScene, anchor: NSRect) {
        self.root = root
        self.scene = scene
        refreshTiles()
        let W = CustomizePanel.W, H = CustomizePanel.H
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? anchor.insetBy(dx: -W, dy: -H)
        var x = anchor.maxX + 14
        if x + W > vf.maxX { x = anchor.minX - 14 - W }
        x = clamp(x, vf.minX + 8, vf.maxX - W - 8)
        let y = clamp(anchor.midY - H / 2, vf.minY + 8, vf.maxY - H - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
        root = nil
        scene = nil
    }

    /// Closes the panel if its snowman no longer exists as a 2+ ball stack.
    func validate() {
        guard isVisible else { return }
        guard let r = root, r.parent != nil, r.below == nil, r.above != nil else {
            dismiss()
            return
        }
    }
}
