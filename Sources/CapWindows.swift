import AppKit
import SpriteKit

/// The content root of one cap window, handed to the overlay scene that owns the target window.
/// Children of `root` keep OVERLAY-SCENE coordinates: the scene sets `root.position` every frame to
/// `CapGeometry.worldOffset(targetInScene:)` of the frame it simulates with, so a node's place inside
/// the cap window is (scene position − that frame's corner) — independent of any smoothing lag —
/// while WindowServer moves the cap window itself together with the target.
final class CapWorld {
    let target: Int
    let root = SKNode()
    /// Strip (snow line) container and garland container (same z as in the overlay scene).
    let strips = SKNode()
    let garland = SKNode()
    /// Room above the target's top edge the riders need (set by the scene, applied by the manager).
    var neededAbove: CGFloat = CapGeometry.above
    /// Room below the edge the cap window HAS (applied by the manager together with the window
    /// frame, so the content offset and the frame always change in the same main-thread turn)
    /// and the room the scene would like (garland or not).
    var below: CGFloat = CapGeometry.below
    var neededBelow: CGFloat = CapGeometry.below
    /// Where WindowServer has the cap (scene x), its offset `k` to the target's left edge, and
    /// whether the newest event was a resize (see `CapMover.anchor`); nil = no event mover
    /// (the cap then sits at `CapGeometry.worldOffset`).
    var anchor: (() -> (x: CGFloat, k: CGFloat, resizing: Bool)?)?
    /// Called every frame (before the content is placed) with the leftmost / rightmost target edge
    /// drawn or reported (scene x): the cap grows before the strip would leave it.
    var cover: ((_ minX: CGFloat, _ maxX: CGFloat) -> Void)?
    /// True while something animates (riders wobbling, garland twinkle): full frame rate.
    var animated = false
    var hasRiders = false
    var hasGarland = false

    /// Hybrid ordering: the cap floats above all normal windows and its content is cropped to
    /// the part of the strip not covered by windows in front of its target.
    let container = SKCropNode()
    private let maskRoot = SKNode()
    private var visible: [CGRect]?? = .none
    /// The whole cap region is covered by front windows (nothing to show).
    private(set) var fullyCovered = false

    init(target: Int, stripZ: CGFloat, garlandZ: CGFloat) {
        self.target = target
        strips.zPosition = stripZ
        garland.zPosition = garlandZ
        root.addChild(strips)
        root.addChild(garland)
        container.addChild(root)
    }

    /// The region this cap shows, in Cocoa global coordinates: its visible rects (scene coordinates
    /// of the owning screen) clipped to the cap window, or the whole cap window when unmasked.
    func visibleGlobal(screenOrigin o: CGPoint, capFrame: CGRect) -> [CGRect] {
        switch visible {
        case .some(.some(let rects)):
            return rects.map { $0.offsetBy(dx: o.x, dy: o.y).intersection(capFrame) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        default:
            return [capFrame]
        }
    }

    /// Content offset (see the class comment); the mask uses the same coordinates.
    func place(offset: CGPoint) {
        root.position = offset
        maskRoot.position = offset
    }

    /// Visible part of the cap in scene coordinates: nil = no masking, [] = fully covered.
    /// The mask nodes are rebuilt only when the rects change.
    func setVisible(_ rects: [CGRect]?) {
        if case .some(let cur) = visible, cur == rects { return }
        visible = .some(rects)
        guard let rects else {
            container.maskNode = nil
            fullyCovered = false
            onMaskChange?()
            return
        }
        fullyCovered = rects.isEmpty
        // Reuse the mask sprites (no allocation while a window slides over this cap).
        while maskPool.count < rects.count {
            let n = SKSpriteNode(color: .white, size: CGSize(width: 1, height: 1))
            n.anchorPoint = .zero
            maskRoot.addChild(n)
            maskPool.append(n)
        }
        for (k, n) in maskPool.enumerated() {
            if k < rects.count {
                n.size = rects[k].size
                n.position = rects[k].origin
                n.isHidden = false
            } else if !n.isHidden {
                n.isHidden = true
            }
        }
        if container.maskNode !== maskRoot { container.maskNode = maskRoot }
        onMaskChange?()
    }
    private var maskPool: [SKSpriteNode] = []
    /// Called when the mask changed (the cap window raises its frame rate for a moment).
    var onMaskChange: (() -> Void)?
}

/// Empty scene hosting one `CapWorld` (all logic stays in the overlay scene).
final class CapScene: SKScene {
    let world: CapWorld
    init(size: CGSize, world: CapWorld) {
        self.world = world
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
        addChild(world.container)
    }
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A small transparent window ordered directly above one app window, holding its snow line,
/// riders and garland. Never takes the mouse (the overlay above handles rider clicks), never
/// activates, never becomes key.
final class CapWindow: NSPanel {
    let world: CapWorld
    let scene: CapScene
    let skView: SKView
    weak var owner: OverlayWindow?
    private(set) var above: CGFloat

    /// `owner` is nil only in the standalone spike.
    init(target: Int, frameCG: CGRect, above: CGFloat, level: Int32, owner: OverlayWindow?, stripZ: CGFloat, garlandZ: CGFloat) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CapGeometry.cocoa(fromCG: frameCG, primaryHeight: primaryH)
        world = CapWorld(target: target, stripZ: stripZ, garlandZ: garlandZ)
        scene = CapScene(size: cocoa.size, world: world)
        skView = SKView(frame: NSRect(origin: .zero, size: cocoa.size))
        self.above = above
        self.owner = owner
        super.init(contentRect: cocoa, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        self.level = NSWindow.Level(rawValue: Int(level))
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary, .managed]
        skView.allowsTransparency = true
        skView.isAsynchronous = true
        skView.ignoresSiblingOrder = false
        skView.preferredFramesPerSecond = 60
        skView.autoresizingMask = [.width, .height]
        contentView = skView
        ensureTransparent()
        skView.presentScene(scene)
        world.onMaskChange = { [weak self] in self?.boost() }
        // A size change never rescales the last drawn frame while the next one renders: it stays
        // at the bottom-left (where the content origin is), or bottom-right while growing left.
        anchorStaleFrame(right: false)
        world.anchor = { [weak self] in
            guard let self, let a = CapMover.shared.anchor(target: self.world.target) else { return nil }
            return (a.x - (self.owner?.hostScreen.frame.minX ?? 0), a.k, a.resizing)
        }
        world.cover = { [weak self] minX, maxX in self?.cover(sceneMinX: minX, sceneMaxX: maxX) }
    }

    /// Where the previous drawable stays while a resized frame's first new one renders.
    private func anchorStaleFrame(right: Bool) {
        let p: NSView.LayerContentsPlacement = right ? .bottomRight : .bottomLeft
        if skView.layerContentsPlacement != p { skView.layerContentsPlacement = p }
        let flipped = skView.layer?.contentsAreFlipped() ?? false
        let g: CALayerContentsGravity = right ? (flipped ? .topRight : .bottomRight) : (flipped ? .topLeft : .bottomLeft)
        if skView.layer?.contentsGravity != g { skView.layer?.contentsGravity = g }
    }

    /// Grows the cap before the strip would leave it. Left: origin and width change together by
    /// the same amount (the right edge stays; the old drawable stays where it is on screen) and
    /// the mover's x with them, before the scene places the content this same turn. Right: size
    /// only. (AppKit's origin is stale after event moves: frames are rebuilt from the mover's x.)
    private func cover(sceneMinX lo: CGFloat, sceneMaxX hi: CGFloat) {
        guard let a = CapMover.shared.anchor(target: world.target) else { return }
        let sx = owner?.hostScreen.frame.minX ?? 0
        // Per frame: cheap checks first; the true bounds are read only when the cap must grow.
        guard CapGeometry.leftGrowth(capX: a.x, targetMinX: lo + sx) != nil
                || CapGeometry.coverWidth(current: frame.width, capX: a.x, targetMaxX: hi + sx) > frame.width,
              let b = SkyLightEvents.shared.bounds(of: world.target) else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if let nx = CapGeometry.leftGrowth(capX: a.x, targetMinX: min(lo + sx, b.minX)) {
            let cg = CGRect(x: nx, y: b.minY - above, width: frame.width + (a.x - nx), height: above + world.below)
            anchorStaleFrame(right: true)
            CapMover.shared.set(target: world.target, cap: windowNumber, above: above, x: nx)
            setFrame(CapGeometry.cocoa(fromCG: cg, primaryHeight: primaryH), display: false)
            moveCG(to: cg.origin)
            Diag.shared.row("capFrame", id: world.target, note: String(format: "grow left %.0f→x=%.0f w=%.0f", a.x - nx, nx, cg.width))
            return                                  // the right side (if needed) next frame
        }
        let w = CapGeometry.coverWidth(current: frame.width, capX: a.x, targetMaxX: max(hi + sx, b.maxX))
        guard w > frame.width else { return }
        sync(targetCG: b, above: above, below: world.below)
        Diag.shared.row("capFrame", id: world.target, note: String(format: "widen to %.0f (size only)", frame.width))
    }

    /// A moving window is sliding over this cap: render every frame for a moment (a strip-only
    /// cap normally runs at 15fps), so the occluded boundary never steps.
    private(set) var boostUntil: TimeInterval = 0
    var boostFrameRate = 60
    private func boost() {
        boostUntil = ProcessInfo.processInfo.systemUptime + 0.5
        if skView.preferredFramesPerSecond < boostFrameRate { skView.preferredFramesPerSecond = boostFrameRate }
    }
    var boosted: Bool { ProcessInfo.processInfo.systemUptime < boostUntil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Never pushed back onto the screen: a cap above a full-height window starts above the
    /// screen's top (under the menu bar), and any constraint would shift its content.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Puts the window at an exact CG global top-left with SkyLight (as the event path does).
    func moveCG(to origin: CGPoint) {
        guard let move = SkyLightEvents.shared.moveWindow, let wid = UInt32(exactly: windowNumber) else { return }
        var p = origin
        _ = move(SkyLightEvents.shared.connection, wid, &p)
    }

    /// Same guarantee as the overlay: never opaque, never capturing the mouse.
    @discardableResult
    func ensureTransparent() -> Bool {
        var repaired = false
        if !ignoresMouseEvents { ignoresMouseEvents = true; repaired = true }
        if !skView.allowsTransparency { skView.allowsTransparency = true; repaired = true }
        if let layer = skView.layer {
            if layer.isOpaque { layer.isOpaque = false; repaired = true }
            if layer.backgroundColor?.alpha ?? 0 > 0 { layer.backgroundColor = CGColor.clear; repaired = true }
        }
        if isOpaque { isOpaque = false; repaired = true }
        if backgroundColor != .clear { backgroundColor = .clear; repaired = true }
        if scene.backgroundColor.alphaComponent > 0 { scene.backgroundColor = .clear; repaired = true }
        return repaired
    }

    /// Keeps AppKit's frame in step with where the event mover has the cap (x), the target's true
    /// bounds (y) and the needed room. The cap's x and its offset to the target belong to
    /// `CapMover` (a resize leaves it in place); the width only grows here (size-only change).
    func sync(targetCG b: CGRect, above a: CGFloat, below bl: CGFloat) {
        above = a
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var cg = CapGeometry.capFrameCG(target: b, above: a, below: bl)
        if let anc = CapMover.shared.anchor(target: world.target) {
            cg.origin.x = anc.x
            cg.size.width = CapGeometry.coverWidth(current: frame.width, capX: anc.x, targetMaxX: b.maxX)
        }
        let f = CapGeometry.cocoa(fromCG: cg, primaryHeight: primaryH)
        if frame != f {
            if frame.size != f.size { anchorStaleFrame(right: false) }
            setFrame(f, display: false)
            moveCG(to: cg.origin)          // exact position even if AppKit adjusted anything
        }
        world.below = bl
    }
}

/// Creates / removes cap windows for the decorated windows of each overlay (live mode only),
/// re-orders them above their targets, keeps AppKit frames in sync and logs timing to diag.
final class CapWindowManager {
    static let maxCaps = 20
    /// "hybrid" (default): caps float just above normal windows and mask what front windows
    /// cover. "relative": each cap ordered directly above its target with SLSOrderWindow (live
    /// test: did not hold across app activation for other apps' windows).
    enum Ordering: String { case hybrid, relative }
    let ordering: Ordering = Ordering(rawValue: UserDefaults.standard.string(forKey: "capOrdering") ?? "") ?? .hybrid
    /// Window level of hybrid caps: one above normal windows, below floating panels and our overlay.
    static let hybridLevel = Int32(CGWindowLevelForKey(.normalWindow)) + 1
    private(set) var caps: [Int: CapWindow] = [:]
    private var timer: Timer?
    private var lastStats: TimeInterval = 0
    private(set) var reorderEvents = 0
    private var orderErrors = 0, orders = 0
    var frameRate = 60 { didSet { if frameRate != oldValue { applyFrameRates() } } }

    var available: Bool { SkyLightEvents.shared.capsAvailable && SkyLightEvents.shared.registered }

    /// Pure: at least 15% of the window's top edge is not covered by windows in front of it
    /// (fully covered background windows get no cap window).
    static func topEdgeVisible(_ w: AppWindow, in windows: [AppWindow]) -> Bool {
        let n = 20
        var visible = 0
        for i in 0..<n {
            let p = CGPoint(x: w.frame.minX + (CGFloat(i) + 0.5) / CGFloat(n) * w.frame.width, y: w.frame.maxY - 2)
            if !windows.contains(where: { $0.order < w.order && $0.frame.contains(p) }) { visible += 1 }
        }
        return CGFloat(visible) / CGFloat(n) >= 0.15
    }

    /// Frame rate tier: riders wobble (60), garland twinkle at 20Hz (30), strip only (15).
    static func fps(riders: Bool, garland: Bool, cap: Int) -> Int {
        min(cap, riders ? 60 : (garland ? 30 : 15))
    }

    /// `windows`: current app windows (Cocoa global, front-to-back). `enabled`: live mode, window
    /// features on, overlays shown.
    func reconcile(overlays: [OverlayWindow], windows: [AppWindow], enabled: Bool) {
        guard enabled, available else { removeAll(reason: enabled ? "unavailable" : "disabled"); return }
        // Each window belongs to the overlay whose screen holds the middle of its top edge.
        var wanted: [(AppWindow, OverlayWindow)] = []
        for w in windows.sorted(by: { $0.order < $1.order }) {
            let top = CGPoint(x: w.frame.midX, y: w.frame.maxY - 1)
            guard let o = overlays.first(where: { $0.hostScreen.frame.contains(top) && !$0.isPaused }),
                  o.scene.isDecorated(w.id), !o.scene.nonLiveWindows.contains(w.id),
                  caps[w.id] != nil || CapWindowManager.topEdgeVisible(w, in: windows) else { continue }
            wanted.append((w, o))
            if wanted.count >= CapWindowManager.maxCaps { break }
        }
        // Existing caps stay while their window is decorated (covering only masks / hides them);
        // new caps only for windows whose top edge is visible.
        let ids = Set(wanted.map { $0.0.id })
        for id in Array(caps.keys) where caps[id]?.owner == nil || !(ids.contains(id) || keepCovered(id, overlays: overlays, windows: windows)) {
            remove(id, reason: "gone")
        }
        for (w, o) in wanted where caps.count < CapWindowManager.maxCaps || caps[w.id] != nil {
            if let c = caps[w.id] {
                if c.owner !== o { remove(w.id, reason: "screen") } else { continue }
            }
            create(w, overlay: o)
        }
        if timer == nil && !caps.isEmpty {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// A capped window that still exists and is decorated keeps its cap even when covered.
    private func keepCovered(_ id: Int, overlays: [OverlayWindow], windows: [AppWindow]) -> Bool {
        guard ordering == .hybrid, let c = caps[id], let o = c.owner, !o.isPaused,
              windows.contains(where: { $0.id == id }) else { return false }
        return o.scene.isDecorated(id) && !o.scene.nonLiveWindows.contains(id)
    }

    private func create(_ w: AppWindow, overlay o: OverlayWindow) {
        let sls = SkyLightEvents.shared
        guard let b = sls.bounds(of: w.id) else { return }
        let level = ordering == .hybrid ? CapWindowManager.hybridLevel : (sls.level(of: w.id) ?? 0)
        o.scene.capMasking = ordering == .hybrid
        let above = CapGeometry.above
        let frameCG = CapGeometry.roomyFrameCG(target: b, above: above)
        let c = CapWindow(target: w.id, frameCG: frameCG, above: above, level: level,
                          owner: o, stripZ: o.scene.capStripZ, garlandZ: o.scene.capGarlandZ)
        c.skView.preferredFramesPerSecond = min(frameRate, 15)
        c.orderFrontRegardless()
        CapMover.shared.set(target: w.id, cap: c.windowNumber, above: above, x: frameCG.minX, bounds: b)
        c.moveCG(to: frameCG.origin)
        let err = ordering == .relative ? sls.order(c.windowNumber, above: w.id) : 0
        caps[w.id] = c
        CapMover.shared.set(target: w.id, cap: c.windowNumber, above: above)
        o.scene.attachCapWorld(c.world)
        Diag.shared.row("capWindow", id: w.id, rect: b, note: "create cap=\(c.windowNumber) level=\(level) mode=\(ordering.rawValue) order=\(err)")
    }

    func remove(_ id: Int, reason: String) {
        guard let c = caps.removeValue(forKey: id) else { return }
        CapMover.shared.remove(target: id)
        c.owner?.scene.detachCapWorld(id)        // nodes go back to the overlay first
        c.ignoresMouseEvents = true
        c.orderOut(nil)
        c.skView.presentScene(nil)
        c.close()
        Diag.shared.row("capWindow", id: id, note: "remove cap=\(c.windowNumber) reason=\(reason)")
        if caps.isEmpty { timer?.invalidate(); timer = nil }
    }

    func removeAll(reason: String) {
        CapMover.shared.removeAll()
        for id in Array(caps.keys) { remove(id, reason: reason) }
    }

    /// A z-order change event (or the 4Hz tick): every cap directly above its target again.
    func reorderAll() {
        guard ordering == .relative else { return }
        let sls = SkyLightEvents.shared
        for (id, c) in caps where c.isVisible {
            let e = sls.order(c.windowNumber, above: id)
            orders += 1
            if e != 0 { orderErrors += 1 }
        }
    }

    func reorderEvent() { reorderEvents += 1; reorderAll() }

    /// Hides / shows the caps of one overlay (full-screen pause).
    func setHidden(_ hidden: Bool, for overlay: OverlayWindow) {
        for (id, c) in caps where c.owner === overlay {
            c.skView.isPaused = hidden
            if hidden { c.orderOut(nil) } else {
                c.orderFrontRegardless()
                if ordering == .relative { _ = SkyLightEvents.shared.order(c.windowNumber, above: id) }
            }
        }
    }

    /// Safety tick: never opaque, never capturing the mouse.
    func enforce() -> Bool {
        var repaired = false
        for c in caps.values where c.ensureTransparent() { repaired = true }
        return repaired
    }

    private func applyFrameRates() {
        for c in caps.values { c.skView.preferredFramesPerSecond = CapWindowManager.fps(riders: c.world.hasRiders, garland: c.world.hasGarland, cap: frameRate) }
    }

    private func tick() {
        reorderAll()
        let sls = SkyLightEvents.shared
        for (id, c) in caps {
            guard let b = sls.bounds(of: id) else { continue }
            let a = c.world.neededAbove
            if a != c.above { CapMover.shared.set(target: id, cap: c.windowNumber, above: a) }
            c.sync(targetCG: b, above: a, below: c.world.neededBelow)
            // Hybrid: a fully covered cap is ordered out (nothing to draw), back in when uncovered.
            if ordering == .hybrid {
                if c.world.fullyCovered && c.isVisible { c.orderOut(nil); c.skView.isPaused = true }
                else if !c.world.fullyCovered && !c.isVisible && !(c.owner?.isPaused ?? true) { c.skView.isPaused = false; c.orderFrontRegardless() }
            }
            c.boostFrameRate = frameRate
            let fps = c.boosted ? frameRate : CapWindowManager.fps(riders: c.world.hasRiders, garland: c.world.hasGarland, cap: frameRate)
            if c.skView.preferredFramesPerSecond != fps { c.skView.preferredFramesPerSecond = fps }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastStats >= 2 {
            lastStats = now
            Diag.shared.row("capStats", note: CapMover.shared.drainStats() + " caps=\(caps.count) vanishedInCallback=\(CapMover.shared.vanishedCount) mode=\(ordering.rawValue) orders=\(orders) orderErrors=\(orderErrors) reorderEvents=\(reorderEvents) "
                            + (ordering == .relative ? zOrderCheck() : visibilityCheck()))
            orders = 0; orderErrors = 0
        }
    }

    var summary: String { "caps=\(caps.count)" }

    /// Hybrid check from CGWindowList: a cap is shown correctly when its visible (unmasked) region
    /// does not overlap any window in front of its target (≤ 2pt tolerance for poll lag).
    func visibilityCheck() -> String {
        guard !caps.isEmpty, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return "vis=n/a" }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let me = getpid()
        var order: [(id: Int, cocoa: CGRect)] = []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowOwnerPID as String] as? Int32) != me {
            guard let n = w[kCGWindowNumber as String] as? Int, let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d as CFDictionary) else { continue }
            order.append((n, CapGeometry.cocoa(fromCG: r, primaryHeight: primaryH)))
        }
        var ok = 0
        var bad: [String] = []
        for (t, c) in caps {
            guard c.isVisible, let ti = order.firstIndex(where: { $0.id == t }) else { ok += 1; continue }
            let shown = c.world.visibleGlobal(screenOrigin: c.owner?.hostScreen.frame.origin ?? .zero, capFrame: c.frame)
            let front = order[..<ti].map { $0.cocoa.insetBy(dx: 2, dy: 2) }
            let overlap = shown.contains { s in front.contains { !$0.intersection(s).isNull && $0.intersection(s).width > 0 && $0.intersection(s).height > 0 } }
            if overlap { bad.append("\(t)") } else { ok += 1 }
        }
        return "visibleCorrectly=\(ok)/\(caps.count)" + (bad.isEmpty ? "" : " overlapping=" + bad.joined(separator: ","))
    }

    /// z-order check from CGWindowList: how many caps sit directly above their target
    /// (no other window between them), and the ids of those that don't.
    func zOrderCheck() -> String {
        guard !caps.isEmpty, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "z=n/a" }
        let ids = list.compactMap { $0[kCGWindowNumber as String] as? Int }
        var ok = 0
        var bad: [String] = []
        for (t, c) in caps {
            guard let ci = ids.firstIndex(of: c.windowNumber), let ti = ids.firstIndex(of: t) else { bad.append("\(t):offscreen"); continue }
            if ti == ci + 1 { ok += 1 } else { bad.append("\(t):cap@\(ci) target@\(ti)") }
        }
        return "zDirectlyAbove=\(ok)/\(caps.count)" + (bad.isEmpty ? "" : " zBad=" + bad.joined(separator: ","))
    }
}
