// capspike2: cap windows over real windows, built with the APP's own CapWindow / CapWorld /
// CapMover / SkyLightEvents / CapGeometry code. Each cap shows a white line on its target's
// top edge and one small ball.
//   --mode hybrid (default): caps float one level above normal windows and are masked by the
//                            windows in front of their target (the app's default)
//   --mode relative:         caps at the target's level, SLSOrderWindow above the target (4Hz)
// Caps are created dynamically (every 0.5s) for windows whose top edge becomes ≥15% visible,
// up to 6. Safe by construction: exits by itself after --seconds (default 20, max 60), watchdog
// 2s later; caps ignore ALL mouse input (mouse events reaching this process are counted);
// never activates. Every 2s and at exit, per cap: expected vs actual CG frame, z-order, and
// visibleCorrectly (the cap's shown region overlaps no window in front of its target).
// Usage: capspike2 [--mode hybrid|relative] [--seconds N] [--tx] [--order-on-move] [--dry-run]
import AppKit
import SpriteKit

setvbuf(stdout, nil, _IOLBF, 0)
var seconds: Double = 20
var dryRun = false
var hybrid = true
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--seconds": seconds = it.next().flatMap { Double($0) } ?? 20
        case "--mode":
            switch it.next() { case "hybrid": hybrid = true; case "relative": hybrid = false
            default: print("capspike2: --mode hybrid|relative"); exit(2) }
        case "--tx": CapMover.shared.useTransaction = true
        case "--order-on-move": CapMover.shared.orderOnMove = true
        case "--dry-run": dryRun = true
        default: print("usage: capspike2 [--mode hybrid|relative] [--seconds N (3–60)] [--tx] [--order-on-move] [--dry-run]"); exit(2)
        }
    }
    seconds = min(max(seconds, 3), 60)
}
let sls = SkyLightEvents.shared
guard sls.capsAvailable else { print("capspike2: SkyLight calls missing: \(sls.failure ?? "?")"); exit(1) }
let primaryH = NSScreen.screens.first?.frame.height ?? 0

struct Info { let id: Int; let owner: String; let cg: CGRect; var cocoa: CGRect }
func onScreen() -> [Info] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let me = getpid()
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
              let n = w[kCGWindowNumber as String] as? Int, let d = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: d as CFDictionary), r.width >= 120, r.height >= 80 else { return nil }
        return Info(id: n, owner: (w[kCGWindowOwnerName as String] as? String) ?? "?", cg: r, cocoa: CapGeometry.cocoa(fromCG: r, primaryHeight: primaryH))
    }
}
func visibleTargets(_ infos: [Info]) -> [Info] {
    let aw = infos.enumerated().map { AppWindow(id: $1.id, frame: $1.cocoa, order: $0) }
    return infos.filter { i in CapWindowManager.topEdgeVisible(aw.first { $0.id == i.id }!, in: aw) }
}
print("capspike2: mode=\(hybrid ? "hybrid" : "relative") level=\(hybrid ? CapWindowManager.hybridLevel : 0) seconds=\(Int(seconds))")
if dryRun {
    for t in visibleTargets(onScreen()) { print(String(format: "  would cap %d (%@) CG=(%.0f,%.0f %.0fx%.0f)", t.id, t.owner, t.cg.minX, t.cg.minY, t.cg.width, t.cg.height)) }
    print("capspike2: dry run, nothing created"); exit(0)
}

Thread.detachNewThread { Thread.sleep(forTimeInterval: seconds + 2); print("capspike2: watchdog exit"); exit(0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard sls.start() else { print("capspike2: SLS start failed: \(sls.failure ?? "?")"); exit(1) }
var eventsPerTarget: [Int: Int] = [:]
sls.handler = { ev, wid in if ev == SkyLightEvents.eventMove || ev == SkyLightEvents.eventResize { eventsPerTarget[wid, default: 0] += 1 } }
var mouseEventsToUs = 0
_ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .scrollWheel]) { e in
    mouseEventsToUs += 1
    return e
}

final class Cap { let target: Int; let owner: String; let created: CGRect; let window: CapWindow
    init(target: Int, owner: String, created: CGRect, window: CapWindow) { self.target = target; self.owner = owner; self.created = created; self.window = window } }
@MainActor var caps: [Int: Cap] = [:]

@MainActor func makeCap(_ t: Info) {
    let level = hybrid ? CapWindowManager.hybridLevel : (sls.level(of: t.id) ?? 0)
    let c = CapWindow(target: t.id, frameCG: CapGeometry.capFrameCG(target: t.cg), above: CapGeometry.above, level: level,
                      owner: nil, stripZ: 6, garlandZ: 7)
    // Content in the coordinates of the creation frame (offset fixed): it is cap-local.
    let tc = t.cocoa
    c.world.place(offset: CapGeometry.worldOffset(targetInScene: tc))
    let line = SKSpriteNode(color: .white, size: CGSize(width: tc.width, height: 3.5))
    line.anchorPoint = .zero
    line.position = CGPoint(x: tc.minX, y: tc.maxY)
    c.world.strips.addChild(line)
    let ball = SKShapeNode(circleOfRadius: 9)
    ball.fillColor = .white; ball.strokeColor = NSColor(white: 0.75, alpha: 1)
    ball.position = CGPoint(x: tc.minX + 70, y: tc.maxY + 3.5 + 9)
    ball.zPosition = 10
    c.world.root.addChild(ball)
    c.orderFrontRegardless()
    c.moveCG(to: CapGeometry.capOriginCG(target: t.cg))
    let err = hybrid ? 0 : sls.order(c.windowNumber, above: t.id)
    CapMover.shared.set(target: t.id, cap: c.windowNumber, above: CapGeometry.above)
    caps[t.id] = Cap(target: t.id, owner: t.owner, created: tc, window: c)
    sls.subscribe(Array(caps.keys))
    print("capspike2: + cap \(c.windowNumber) for \(t.id) (\(t.owner)) level=\(level) order=\(err)")
}

/// Hybrid mask: front windows, shifted into the content's (creation-frame) coordinates.
@MainActor func updateMasks(_ infos: [Info]) {
    for (id, cap) in caps {
        guard let ti = infos.firstIndex(where: { $0.id == id }) else { cap.window.world.setVisible([]); continue }
        guard hybrid else { cap.window.world.setVisible(nil); continue }
        let now = infos[ti].cocoa
        let dx = now.minX - cap.created.minX, dy = now.maxY - cap.created.maxY
        let region = CGRect(x: cap.created.minX - CapGeometry.side, y: cap.created.maxY - CapGeometry.below,
                            width: cap.created.width + 2 * CapGeometry.side, height: CapGeometry.above + CapGeometry.below)
        let front = infos[..<ti].map { $0.cocoa.offsetBy(dx: -dx, dy: -dy) }
        cap.window.world.setVisible(CapGeometry.visibleRects(cap: region, occluders: front))
        if cap.window.world.fullyCovered && cap.window.isVisible { cap.window.orderOut(nil) }
        else if !cap.window.world.fullyCovered && !cap.window.isVisible { cap.window.orderFrontRegardless() }
    }
}

@MainActor func report(_ tag: String) {
    let infos = onScreen()
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    let ids = list.compactMap { $0[kCGWindowNumber as String] as? Int }
    func cgBounds(_ id: Int) -> CGRect? {
        guard let w = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == id }), let d = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: d as CFDictionary)
    }
    print("capspike2: --- \(tag) | \(CapMover.shared.drainStats()) | mouse events reaching capspike2=\(mouseEventsToUs)")
    for (id, cap) in caps.sorted(by: { $0.key < $1.key }) {
        let c = cap.window
        guard let ti = infos.firstIndex(where: { $0.id == id }) else { print("  target \(id): gone"); continue }
        let b = infos[ti].cg
        let exp = CapGeometry.capFrameCG(target: b)
        let act = cgBounds(c.windowNumber)
        let d = act.map { String(format: "Δ=(%.1f,%.1f)", $0.minX - exp.minX, $0.minY - exp.minY) } ?? "Δ=n/a (ordered out)"
        let ci = ids.firstIndex(of: c.windowNumber), tIdx = ids.firstIndex(of: id)
        let z = (ci != nil && tIdx != nil) ? (tIdx! == ci! + 1 ? "directly above" : "cap@\(ci!) target@\(tIdx!)") : "cap not on screen"
        // visibleCorrectly: shown region (global) ∩ windows in front of the target = ∅ (2pt tolerance).
        let now = infos[ti].cocoa
        let shown = c.isVisible ? c.world.visibleGlobal(screenOrigin: CGPoint(x: now.minX - cap.created.minX, y: now.maxY - cap.created.maxY), capFrame: c.frame) : []
        let front = infos[..<ti].map { $0.cocoa.insetBy(dx: 2, dy: 2) }
        let overlapping = shown.contains { s in front.contains { let i = $0.intersection(s); return !i.isNull && i.width > 0 && i.height > 0 } }
        print("  target \(id) (\(cap.owner)): \(d) | z: \(z) | visibleCorrectly=\(overlapping ? "NO" : "yes") shownRects=\(shown.count) | events=\(eventsPerTarget[id] ?? 0)")
    }
}

// Discovery + masks (10Hz), relative re-order (4Hz), AppKit frame sync.
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated {
    let infos = onScreen()
    updateMasks(infos)
} }
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated {
    let infos = onScreen()
    for t in visibleTargets(infos) where caps[t.id] == nil && caps.count < 6 { makeCap(t) }
    for (id, cap) in caps where !infos.contains(where: { $0.id == id }) {
        CapMover.shared.remove(target: id); cap.window.orderOut(nil); caps[id] = nil
        print("capspike2: - cap for \(id) (gone)")
    }
} }
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated {
    for (id, cap) in caps {
        if !hybrid { _ = sls.order(cap.window.windowNumber, above: id) }
        if let b = sls.bounds(of: id), cap.window.isVisible { cap.window.sync(targetCG: b, above: CapGeometry.above, below: CapGeometry.below) }
    }
} }
MainActor.assumeIsolated {
    for t in visibleTargets(onScreen()).prefix(6) { makeCap(t) }
    updateMasks(onScreen())
}
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { report(String(format: "%.0fs", ProcessInfo.processInfo.systemUptime)) } }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { report("after creation") } }
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated {
    report("final")
    CapMover.shared.removeAll()
    for cap in caps.values { cap.window.orderOut(nil) }
    exit(0)
} }
signal(SIGINT) { _ in exit(0) }
app.run()
