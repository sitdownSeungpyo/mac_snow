import AppKit
import SpriteKit

/// An on-screen app window. `order` 0 is frontmost. Frame is Cocoa coordinates
/// (global in WindowTracker output, screen-local once handed to a scene).
/// `owner` / `ownerIndex` identify the window across launches for saved light links
/// (owner app's bundle id + rank of the window number among that app's windows).
struct AppWindow: Equatable {
    let id: Int
    var frame: CGRect
    var order: Int
    var owner: String = ""
    var ownerIndex: Int = 0
    var pid: Int = 0
}

/// Lists visible app windows via CGWindowList (bounds only; no Screen Recording permission needed).
enum WindowTracker {
    /// Upper bound on tracked windows (more than this is never needed for decorations).
    static let maxWindows = 40
    private static var bundleCache: [Int: String] = [:]

    private static func sane(_ r: CGRect) -> Bool {
        r.width >= 120 && r.height >= 80 && r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite
            && r.width < 20_000 && r.height < 20_000 && abs(r.minX) < 50_000 && abs(r.minY) < 50_000
    }

    private static func owner(pid: Int, name: String?) -> String {
        if let b = bundleCache[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? name ?? "pid\(pid)"
        if bundleCache.count > 200 { bundleCache.removeAll() }
        bundleCache[pid] = b
        return b
    }

    /// `ownWindows`: window numbers of every window this app owns (overlays, panels, menus);
    /// they are excluded in addition to the PID check so we can never react to ourselves.
    static func snapshot(ownWindows: Set<Int> = []) -> [AppWindow] { snapshotWithPopups(ownWindows: ownWindows).windows }

    /// Like `snapshot`, plus the frames of excluded child/popup windows (so a click inside one is
    /// never taken as a grab of its parent) and each popup's rank: how many kept windows are in
    /// front of it (it covers only windows whose `order` ≥ its rank).
    static func snapshotWithPopups(ownWindows: Set<Int> = []) -> (windows: [AppWindow], popups: [CGRect], popupRanks: [Int]) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return ([], [], []) }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var out: [AppWindow] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != me,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let number = info[kCGWindowNumber as String] as? Int, !ownWindows.contains(number),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: boundsDict as CFDictionary), sane(r) else { continue }
            if out.count >= maxWindows * 2 { break }
            let frame = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            out.append(AppWindow(id: number, frame: frame, order: out.count,
                                 owner: owner(pid: pid, name: info[kCGWindowOwnerName as String] as? String), pid: pid))
        }
        let split = splitChildWindows(out)
        let ranks = split.popups.map { p in split.kept.filter { $0.order < p.order }.count }
        out = Array(split.kept.prefix(maxWindows))
        for i in out.indices { out[i].order = i }
        // Rank of each window number among its owner's windows (creation order; stable-ish across launches).
        var byOwner: [String: [Int]] = [:]
        for w in out { byOwner[w.owner, default: []].append(w.id) }
        for (k, ids) in byOwner { byOwner[k] = ids.sorted() }
        for i in out.indices { out[i].ownerIndex = byOwner[out[i].owner]?.firstIndex(of: out[i].id) ?? 0 }
        return (out, split.popups.map { $0.frame }, ranks)
    }

    /// Child / popup windows (omnibox suggestions, autocomplete, dropdowns, in-window sheets): a
    /// window is excluded when another window of the same process is larger, contains ≥ 90% of its
    /// area, and has a different top edge. Pure function (unit-tested offscreen).
    static func splitChildWindows(_ windows: [AppWindow]) -> (kept: [AppWindow], popups: [AppWindow]) {
        var kept: [AppWindow] = [], popups: [AppWindow] = []
        for w in windows {
            let area = w.frame.width * w.frame.height
            let isChild = area > 0 && windows.contains { o in
                guard o.id != w.id, o.pid == w.pid, o.pid != 0 else { return false }
                let oArea = o.frame.width * o.frame.height
                guard oArea > area else { return false }
                let inter = o.frame.intersection(w.frame)
                guard !inter.isNull, inter.width * inter.height >= 0.9 * area else { return false }
                return abs(o.frame.maxY - w.frame.maxY) > 1      // same top edge => not a popup (e.g. tabs)
            }
            if isChild { popups.append(w) } else { kept.append(w) }
        }
        return (kept, popups)
    }

    /// One window's CGWindowList entry, looked up by id (≈0.1ms; nil = the window no longer exists).
    static func info(of id: Int) -> [String: Any]? {
        guard let n = CGWindowID(exactly: id),
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], n) as? [[String: Any]] else { return nil }
        return list.first { ($0[kCGWindowNumber as String] as? Int) == id }
    }

    /// Every window's CGWindowList entry by id, from one call (on and off screen).
    static func infoByID() -> [Int: [String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [Int: [String: Any]] = [:]
        for i in list { if let n = i[kCGWindowNumber as String] as? Int { out[n] = i } }
        return out
    }

    /// Pure: a window missing from the on-screen list is gone NOW (no debounce) when destroyed
    /// (no entry at all), or ordered out / faded out right after a close signal for it.
    static func confirmedGone(_ info: [String: Any]?, closeSignal: Bool) -> Bool {
        guard info != nil else { return true }
        return closeSignal && reallyGone(info)
    }

    /// Pure: a window missing from the on-screen list is really gone (closed, ordered out, faded
    /// out) — not just transiently unlisted — when its own entry is missing, off screen or fully
    /// transparent. Only an entry that is still on screen and visible keeps the debounce.
    static func reallyGone(_ info: [String: Any]?) -> Bool {
        guard let info else { return true }
        if (info[kCGWindowIsOnscreen as String] as? Bool) != true { return true }
        return ((info[kCGWindowAlpha as String] as? Double) ?? 1) <= 0
    }

    /// The window a title-band press would grab: the front-most kept window containing `m`, unless
    /// `m` is inside an excluded popup (a click in Chrome's omnibox list is never a grab), and only
    /// within `band` points of that window's top edge.
    static func grabTarget(at m: CGPoint, windows: [AppWindow], popups: [CGRect], band: CGFloat) -> Int? {
        guard m.x.isFinite, m.y.isFinite, !popups.contains(where: { $0.contains(m) }),
              let w = windows.first(where: { $0.frame.contains(m) }), m.y >= w.frame.maxY - band else { return nil }
        return w.id
    }

    /// Windows intersecting `screenFrame`, converted to that screen's local coordinates.
    static func local(_ windows: [AppWindow], in screenFrame: CGRect) -> [AppWindow] {
        windows.compactMap { w in
            guard w.frame.intersects(screenFrame) else { return nil }
            var l = w
            l.frame = w.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            return l
        }
    }
}

/// Snow on one window's top edge: a granular ("falling sand") heightmap of 2pt columns anchored to
/// the window's top edge — never stretched with the window. Grains flow downhill past the angle of
/// repose, pile up, and pour off unsupported ends (`takeSpill`); a resize pushes or drops the pile
/// instead of scaling it, and the scene's drag bias (`lateral`) makes it flow toward the trailing
/// side. Rendered with Core Graphics into a texture only when the shape changes (≤ 30Hz while
/// flowing).
final class WindowCap {
    static let colWidth: CGFloat = 2
    // Thin, clean strip: ~4–5pt high on average, piles up to ~8pt where snow flows together.
    static let maxHeight: CGFloat = 5.0         // ±0.5 jitter per column (snowfall growth limit)
    static let startRange: ClosedRange<CGFloat> = 2.4...3.0
    /// Angle of repose: the largest height difference between neighbouring 2pt columns (≈ 29°).
    static let repose: CGFloat = 1.1
    /// Highest a pile can get (texture bound).
    static let maxPile: CGFloat = 14
    static let jitterRange: ClosedRange<CGFloat> = -0.5...0.5
    static let below: CGFloat = 8               // texture below the top edge (corner overhang, contact shadow)
    static let side: CGFloat = 8                // texture past the side edges (overhang)
    static let headroom: CGFloat = 6
    static let icicleCount = 0                  // the reference has none

    private(set) var id: Int
    private(set) var frame: CGRect
    private(set) var order: Int
    let node = SKSpriteNode()
    private var heights: [CGFloat]
    private var jitter: [CGFloat]
    private(set) var occluders: [CGRect] = []
    private var relOccluders: [CGRect] = []

    private struct Icicle { var fx: CGFloat; var length: CGFloat; var maxLength: CGFloat; var width: CGFloat }
    private var icicles: [Icicle] = []

    /// Slow changes repaint at most every 2s; shape changes (shed, resample, occlusion) ~10Hz.
    private var dirty = true
    private var urgent = true
    private var cooldown: CGFloat = 0
    private var budget: CGFloat = 0
    private var grown: CGFloat = 0
    private var renderedWidth: CGFloat = 0

    // Granular state.
    /// Flow bias (pt of repose threshold, + = toward +x), set every frame by the scene while the
    /// window is dragged (inertia: snow flows to the trailing side) — 0 when still.
    var lateral: CGFloat = 0
    /// Short push toward an edge that moved outward (widening), decays over ~0.3s.
    private var edgeBias: CGFloat = 0
    /// True while grains are flowing (the scene steps only awake caps).
    private(set) var awake = true
    /// Snow that left the cap (unsupported ends, narrowing): scene x and area (pt²), taken by the scene.
    private var spill: [(x: CGFloat, area: CGFloat)] = []

    /// Settling back after a slide-off: columns start as a thin film and grow to `regrowTarget`.
    private var regrowTarget: [CGFloat] = []
    private var regrowLeft: CGFloat = 0

    /// `regrowHeight`: average height to settle back to (nil = fresh cap, 8–10pt); it grows in from
    /// a thin film over `regrowDuration` seconds and its icicles start from nothing.
    init(window: AppWindow, regrowHeight: CGFloat? = nil, regrowDuration: CGFloat = 0) {
        id = window.id
        frame = window.frame
        order = window.order
        let n = WindowCap.columns(for: window.frame.width)
        jitter = (0..<n).map { _ in CGFloat.random(in: WindowCap.jitterRange) }
        if let h = regrowHeight, h.isFinite {
            let target = (0..<n).map { _ in clamp(h * CGFloat.random(in: 0.85...1.15), 1, WindowCap.maxHeight) }
            if regrowDuration > 0 {
                heights = target.map { min($0, 0.6) }
                regrowTarget = target
                regrowLeft = regrowDuration
            } else {
                heights = target
            }
        } else {
            heights = (0..<n).map { _ in CGFloat.random(in: WindowCap.startRange) }
        }
        // Start at rest: ends already within the angle of repose (no spill on creation).
        heights = WindowCap.reposeProfile(heights)
        if !regrowTarget.isEmpty { regrowTarget = WindowCap.reposeProfile(regrowTarget) }
        node.anchorPoint = .zero
        resetIcicles()
        if regrowHeight != nil { for k in icicles.indices { icicles[k].length = 0 } }
        place()
    }

    /// Caps each column so both unsupported ends slope at the angle of repose.
    static func reposeProfile(_ h: [CGFloat]) -> [CGFloat] {
        let n = h.count
        return h.enumerated().map { i, v in min(v, repose * CGFloat(min(i, n - 1 - i) + 1) * 0.95) }
    }

    private static func columns(for width: CGFloat) -> Int { max(2, Int(width / colWidth) + 1) }

    private func resetIcicles() {
        let count = WindowCap.icicleCount > 0 ? min(WindowCap.icicleCount, max(2, Int(frame.width / 110))) : 0
        icicles = (0..<count).map { k in
            let fx = (CGFloat(k) + CGFloat.random(in: 0.25...0.75)) / CGFloat(count)
            return Icicle(fx: fx, length: CGFloat.random(in: 2...6), maxLength: CGFloat.random(in: 8...22),
                          width: CGFloat.random(in: 3...5))
        }
    }

    private func place() {
        node.position = CGPoint(x: frame.minX - WindowCap.side, y: frame.maxY - WindowCap.below)
    }

    /// The app replaced its window (new window number, same place): the snow stays.
    func rekey(to newID: Int) { id = newID }

    var isEmpty: Bool { heights.allSatisfy { $0 < 0.5 } }
    var averageHeight: CGFloat { heights.reduce(0, +) / CGFloat(max(heights.count, 1)) }
    /// Snow volume in pt² (height × width).
    var volume: CGFloat { heights.reduce(0, +) * WindowCap.colWidth }

    /// Follows the window. Width changes resample the heightmap keeping the snow volume.
    func update(window: AppWindow) {
        order = window.order
        guard window.frame.width.isFinite, window.frame.minX.isFinite, window.frame.maxY.isFinite else { return }
        let dL = window.frame.minX - frame.minX, dR = window.frame.maxX - frame.maxX
        if abs(dL - dR) > 0.25 {
            // Resize: the snow stays where it is in the world (it is not stretched). Columns are
            // re-indexed from the new left edge; what is no longer supported pours off, new room
            // starts empty and the pile is pushed into it (edge bias toward the widened side).
            regrowTarget = []
            regrowLeft = 0
            let n = WindowCap.columns(for: window.frame.width)
            let old = heights
            var new = [CGFloat](repeating: 0, count: n)
            let cw = WindowCap.colWidth
            for (i, h) in old.enumerated() where h > 0 {
                let x = CGFloat(i) * cw - dL                    // window-relative x in the new frame
                let f = x / cw
                let a = Int(floor(f)), u = f - floor(f)
                for (j, part) in [(a, 1 - u), (a + 1, u)] where part > 0 {
                    if j >= 0 && j < n { new[j] += h * part }
                    else { spill.append((window.frame.minX + CGFloat(j) * cw, h * part * cw)) }
                }
            }
            heights = new
            jitter = (0..<n).map { i in i < jitter.count ? jitter[i] : CGFloat.random(in: WindowCap.jitterRange) }
            // Push toward a widened side while it moves (the pile is shoved into the new room).
            if dR > 0.25 { edgeBias = min(2.2, edgeBias + 0.8) } else if dL < -0.25 { edgeBias = max(-2.2, edgeBias - 0.8) }
            awake = true
            urgent = true
        }
        frame = window.frame
        place()
        // Stretch the existing texture until the (throttled) re-render catches up.
        if renderedWidth > 0 {
            node.size = CGSize(width: frame.width + WindowCap.side * 2, height: node.size.height)
        }
    }

    func setOccluders(_ rects: [CGRect]) {
        occluders = rects
        let rel = rects.map {
            CGRect(x: ($0.minX - frame.minX).rounded(), y: ($0.minY - frame.maxY).rounded(),
                   width: $0.width.rounded(), height: $0.height.rounded())
        }
        if rel != relOccluders {
            relOccluders = rel
            urgent = true
        }
    }

    private func height(at x: CGFloat) -> CGFloat {
        let f = clamp((x - frame.minX) / WindowCap.colWidth, 0, CGFloat(heights.count - 1))
        let i = Int(f), j = min(i + 1, heights.count - 1)
        return heights[i] + (heights[j] - heights[i]) * (f - CGFloat(i))
    }

    /// Snow surface height at x, or nil if x is outside the window.
    func surface(at x: CGFloat) -> CGFloat? {
        guard x >= frame.minX, x <= frame.maxX else { return nil }
        return frame.maxY + height(at: x)
    }

    /// False where a front window covers the window's top edge.
    func isVisible(atX x: CGFloat) -> Bool {
        let p = CGPoint(x: x, y: frame.maxY + 1)
        return !occluders.contains { $0.contains(p) }
    }

    private func cap(_ i: Int) -> CGFloat { WindowCap.maxHeight + jitter[i] }

    func accumulate(rate: CGFloat, dt: CGFloat) {
        budget += rate * dt * CGFloat(heights.count)
        let lump: CGFloat = 0.5
        while budget >= lump {
            budget -= lump
            let c = Int.random(in: 0..<heights.count)
            for (k, w) in [CGFloat(0.2), 0.6, 0.2].enumerated() {
                let i = c + k - 1
                guard i >= 0, i < heights.count else { continue }
                if heights[i] < cap(i) {
                    let add = min(cap(i) - heights[i], lump * w)
                    heights[i] += add
                    grown += add
                }
            }
        }
        // Icicles grow slowly while snow is falling (melt-and-refreeze look).
        let avg = averageHeight
        for k in icicles.indices where icicles[k].length < icicles[k].maxLength * min(1, avg / 12) {
            icicles[k].length += rate * dt * 2.2
            grown += rate * dt
        }
        // Repaint only once the cap has visibly grown (~0.4pt on average).
        if grown > 0.4 * CGFloat(heights.count) {
            grown = 0
            dirty = true
        }
    }

    // MARK: Granular flow

    /// One relaxation step (call every frame while `awake` or `lateral` ≠ 0). Grains move downhill
    /// where neighbouring columns differ by more than the angle of repose (shifted by the drag /
    /// edge bias); past either end there is no support, so what flows there is spilled.
    /// Returns true if anything moved.
    @discardableResult
    func step(dt: CGFloat) -> Bool {
        let n = heights.count
        guard n >= 2, dt > 0 else { return false }
        edgeBias *= exp(-dt / 0.15)
        if abs(edgeBias) < 0.02 { edgeBias = 0 }
        let bias = clamp(lateral + edgeBias, -3, 3)
        guard awake || bias != 0 else { return false }
        let theta = WindowCap.repose
        let tRight = theta - bias, tLeft = theta + bias      // thresholds for flow toward +x / -x
        let rate: CGFloat = 1.0
        var moved: CGFloat = 0
        let cw = WindowCap.colWidth
        // A strong drag bias moves snow several columns per frame (it slides, not creeps).
        let passes = min(8, 1 + Int(abs(bias) * 2.5)) * max(1, Int((dt * 60).rounded()))
        for _ in 0..<passes { moved += relaxPass(tRight: tRight, tLeft: tLeft, rate: rate, cw: cw) }
        if moved > 0.002 { urgent = true; flowing = true } else { flowing = false }
        awake = moved > 0.0005 || bias != 0
        return moved > 0.0005
    }

    /// One sweep of the repose rule (returns the height moved).
    private func relaxPass(tRight: CGFloat, tLeft: CGFloat, rate: CGFloat, cw: CGFloat) -> CGFloat {
        let n = heights.count
        var moved: CGFloat = 0
        // Ends: the outside counts as height 0 with no support — excess beyond the threshold falls.
        if heights[0] - tLeft > 0 {
            let m = min(heights[0], (heights[0] - max(tLeft, 0)) * rate)
            if m > 0.0005 { heights[0] -= m; moved += m; spill.append((frame.minX - 0.5, m * cw)) }
        }
        if heights[n - 1] - tRight > 0 {
            let m = min(heights[n - 1], (heights[n - 1] - max(tRight, 0)) * rate)
            if m > 0.0005 { heights[n - 1] -= m; moved += m; spill.append((frame.maxX + 0.5, m * cw)) }
        }
        // Interior: alternate sweep direction (no directional artefacts from in-place updates).
        let forward = Int(elapsedSteps % 2) == 0
        elapsedSteps &+= 1
        var i = forward ? 0 : n - 2
        while forward ? i < n - 1 : i >= 0 {
            // A negative threshold (strong bias) tilts the rest slope: snow then flows even on the
            // flat and leans against the far side (inertia / a push), never past the window's end.
            let d = heights[i] - heights[i + 1]
            if d > tRight {
                let m = min(heights[i], (d - tRight) * 0.5 * rate)
                if m > 0 { heights[i] -= m; heights[i + 1] += m; moved += m }
            } else if -d > tLeft {
                let m = min(heights[i + 1], (-d - tLeft) * 0.5 * rate)
                if m > 0 { heights[i + 1] -= m; heights[i] += m; moved += m }
            }
            i += forward ? 1 : -1
        }
        return moved
    }
    private var elapsedSteps: UInt = 0
    /// Something moved in the last step (render at up to 30Hz instead of ~10Hz).
    private var flowing = false

    /// Wakes the flow (a change that may have broken the angle of repose).
    func wake() { awake = true }

    /// Snow that left the cap since the last call (scene x, area pt²).
    func takeSpill() -> [(x: CGFloat, area: CGFloat)] {
        guard !spill.isEmpty else { return [] }
        defer { spill.removeAll(keepingCapacity: true) }
        return spill
    }

    func remove(centerX: CGFloat, halfWidth: CGFloat, depth: CGFloat) -> CGFloat {
        let lo = Int(clamp((centerX - halfWidth - frame.minX) / WindowCap.colWidth, 0, CGFloat(heights.count - 1)))
        let hi = Int(clamp((centerX + halfWidth - frame.minX) / WindowCap.colWidth, 0, CGFloat(heights.count - 1)))
        var removed: CGFloat = 0
        for i in lo...hi {
            let take = min(depth, heights[i])
            heights[i] -= take
            removed += take * WindowCap.colWidth
        }
        if removed > 0 { urgent = true; awake = true }
        return removed
    }

    /// Fling: removes the snow above a thin film in `pieces` equal segments; returns each
    /// segment's center x (scene) and area (pt²). Empty segments are skipped.
    func launch(pieces: Int, keep: CGFloat = 0.4) -> [(x: CGFloat, area: CGFloat)] {
        guard pieces > 0, !heights.isEmpty else { return [] }
        var out: [(x: CGFloat, area: CGFloat)] = []
        let per = max(1, heights.count / pieces)
        var i = 0
        while i < heights.count {
            let hi = min(heights.count, i + per)
            var area: CGFloat = 0
            for k in i..<hi where heights[k] > keep {
                area += (heights[k] - keep) * WindowCap.colWidth
                heights[k] = keep
            }
            if area > 0 { out.append((frame.minX + (CGFloat(i + hi) / 2) * WindowCap.colWidth, area)) }   // every bit (volume conserved)
            i = hi
        }
        if !out.isEmpty { urgent = true }
        return out
    }

    /// Adds `area` pt² of snow around x (a clump landed here).
    func deposit(centerX x: CGFloat, area: CGFloat) {
        guard x.isFinite, area.isFinite, area > 0 else { return }
        let c = Int(clamp((x - frame.minX) / WindowCap.colWidth, 0, CGFloat(heights.count - 1)))
        let per = area / WindowCap.colWidth
        for (k, w) in [CGFloat(0.25), 0.5, 0.25].enumerated() {
            let i = c + k - 1
            guard i >= 0, i < heights.count else { continue }
            heights[i] += per * w              // never clipped (volume is conserved); the flow spreads it
        }
        urgent = true
        awake = true
    }

    func reset() {
        for i in heights.indices { heights[i] = CGFloat.random(in: WindowCap.startRange) }
        heights = WindowCap.reposeProfile(heights)
        resetIcicles()
        urgent = true
    }

    /// True when front windows cover the whole top edge.
    private var fullyCovered: Bool {
        let y = frame.maxY + 1
        return occluders.contains { $0.minX <= frame.minX && $0.maxX >= frame.maxX && $0.minY <= y && $0.maxY >= y }
    }

    // MARK: Slide-off pieces

    /// The current cap texture cut into `count` vertical slices: (texture, centre in scene coords,
    /// size, snow area of that slice in pt²). Empty if nothing visible has been rendered.
    func chunkTextures(count: Int) -> [(texture: SKTexture, center: CGPoint, size: CGSize, area: CGFloat)] {
        guard let tex = node.texture, !node.isHidden, node.size.width > 0, node.size.height > 0, count > 0 else { return [] }
        let n = heights.count
        var out: [(texture: SKTexture, center: CGPoint, size: CGSize, area: CGFloat)] = []
        for k in 0..<count {
            let u0 = CGFloat(k) / CGFloat(count), u1 = CGFloat(k + 1) / CGFloat(count)
            let sub = SKTexture(rect: CGRect(x: u0, y: 0, width: u1 - u0, height: 1), in: tex)
            let size = CGSize(width: node.size.width * (u1 - u0), height: node.size.height)
            let center = CGPoint(x: node.position.x + node.size.width * (u0 + u1) / 2, y: node.position.y + node.size.height / 2)
            let i0 = min(n - 1, Int(CGFloat(n) * u0)), i1 = min(n, max(i0 + 1, Int(CGFloat(n) * u1)))
            let area = heights[i0..<i1].reduce(0, +) * WindowCap.colWidth
            out.append((sub, center, size, area))
        }
        return out
    }

    /// Icicles currently hanging (scene coords of their middle, length) — they fall on slide-off.
    func icicleDrops() -> [(pos: CGPoint, length: CGFloat)] {
        icicles.filter { $0.length >= 2 }.map {
            (CGPoint(x: frame.minX + $0.fx * frame.width, y: frame.maxY - $0.length / 2), $0.length)
        }
    }

    // MARK: Rendering

    /// True when the texture is due for a redraw (shape / occlusion / growth changed).
    var renderDue: Bool { (urgent && cooldown <= (flowing ? 1.967 : 1.9)) || (dirty && cooldown <= 0) }
    /// How overdue the redraw is (larger = longer waiting); used to share the per-frame budget.
    var renderPriority: CGFloat { -cooldown }

    /// Ticks the repaint timer every frame; redraws only if due and `allowed` (the scene gives
    /// out a small per-frame budget so many caps never redraw in the same frame). Returns true
    /// if a texture was rendered.
    @discardableResult
    func render(dt: CGFloat, scale: CGFloat, allowed: Bool = true) -> Bool {
        if regrowLeft > 0, regrowTarget.count == heights.count, dt > 0 {
            // Ease each column toward its target; finishes exactly when regrowLeft reaches 0.
            let k = min(1, dt / regrowLeft)
            regrowLeft = max(0, regrowLeft - dt)
            for i in heights.indices where regrowTarget[i] > heights[i] {
                heights[i] += (regrowTarget[i] - heights[i]) * k
            }
            urgent = true
            if regrowLeft == 0 { regrowTarget = [] }
        }
        cooldown -= dt
        guard renderDue else { return false }
        if fullyCovered {
            node.isHidden = true
            return false
        }
        guard allowed else { return false }   // stays due; rendered on a later frame
        dirty = false
        urgent = false
        cooldown = 2.0
        if isEmpty && icicles.allSatisfy({ $0.length < 1 }) {
            node.isHidden = true
            return false
        }
        node.isHidden = false
        let side = WindowCap.side, below = WindowCap.below
        let w = frame.width
        // Bounded texture: window width (sanitized by WindowTracker) x ~68pt, never more.
        guard w.isFinite, w > 0, w <= 20_000, scale.isFinite, scale > 0, scale <= 4 else {
            node.isHidden = true
            return false
        }
        let peak = heights.max() ?? 0
        let texW = w + side * 2, texH = max(WindowCap.maxHeight, min(peak, WindowCap.maxPile)) + 4 + WindowCap.headroom + below
        let wpx = Int(ceil(texW * scale)), hpx = Int(ceil(texH * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard wpx > 0, hpx > 0,
              let ctx = CGContext(data: nil, width: wpx, height: hpx, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let maskCtx = CGContext(data: nil, width: wpx, height: hpx, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        for c in [ctx, maskCtx] {
            c.scaleBy(x: scale, y: scale)
            c.translateBy(x: side, y: below)   // origin = window's top-left corner
        }

        // 1) The pile surface: the granular heightmap, lightly smoothed (a smooth powder surface,
        //    no speckle); its ends are the piles' own repose slopes (no artificial taper).
        let n = heights.count
        let radius = 2
        var smooth = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            var sum: CGFloat = 0, wsum: CGFloat = 0
            for j in max(0, i - radius)...min(n - 1, i + radius) {
                let wgt = CGFloat(radius + 1 - abs(i - j))
                sum += heights[j] * wgt; wsum += wgt
            }
            smooth[i] = sum / max(wsum, 1)
        }
        // Path points every 2 columns (4pt): the surface stays smooth, the path is half as long.
        var pts: [CGPoint] = stride(from: 0, to: n, by: 2).map { CGPoint(x: min(CGFloat($0) * WindowCap.colWidth, w), y: smooth[$0]) }
        if (n - 1) % 2 != 0 { pts.append(CGPoint(x: w, y: smooth[n - 1])) }
        let topCurve = CGMutablePath()
        topCurve.move(to: CGPoint(x: 0, y: pts[0].y))
        for k in 0..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[k].x + pts[k + 1].x) / 2, y: (pts[k].y + pts[k + 1].y) / 2)
            topCurve.addQuadCurve(to: mid, control: pts[k])
        }
        topCurve.addLine(to: CGPoint(x: w, y: pts[pts.count - 1].y))
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 0, y: -0.6))
        body.addPath(topCurve)
        body.addLine(to: CGPoint(x: w, y: -0.6))
        body.closeSubpath()
        maskCtx.setFillColor(gray: 1, alpha: 1)
        maskCtx.addPath(body)
        maskCtx.fillPath()
        // Ends: no bead — the line simply tapers to the window's corners (handled by the taper below).
        guard let mask = maskCtx.makeImage() else { return false }

        // 2) Faint soft shadow just below the line.
        if let g = CGGradient(colorsSpace: cs, colors: [rgb(0.1, 0.15, 0.3, 0.22).cgColor, rgb(0.1, 0.15, 0.3, 0).cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: -1, y: -3, width: w + 2, height: 3))
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: -3), options: [])
            ctx.restoreGState()
        }

        // 3) Shade the masked body: bluish underside -> white top, then a soft top highlight.
        ctx.saveGState()
        ctx.resetClip()
        ctx.translateBy(x: -side, y: -below)
        ctx.clip(to: CGRect(x: 0, y: 0, width: texW, height: texH), mask: mask)
        ctx.translateBy(x: side, y: below)
        // Crisp bright white with only a hint of blue at the very bottom.
        let colors = [rgb(0.84, 0.89, 0.98).cgColor, rgb(0.97, 0.98, 1).cgColor, rgb(1, 1, 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.35, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: -0.6), end: CGPoint(x: 0, y: max(2, averageHeight)),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        // Soft 1px highlight along the top.
        ctx.saveGState()
        ctx.addPath(topCurve)
        ctx.setStrokeColor(rgb(1, 1, 1, 0.95).cgColor)
        ctx.setLineWidth(0.8)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // 4) Icicles: glassy, semi-transparent, with a highlight down one side.
        for ic in icicles where ic.length >= 1 {
            let x = ic.fx * w
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - ic.width / 2, y: 0.5))
            path.addQuadCurve(to: CGPoint(x: x, y: -ic.length), control: CGPoint(x: x - ic.width * 0.35, y: -ic.length * 0.45))
            path.addQuadCurve(to: CGPoint(x: x + ic.width / 2, y: 0.5), control: CGPoint(x: x + ic.width * 0.3, y: -ic.length * 0.45))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let ice = [rgb(0.86, 0.94, 1, 0.9).cgColor, rgb(0.72, 0.86, 1, 0.35).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: cs, colors: ice, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: x, y: 0), end: CGPoint(x: x, y: -ic.length), options: [])
            }
            ctx.restoreGState()
            ctx.setStrokeColor(rgb(1, 1, 1, 0.75).cgColor)
            ctx.setLineWidth(0.7)
            ctx.move(to: CGPoint(x: x - ic.width * 0.2, y: -0.5))
            ctx.addLine(to: CGPoint(x: x - ic.width * 0.05, y: -ic.length * 0.75))
            ctx.strokePath()
        }

        // 5) Occlusion: clear wherever a front window covers this cap.
        ctx.setBlendMode(.clear)
        for r in relOccluders { ctx.fill(r) }

        guard let img = ctx.makeImage() else { return false }
        node.texture = SKTexture(cgImage: img)
        node.size = CGSize(width: texW, height: texH)
        renderedWidth = w
        return true
    }
}
