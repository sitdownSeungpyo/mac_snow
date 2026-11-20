import AppKit
import SpriteKit
import simd

enum Intensity: Int, CaseIterable {
    case light, normal, heavy

    var title: String {
        switch self {
        case .light: return "Light"
        case .normal: return "Normal"
        case .heavy: return "Heavy"
        }
    }

    /// Flakes per second per 1280pt of screen width.
    var birthRate: CGFloat {
        switch self {
        case .light: return 14
        case .normal: return 32
        case .heavy: return 80
        }
    }

    /// Average snow accumulation in pt/s.
    var accumulation: CGFloat {
        switch self {
        case .light: return 0.02
        case .normal: return 0.05
        case .heavy: return 0.12
        }
    }
}

final class WinterScene: SKScene {
    let isMainScreen: Bool

    var intensity: Intensity = .normal { didSet { applySnowRate() } }
    var snowPaused = false { didSet { applySnowRate() } }
    var santaEnabled = true { didSet { syncSanta() } }

    private var ground: GroundSnow?
    private var emitter: SKEmitterNode?
    private var balls: [Snowball] = []
    private var gifts: [Gift] = []
    private var santa: Santa?
    private var dockBand: DockBand?

    private var lastTime: TimeInterval = 0
    private var elapsed: CGFloat = 0

    // Window-top snow caps and string lights
    var windowSnowEnabled = true {
        didSet { if !windowSnowEnabled { removeAllCaps() } }
    }
    var windowLightsEnabled = true {
        didSet { if !windowLightsEnabled { lights.clear() } }
    }
    var lightStyle: LightStyle {
        get { lights.style }
        set { lights.style = newValue }
    }
    private var appWindows: [AppWindow] = []
    private var caps: [Int: WindowCap] = [:]
    private let capLayer = SKNode()
    private let lights = StringLights()

    private enum Drag {
        case ball(Snowball)
        case santa(Santa)
        case gift(Gift)
        case plow(Snowplow)
    }
    private var drag: Drag?
    private var pendingBall: Snowball?
    private var dragOffset = CGPoint.zero
    private var dragDistance: CGFloat = 0
    private var lastMouse = CGPoint.zero
    private var samples: [(t: TimeInterval, p: CGPoint)] = []
    private weak var hoverGift: Gift?

    private let ballGravity: CGFloat = 1800
    private let gravity: CGFloat = 1500
    let maxGifts = 30
    private let maxBalls = 24

    // z layers
    private let zGround: CGFloat = 5
    private let zCaps: CGFloat = 6
    private let zLights: CGFloat = 7
    private let zGift: CGFloat = 60
    private let zSanta: CGFloat = 70
    private let zSnow: CGFloat = 80
    private let zFX: CGFloat = 90

    var isCapturingMouse: Bool { drag != nil || pendingBall != nil || linkDrag != nil }

    // Safety: transient FX budget and render liveness.
    static let maxFX = 400
    private var fxCount = 0
    /// Uptime of the last frame update. When the view is not rendering (display asleep, view
    /// never attached to a display) actions do not run, so FX must not be spawned.
    private(set) var lastUpdateUptime: TimeInterval = 0
    /// Called at the end of every update (the window's reveal gate counts rendered frames).
    var onUpdate: (() -> Void)?
    var isRendering: Bool { ProcessInfo.processInfo.systemUptime - lastUpdateUptime < 0.5 }

    init(size: CGSize, isMainScreen: Bool) {
        self.isMainScreen = isMainScreen
        super.init(size: size)
        backgroundColor = .clear
        anchorPoint = .zero
        scaleMode = .resizeFill
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMove(to view: SKView) {
        guard ground == nil else { return }
        let g = GroundSnow(width: size.width, pixelScale: view.window?.backingScaleFactor ?? 2)
        g.zPosition = zGround
        g.setDock(dockBand)
        addChild(g)
        ground = g

        capLayer.zPosition = zCaps
        addChild(capLayer)
        lights.zPosition = zLights
        addChild(lights)
        ballDeleteButton.zPosition = zFX + 5
        addChild(ballDeleteButton)
        anchorLayer.zPosition = zLights + 0.5
        addChild(anchorLayer)

        let e = makeEmitter()
        addChild(e)
        emitter = e
        applySnowRate()
        e.advanceSimulationTime(TimeInterval(e.particleLifetime))
        syncSanta()
    }

    // MARK: Configuration

    func setDock(_ band: DockBand?) {
        let had = dockBand
        dockBand = band
        let spilled0 = ground?.dockGoneSpill ?? 0
        ground?.setDock(band)
        let spilled = (ground?.dockGoneSpill ?? 0) - spilled0
        if had != nil && band == nil {
            Diag.shared.row("dockGone", note: String(format: "cap snow %.0fpt² pours to the floor", spilled))
        } else if had == nil && band != nil, let b = band {
            Diag.shared.row("dockBack", note: String(format: "minX=%.0f maxX=%.0f top=%.0f (cap starts empty)", b.minX, b.maxX, b.top))
        }
    }

    func clearObjects() {
        if let s = starterGift { starterGone(s) }
        for b in balls { b.removeFromParent() }
        for g in gifts { g.removeFromParent() }
        balls.removeAll()
        gifts.removeAll()
        if let d = drag, case .santa = d {} else { drag = nil }
        pendingBall = nil
        hoverGift = nil
        CustomizePanel.shared.validate()
    }

    func resetSnow() {
        ground?.reset()
        for cap in caps.values { cap.reset() }
    }

    // MARK: Windows (snow caps, lights, riding objects)

    private func removeAllCaps() {
        for cap in caps.values { cap.node.removeFromParent() }
        caps.removeAll()
        for b in balls { b.restingOn = nil }
        for g in gifts { g.restingOn = nil }
    }

    // Slide-off / regrow. Caps never follow a moving window. When a window is grabbed (title-bar
    // drag reported by the app) or a poll sees its bounds change, its cap slides off as chunks of
    // the cap texture (our own 60fps simulation, no window tracking), its lights drop and fade,
    // riders fall. After the window has been still for `settleDelay` a new cap regrows there.
    static let settleDelay: CGFloat = 0.4
    static let capGrowth: CGFloat = 0.25
    static let regrowDuration: CGFloat = 1.2
    static let keepFraction: CGFloat = 0.4
    private var trackedFrames: [Int: CGRect] = [:]
    private var lastBoundsChange: [Int: CGFloat] = [:]
    /// Windows whose cap slid off and that have not been still for `settleDelay` yet.
    private(set) var unsettled = Set<Int>()
    private var rememberedHeight: [Int: CGFloat] = [:]

    /// Snow sits on the top edge, so only a translation of the top edge (top-left corner) counts
    /// as a move. Height-only changes (e.g. a growing popup or a bottom-edge resize) and width
    /// changes with the same top-left are not moves (the cap just resamples its width).
    static func topEdgeMoved(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.maxY - b.maxY) > 0.5
    }

    /// Moves everything kept per window from `old` to `new` (window-number churn).
    private func adopt(from old: Int, to new: Int) {
        func move<V>(_ d: inout [Int: V]) { if let v = d.removeValue(forKey: old) { d[new] = v } }
        move(&trackedFrames); move(&stableSince); move(&lastBoundsChange); move(&rememberedHeight)
        move(&liveTracks); move(&liveMode); move(&spillBank); move(&capToTrue); move(&capVelocity)
        missing[old] = nil
        if decorated.remove(old) != nil { decorated.insert(new) }
        if unsettled.remove(old) != nil { unsettled.insert(new) }
        if let cap = caps.removeValue(forKey: old) { cap.rekey(to: new); caps[new] = cap }
        for b in balls where b.restingOn == old { b.restingOn = new }
        for g in gifts where g.restingOn == old { g.restingOn = new }
        Diag.shared.row("adopt", id: new, note: "window \(old) replaced by \(new) in the same place: snow kept")
    }

    /// A window absent from the window list counts as gone after this many consecutive polls
    /// spanning this long (one missing poll never removes anything).
    static let goneConfirmPolls = 2
    static let goneConfirmTime: CGFloat = 0.35
    private var missing: [Int: (since: CGFloat, polls: Int, window: AppWindow)] = [:]   // since: scene time
    /// Windows kept although the last poll(s) did not list them (see `setAppWindows`).
    var ghostWindows: Set<Int> { Set(missing.keys) }

    /// A new window gets no cap / garland / anchors until its top edge has been stable this long
    /// (transient popups and tooltips never get decorated).
    static let settleInDelay: CGFloat = 1.0
    private var stableSince: [Int: CGFloat] = [:]
    /// Windows that passed the settle-in delay and may carry snow, lights and anchors.
    private(set) var decorated = Set<Int>()
    var decoratedWindows: [AppWindow] { appWindows.filter { decorated.contains($0.id) } }
    func isDecorated(_ id: Int) -> Bool { decorated.contains(id) }
    /// Title-bar drags reported by the app: (direction, scene time). The slide-off itself waits for
    /// a poll confirming that the top edge moved within `grabConfirmWindow`.
    private var pendingGrabs: [Int: (dir: CGVector, t: CGFloat)] = [:]
    static let grabConfirmWindow: CGFloat = 0.3
    private(set) var slideOffCount = 0

    /// Receives the current app windows (screen-local, front-to-back) at 4-10Hz. A bounds change
    /// slides the cap off; a z-order-only change just updates occlusion.
    func setAppWindows(_ windows: [AppWindow]) { setAppWindows(windows, poll: true) }

    /// `poll` = false: a re-run with the current windows (no new list), ghosts stay as they are.
    private func setAppWindows(_ windows: [AppWindow], poll: Bool) {
        // Defensive: never build anything from a non-finite or absurd frame.
        let list = windows.filter { w in
            let f = w.frame
            return f.minX.isFinite && f.minY.isFinite && f.width.isFinite && f.height.isFinite
                && f.width > 0 && f.height > 0 && f.width < 20_000 && f.height < 20_000
        }
        // Vanished windows (minimize / hide / close detected early) are ignored while still listed;
        // once gone from the list they come back later as new windows (settle-in, regrow, riders).
        // A "vanished" window that stays listed with a stable frame for 0.6s was a false alarm.
        let now = liveClock()
        for (id, v) in vanished {
            guard let w = list.first(where: { $0.id == id }) else { vanished[id] = nil; continue }
            if w.frame != v.frame { vanished[id] = (w.frame, now) }
            else if now - v.since >= 0.6 { vanished[id] = nil; Diag.shared.row("unvanish", id: id, rect: w.frame, note: "stable while listed") }
        }
        let previous = appWindows
        let listed = list.filter { vanished[$0.id] == nil }
        // Live mode: a frame delivered by a window event is newer than this poll; keep it.
        var list2 = listed.map { w -> AppWindow in
            guard liveTracking, liveTracks[w.id] != nil, let cur = trackedFrames[w.id] else { return w }
            var l = w; l.frame = cur; return l
        }
        // A window missing from a poll (CGWindowList skips windows during app switches, Space
        // animations, fades) keeps its snow, riders and cap as a "ghost" until it has been missing
        // from `goneConfirmPolls` consecutive polls spanning `goneConfirmTime`. Explicit vanishes
        // (close / minimize / app hide) stay listed but filtered above, so they go at once.
        let rawIDs = Set(list.map { $0.id })
        if poll {
            let previousIDs = Set(previous.map { $0.id })
            for id in Array(missing.keys) where !previousIDs.contains(id) { missing[id] = nil }
            // Window-number churn: an app replaced a window by a new one in the same place (same
            // process, same frame within 1pt) while the old number went missing — it keeps the snow.
            for w in list2 where trackedFrames[w.id] == nil {
                guard let old = previous.first(where: { o in
                    !rawIDs.contains(o.id) && o.pid == w.pid && w.pid != 0 && abs(o.frame.minX - w.frame.minX) <= 1
                        && abs(o.frame.maxY - w.frame.maxY) <= 1 && abs(o.frame.width - w.frame.width) <= 1 }) else { continue }
                adopt(from: old.id, to: w.id)
            }
            for id in Array(missing.keys) where rawIDs.contains(id) {
                missing[id] = nil
                Diag.shared.row("ghostBack", id: id, note: "listed again (kept everything)")
            }
            for w in previous where !rawIDs.contains(w.id) && trackedFrames[w.id] != nil {
                var m = missing[w.id] ?? (elapsed, 0, w)
                m.polls += 1
                if m.polls >= WinterScene.goneConfirmPolls && elapsed - m.since >= WinterScene.goneConfirmTime {
                    missing[w.id] = nil
                    Diag.shared.row("ghostGone", id: w.id, rect: w.frame, note: String(format: "missing %d polls %.0fms", m.polls, Double(elapsed - m.since) * 1000))
                    continue
                }
                if m.polls == 1 { Diag.shared.row("ghost", id: w.id, rect: w.frame, note: "missing from poll") }
                missing[w.id] = m
                list2.append(m.window)               // keeps its last frame and z-order
            }
        }
        appWindows = list2
        if let r = raised, list2.first?.pid == r.pid && r.pid != 0 || list2.first.map({ r.ids.contains($0.id) }) == true || now - r.t >= WinterScene.raiseHold {
            raised = nil
            if !heldCover.isEmpty { heldCoverFrames = 0 }         // own caps unmask one frame later
        }
        var seen = Set<Int>()
        for w in list2 {
            seen.insert(w.id)
            if trackedFrames[w.id] == nil { stableSince[w.id] = elapsed }
            if let old = trackedFrames[w.id], WinterScene.topEdgeMoved(old, w.frame) {
                if liveTracking && decorated.contains(w.id) && !nonLiveWindows.contains(w.id) {
                    // Live mode without an event for this move (yet): just follow, never slide off.
                    moveRiders(on: w.id, by: CGPoint(x: w.frame.minX - old.minX, y: w.frame.maxY - old.maxY))
                } else if decorated.contains(w.id) {
                    lastBoundsChange[w.id] = elapsed
                    if !unsettled.contains(w.id) {
                        var dir = CGVector(dx: w.frame.minX - old.minX, dy: w.frame.maxY - old.maxY)
                        var reason = "topEdgeMoved"
                        if let g = pendingGrabs[w.id], elapsed - g.t <= WinterScene.grabConfirmWindow { dir = g.dir; reason = "grab" }
                        slideOff(windowID: w.id, direction: dir, reason: reason)
                    }
                } else {
                    stableSince[w.id] = elapsed      // still settling in: restart the clock
                }
            }
            pendingGrabs[w.id] = nil
            trackedFrames[w.id] = w.frame
            if !unsettled.contains(w.id) { caps[w.id]?.update(window: w) }   // order / occlusion only
        }
        for id in Array(trackedFrames.keys) where !seen.contains(id) {
            trackedFrames[id] = nil
            liveOccluder[id] = nil
            stableSince[id] = nil
            decorated.remove(id)
            pendingGrabs[id] = nil
            lastBoundsChange[id] = nil
            unsettled.remove(id)
            liveTracks[id] = nil
            liveMode[id] = nil
            // Gone (minimized, hidden, closed, other Space): everything on it disappears at once —
            // no burst, no spill, no falling riders. The snow amount is remembered (it regrows when
            // the window returns) and riders are parked to be put back on the same window.
            if let cap = caps[id] {
                rememberedHeight[id] = cap.averageHeight
                cap.node.removeFromParent()
                caps[id] = nil
                Diag.shared.row("stripRemove", id: id, note: vanished[id] != nil ? "vanished" : "gone from window list")
            } else {
                rememberedHeight[id] = nil
            }
            spillBank[id] = nil
            parkRiders(of: id, window: previous.first { $0.id == id })
        }
        settleWindows()
        refreshOccluders()
        lights.suppressed = unsettled
        // User links whose window disappeared are removed; a drag whose source vanished is cancelled.
        let ids = Set(list2.map { $0.id })
        let before = userLinks.count
        userLinks.removeAll { !ids.contains($0.a.window) || !ids.contains($0.b.window) }
        if userLinks.count != before { onUserLinksChanged?() }
        if let src = linkDrag, !ids.contains(src.window) { cancelLinkDrag() }
        syncLights()
        if lightEditMode { refreshAnchorDots() }
    }

    /// The user grabbed this window's title bar and started dragging (reported by the app from
    /// global mouse events). `direction` = drag direction (screen-local), used for the slide.
    /// Only records the drag; nothing slides off unless the next poll(s) show the top edge moved
    /// within `grabConfirmWindow` (a text-selection drag in the window never moves it).
    func windowGrabbed(_ id: Int, direction: CGVector) {
        guard decorated.contains(id), direction.dx.isFinite, direction.dy.isFinite else { return }
        pendingGrabs[id] = (direction, elapsed)
    }

    // MARK: Toy snowplow

    private(set) var plow: Snowplow?
    static let plowSpeed: CGFloat = 26
    /// Main screen only; toggled from the menu / ⌃⌥⌘P.
    var plowEnabled = false {
        didSet {
            guard plowEnabled != oldValue else { return }
            if plowEnabled && isMainScreen, plow == nil, ground != nil {
                let pl = Snowplow()
                pl.zPosition = zGift - 1
                if let view { pl.rasterize(view: view) }
                pl.position = CGPoint(x: 70, y: (ground?.floorSurface(at: 70) ?? 0) - 1)
                addChild(pl)
                pl.drift.zPosition = zGift - 1.5
                addChild(pl.drift)
                plow = pl
            } else if !plowEnabled, let pl = plow {
                if let d = drag, case .plow = d { drag = nil }
                pl.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
                dropDrift(pl)
                pl.drift.removeFromParent()
                plow = nil
            }
        }
    }

    /// Drives along the floor snow across the whole screen — behind the Dock too (it passes under
    /// the Dock's glass, plowing the floor there) — turns at the screen edges, scrapes the snow
    /// under the blade and pushes it into a little mound in front, with a light spray.
    private func updatePlow(_ dt: CGFloat) {
        guard let pl = plow, let ground else { return }
        pl.animate(time: elapsed)
        guard !pl.held else { return }
        let surface = ground.floorSurface(at: pl.position.x) - 1
        if pl.airborne {                                           // dropped: fall back onto the snow
            pl.vy -= gravity * dt
            pl.position.y += pl.vy * dt
            if pl.position.y <= surface { pl.position.y = surface; pl.vy = 0; pl.airborne = false }
            return
        }
        let nx = pl.position.x + pl.dir * WinterScene.plowSpeed * dt
        let front = nx + pl.dir * (20 + pl.driftLength)
        if front < 4 || front > size.width - 4 || nx < 22 || nx > size.width - 22 {
            dropDrift(pl)              // leave the pile behind as a mound, then turn around
            pl.turnAround()
            return
        }
        pl.position.x = nx
        // Scrape under the blade into the drift (until the drift is as big as it gets).
        if !pl.driftFull {
            let room = max(0, 0.88 * Snowplow.driftMaxHeight * Snowplow.driftMaxHeight - pl.driftVolume)
            pl.driftVolume += ground.scrapeFloor(at: pl.bladeX, dir: pl.dir, keep: 10, maxArea: room)
        }
        pl.position.y = ground.floorSurface(at: pl.position.x) - 1
        pl.updateDriftTexture(scale: view?.window?.backingScaleFactor ?? 2)
        pl.drift.xScale = pl.dir
        pl.drift.position = CGPoint(x: pl.bladeX - pl.dir * 1, y: ground.floorSurface(at: pl.bladeX + pl.dir * 3) - 2)
    }

    /// The plow is behind the Dock (it can't be clicked there; the Dock takes the click).
    func plowUnderDock(_ pl: Snowplow) -> Bool {
        guard let b = dockBand else { return false }
        return pl.position.x >= b.minX - 8 && pl.position.x <= b.maxX + 8 && pl.position.y < b.top
    }

    private func dropDrift(_ pl: Snowplow) {
        guard let ground else { return }
        let len = pl.driftLength
        let v = pl.releaseDrift()
        ground.depositDriftFloor(fromX: pl.bladeX, dir: pl.dir, length: len, area: v)
    }

    // MARK: Live window tracking (SkyLight move/resize events)

    /// True while window move/resize events arrive in real time: caps, riders and lights follow
    /// the window exactly; fast motion sheds small snowballs and wobbles riders; a violent shake
    /// throws riders off. False = fallback: slide-off on move, regrow when still.
    var liveTracking = false {
        didSet { if liveTracking != oldValue { lights.suppressed = unsettled } }
    }
    /// In live mode, windows whose events don't arrive (per-window fallback): they slide off on move.
    var nonLiveWindows = Set<Int>()
    static let riderFallAccel: CGFloat = 70_000     // pt/s² of the drawn (smoothed) motion: only a violent shake throws riders off
    static let liveVelocityTau: CGFloat = 0.06       // s, velocity smoothing for wobble / fall-off
    /// Teleport detection is time-aware: a real fast fling (events 100–200pt apart at ~6000pt/s)
    /// must interpolate. A sample is a jump (snap / programmatic move: everything snaps there, no
    /// velocity, wobble, throw-off or shedding) only if it is > `liveTeleportFar` away, or > `liveTeleport`
    /// away AND (implied speed > `liveTeleportSpeed`, or no event for > `liveTeleportPause` before it).
    static let liveTeleport: CGFloat = 120
    static let liveTeleportFar: CGFloat = 600
    static let liveTeleportSpeed: CGFloat = 15_000          // pt/s (gap floored at one display frame)
    static let liveTeleportPause: TimeInterval = 0.25
    private(set) var liveTeleportCount = 0

    static func isLiveTeleport(distance: CGFloat, gap: TimeInterval) -> Bool {
        guard distance.isFinite else { return true }
        if distance > liveTeleportFar { return true }
        guard distance > liveTeleport else { return false }
        return gap > liveTeleportPause || distance / CGFloat(max(gap, 1.0 / 60)) > liveTeleportSpeed
    }

    // Render-time smoothing. Events arrive irregularly (live: mean ≈ 20ms, gaps up to ~150ms), so
    // they are only recorded (timestamped on arrival); each display frame draws the window at a
    // time-interpolated position about one average interval behind the newest sample.
    static let maxExtrapolation: TimeInterval = 0.04   // s past the newest sample, then hold
    static let dragEndAfter: TimeInterval = 0.12       // no events this long = drag over
    static let renderDelayRange: ClosedRange<TimeInterval> = 0.02...0.04   // 1.5× median event interval, clamped
    /// The drawn edges follow a smoothed path through the samples (`livePath`), sampled
    /// `renderDelay` behind. When new data revises the path at the previously drawn time (after an
    /// extrapolation / hold, or at the end of a drag), the position difference goes into an offset
    /// that decays critically damped (τ 30ms): no snaps.
    static let correctionTau: Double = 0.03
    static let maxEdgeSpeed: Double = 8000            // pt/s per edge (tangent clamp)
    static let extrapolationFade: Double = 0.008
    static let delaySlew: Double = 0.03               // s of render-delay change per second (no time jumps)
    /// Event timestamps are arrival times and jitter (a late event makes a 15000pt/s burst between two
    /// samples), so the path is a local linear regression of the samples with a triangular kernel
    /// (half-width 50ms): steady motion is reproduced exactly, timestamp jitter is averaged out, and
    /// the path is continuous in time (samples enter and leave the kernel with weight 0).
    static let pathKernel: Double = 0.05
    /// Monotonic clock for live samples (injectable for the offscreen harness).
    var liveClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private struct LiveTrack {
        var samples: [(t: TimeInterval, r: CGRect)]
        var intervals: [TimeInterval] = [0.02]     // recent event intervals (median => render delay)
        var shown: CGRect
        var vel = CGVector.zero                    // smoothed velocity of the drawn top edge
        var lastShed: CGFloat = -10
        var resized = false                        // the width changed during this track (an edge drag)
        // Edges are (minX, minY, maxX, maxY). Path value / slope at the last drawn time, and the
        // correction offset (drawn = path + off) with its velocity.
        var delay: TimeInterval = 0
        var prevRenderT: TimeInterval?
        var prevTarget = SIMD4<Double>(repeating: 0)
        var off = SIMD4<Double>(repeating: 0)
        var pathVel: CGVector?                     // top-left velocity of the sample path (data, no gap artefacts)
        var wasSettling = false
        var lastReversal: CGFloat = -10            // scene time of the last direction reversal
        var offVel = SIMD4<Double>(repeating: 0)

        var renderDelay: TimeInterval {
            let s = intervals.sorted()
            let median = s[s.count / 2]
            return min(max(median * 1.5, WinterScene.renderDelayRange.lowerBound), WinterScene.renderDelayRange.upperBound)
        }
        mutating func addInterval(_ gap: TimeInterval) {
            intervals.append(min(gap, 0.06))
            if intervals.count > 9 { intervals.removeFirst(intervals.count - 9) }
        }
    }

    private static func edges(_ r: CGRect) -> SIMD4<Double> {
        SIMD4(Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY))
    }
    private static func rect(_ e: SIMD4<Double>) -> CGRect {
        CGRect(x: e[0], y: e[1], width: max(1, e[2] - e[0]), height: max(1, e[3] - e[1]))
    }
    private var liveTracks: [Int: LiveTrack] = [:]
    private(set) var liveShedCount = 0
    /// Drawing mode of the last frame per window (diag / harness): interp / extrap / hold / settle.
    private(set) var liveMode: [Int: String] = [:]

    /// A real-time window event (screen-local Cocoa coordinates): recorded, drawn next frames.
    func liveWindowFrame(_ id: Int, _ f: CGRect) {
        guard liveTracking, f.minX.isFinite, f.minY.isFinite, f.width.isFinite, f.height.isFinite, f.width > 0, f.height > 0,
              let i = appWindows.firstIndex(where: { $0.id == id }) else { return }
        let now = liveClock()
        liveOcclusionChanged(id, old: liveOccluder[id]?.frame ?? appWindows[i].frame, new: f)
        if var tr = liveTracks[id] {
            let last = tr.samples.last!
            let gap = now - last.t
            if WinterScene.isLiveTeleport(distance: hypot(f.minX - last.r.minX, f.maxY - last.r.maxY), gap: gap) {
                // Jump: snap everything there.
                let old = tr.shown
                tr = LiveTrack(samples: [(now, f)], intervals: tr.intervals, shown: f)
                liveTracks[id] = tr
                liveTeleportCount += 1
                Diag.shared.row("liveTeleport", id: id, rect: f, note: String(format: "from=%.0f,%.0f gapMs=%.1f", last.r.minX, last.r.maxY, gap * 1000))
                applyLive(index: i, frame: f, previous: old, velocity: .zero, accel: .zero, dt: 1.0 / 60, teleport: true)
                return
            }
            if gap > 0.0005 && gap < 0.2 { tr.addInterval(gap) }
            if gap >= 0.2 { tr.samples = [(now - tr.renderDelay, tr.shown)] }     // restarting after a pause
            // Events < 4ms apart (move + resize pairs, coalesced bursts) carry no timing information:
            // the newer replaces the older (a near-zero interval would make a huge slope).
            if gap < 0.004 && tr.samples.count >= 2 { tr.samples.removeLast() }
            if abs(f.width - last.r.width) > 0.25 { tr.resized = true }
            tr.samples.append((now, f))
            if tr.samples.count > 10 { tr.samples.removeFirst(tr.samples.count - 10) }
            liveTracks[id] = tr
        } else {
            let cur = appWindows[i].frame
            // No earlier event for this window: treated as following a pause.
            if WinterScene.isLiveTeleport(distance: hypot(f.minX - cur.minX, f.maxY - cur.maxY), gap: .infinity) {
                // First event is already a jump (snap / programmatic move): snap, never glide.
                liveTracks[id] = LiveTrack(samples: [(now, f)], shown: f)
                liveTeleportCount += 1
                Diag.shared.row("liveTeleport", id: id, rect: f, note: String(format: "from=%.0f,%.0f first", cur.minX, cur.maxY))
                applyLive(index: i, frame: f, previous: cur, velocity: .zero, accel: .zero, dt: 1.0 / 60, teleport: true)
                return
            }
            var tr = LiveTrack(samples: [(now - 0.02, cur), (now, f)], shown: cur)
            tr.resized = abs(f.width - cur.width) > 0.25
            liveTracks[id] = tr
        }
    }

    /// The sample path at time `t`: a local linear regression of the samples (triangular kernel of
    /// half-width `pathKernel`, widened while it holds fewer than two samples) evaluated at `t`.
    /// Past the newest sample the fit at the newest sample is extrapolated with its slope, fading
    /// out (τ 8ms: a window that really stopped is overshot by ≤ 8ms of its speed) and
    /// held after `maxExtrapolation`.
    private static func livePath(_ s: [(t: TimeInterval, r: CGRect)], at t: TimeInterval) -> SIMD4<Double> {
        guard let first = s.first, let newest = s.last else { return .zero }
        if s.count == 1 || t <= first.t { return edges(t <= first.t ? first.r : newest.r) }
        let te = min(t, newest.t)
        var (value, slope) = fit(s, at: te)
        if t > newest.t {
            let e = min(t - newest.t, maxExtrapolation)
            value += slope * (extrapolationFade * (1 - exp(-e / extrapolationFade)))
        }
        return value
    }

    /// Kernel-weighted linear fit at `t`: value and slope (slope clamped to `maxEdgeSpeed`).
    private static func fit(_ s: [(t: TimeInterval, r: CGRect)], at t: TimeInterval) -> (SIMD4<Double>, SIMD4<Double>) {
        var hw = pathKernel
        for _ in 0..<4 {
            var sw = 0.0, st = 0.0, stt = 0.0, n = 0
            var sy = SIMD4<Double>(repeating: 0), sty = SIMD4<Double>(repeating: 0)
            for x in s {
                let w = max(0, 1 - abs(x.t - t) / hw)
                guard w > 0 else { continue }
                let dt = x.t - t, y = edges(x.r)
                sw += w; st += w * dt; stt += w * dt * dt; sy += y * w; sty += y * (w * dt); n += 1
            }
            if n >= 2 {
                let den = sw * stt - st * st
                if den > 1e-12 * max(sw * stt, 1e-12) {
                    var b = (sty * sw - sy * st) / den
                    b = simd_clamp(b, SIMD4(repeating: -maxEdgeSpeed), SIMD4(repeating: maxEdgeSpeed))
                    let a = (sy - b * st) / sw
                    return (a, b)
                }
                return (sy / sw, .zero)
            }
            hw *= 2
        }
        // Sparse samples: nearest one, no slope.
        let nearest = s.min { abs($0.t - t) < abs($1.t - t) }!
        return (edges(nearest.r), .zero)
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ u: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * u, y: a.minY + (b.minY - a.minY) * u,
               width: a.width + (b.width - a.width) * u, height: a.height + (b.height - a.height) * u)
    }

    /// Per display frame: draw every live window at its interpolated position.
    private func stepLive(_ dt: CGFloat) {
        guard !liveTracks.isEmpty else { return }
        let now = liveClock()
        for (id, var tr) in liveTracks {
            guard let i = appWindows.firstIndex(where: { $0.id == id }), let newest = tr.samples.last else { liveTracks[id] = nil; continue }
            // Render delay: 1.5× the median interval, slewed (a sudden change would jump in time).
            // A window with a cap window is drawn by WindowServer itself; the simulation then runs
            // without render delay (overlay-drawn pieces — clumps, ✕, strands — stay closest to it).
            let lowLatency = capWorlds[id] != nil
            let want = lowLatency ? 0 : tr.renderDelay
            let slew = WinterScene.delaySlew * Double(max(dt, 1.0 / 240))
            tr.delay = (tr.delay == 0 || lowLatency) ? want : tr.delay + min(max(want - tr.delay, -slew), slew)
            let renderT = now - tr.delay
            let settling = now - newest.t > WinterScene.dragEndAfter
            let samples = tr.samples
            let path: (TimeInterval) -> SIMD4<Double> = { t in
                settling ? WinterScene.edges(newest.r) : WinterScene.livePath(samples, at: t)
            }
            let ahead = renderT - newest.t
            let mode = settling ? "settle" : (ahead <= 0 ? "interp" : (ahead > WinterScene.maxExtrapolation ? "hold" : "extrap"))
            let target = path(renderT)
            // New data revised the path where we drew last frame (an extrapolation that ran ahead, the
            // end of a drag): carry the position difference in the offset so nothing jumps. The old
            // velocity is deliberately not carried: that would overshoot when the window really
            // slowed down (and then move backwards).
            if let pt = tr.prevRenderT { tr.off += tr.prevTarget - path(pt) }
            tr.prevRenderT = renderT
            tr.prevTarget = target
            // Flicks / reversals / stops are judged on the data (the fitted sample path), not on the
            // drawn motion, whose catch-ups after event gaps look like accelerations too.
            let fitSlope = settling ? SIMD4<Double>(repeating: 0) : WinterScene.fit(samples, at: min(renderT, newest.t)).1
            let pv = CGVector(dx: fitSlope[0], dy: fitSlope[3])
            let pathAccel = tr.pathVel.map { CGVector(dx: (pv.dx - $0.dx) / max(dt, 1.0 / 240), dy: (pv.dy - $0.dy) / max(dt, 1.0 / 240)) } ?? .zero
            let prevPathVel = tr.pathVel ?? .zero
            tr.pathVel = pv
            // Offset decays critically damped (exact solution).
            let w = 1 / WinterScene.correctionTau
            let fdt = Double(max(dt, 1.0 / 240))
            let e = exp(-w * fdt)
            let o0 = tr.off, v0 = tr.offVel
            tr.off = (o0 + (v0 + o0 * w) * fdt) * e
            tr.offVel = (v0 - (v0 + o0 * w) * (w * fdt)) * e
            let old = tr.shown
            var n = WinterScene.rect(target + tr.off)
            let done = mode == "settle" && abs(n.minX - newest.r.minX) < 0.25 && abs(n.maxY - newest.r.maxY) < 0.25
                && abs(n.width - newest.r.width) < 0.25 && abs(n.minY - newest.r.minY) < 0.25
                && abs(tr.offVel[0]) + abs(tr.offVel[3]) < 8
            if done { n = newest.r }
            // Smoothed velocity / acceleration of the DRAWN motion (rider wobble, throw-off).
            let raw = CGVector(dx: (n.minX - old.minX) / max(dt, 1.0 / 240), dy: (n.maxY - old.maxY) / max(dt, 1.0 / 240))
            let kv = 1 - exp(-dt / WinterScene.liveVelocityTau)
            let v = CGVector(dx: tr.vel.dx + (raw.dx - tr.vel.dx) * kv, dy: tr.vel.dy + (raw.dy - tr.vel.dy) * kv)
            let a = CGVector(dx: (v.dx - tr.vel.dx) / max(dt, 1.0 / 240), dy: (v.dy - tr.vel.dy) / max(dt, 1.0 / 240))
            // A direction reversal at speed (shaking) — riders are thrown only while shaking, never by
            // a single hard stop of a fling.
            if v.dx * tr.vel.dx < 0 && abs(v.dx) > 150 && abs(tr.vel.dx) > 150 { tr.lastReversal = elapsed }
            let shaking = elapsed - tr.lastReversal < 0.35
            tr.vel = done ? .zero : v
            tr.shown = n
            liveMode[id] = mode
            applyLive(index: i, frame: n, previous: old, velocity: v, accel: a, dt: dt, teleport: false, shaking: shaking)
            if done {
                liveTracks[id] = nil
                liveMode[id] = nil
                capToTrue[id] = nil
                capVelocity[id] = nil
                refreshOccluders()               // occlusion of the dragged cap catches up once
            } else {
                // A flick / reversal (hard brake of the sample path while interpolating real data)
                // or a stop after a fast move (the drag ends at > `shedStopSpeed`): a few soft
                // clumps, ≤ 3/s. Steady drags, event gaps and catch-ups never shed.
                let pam = hypot(pathAccel.dx, pathAccel.dy)
                let prevSpeed = hypot(prevPathVel.dx, prevPathVel.dy)
                let braking = pathAccel.dx * prevPathVel.dx + pathAccel.dy * prevPathVel.dy < 0
                let flick = (mode == "interp" || (lowLatency && !settling)) && braking && pam > WinterScene.shedAccel * 2 && prevSpeed > 300
                let stop = settling && !tr.wasSettling && prevSpeed > WinterScene.shedStopSpeed
                // Drag (cap windows): inertia + air drag push the granular snow toward the trailing
                // side; it flows there and pours off the trailing end as a sand stream.
                // (A cap held for a resize shows its content at scene x: no horizontal offset then.)
                let toScene = CGVector(dx: capHeld(id) ? 0 : newest.r.minX - n.minX, dy: newest.r.maxY - n.maxY)
                capToTrue[id] = toScene
                // Spilled snow inherits the window's velocity only when it is carried (a move, not a resize).
                let resizing = tr.samples.count >= 2 && abs(tr.samples[tr.samples.count - 1].r.width - tr.samples[tr.samples.count - 2].r.width) > 0.25
                capVelocity[id] = resizing ? .zero : pv
                if lowLatency && dragSnowSlides && !settling, let cap = caps[id] {
                    let g = -pathAccel.dx - pv.dx * 5         // ≥ ~1100pt/s flat snow starts to slide
                    cap.lateral = clamp(g / 5000, -2.6, 2.6)
                }
                if flick || stop, elapsed - tr.lastShed >= WinterScene.shedCooldown, let cap = caps[id] {
                    tr.lastShed = elapsed
                    if lowLatency && dragSnowSlides && prevSpeed > WinterScene.flingSpeed {
                        flingSnow(cap, velocity: prevPathVel, toTrue: toScene)
                    } else {
                        let jolt = stop ? CGVector(dx: -prevPathVel.dx / 0.05, dy: -prevPathVel.dy / 0.05) : pathAccel
                        shedSoftClumps(cap, accel: jolt, velocity: prevPathVel)
                    }
                }
                tr.wasSettling = settling
                liveTracks[id] = tr
            }
            if Diag.shared.enabled && liveDiagRows < WinterScene.maxLiveDiagRows {
                liveDiagRows += 1
                Diag.shared.row("liveFrame", id: id, rect: n, note: String(format: "dtMs=%.1f newestX=%.1f newestTop=%.1f ageMs=%.1f mode=%@ delayMs=%.1f offX=%.1f",
                                                                       Double(dt) * 1000, newest.r.minX, newest.r.maxY, (now - newest.t) * 1000, mode, tr.delay * 1000, tr.off[0]))
            }
        }
        if lightEditMode { refreshAnchorDots() }
    }
    private var liveDiagRows = 0

    /// The cap of `id` stays where it is for a resize (see `CapMover.originX`): its content is
    /// then drawn at scene x (both strip ends exact, the stationary one never moves).
    private func capHeld(_ id: Int) -> Bool {
        guard let a = capWorlds[id]?.anchor?() else { return false }
        return a.resizing || (liveTracks[id]?.resized ?? false)
    }
    static let maxLiveDiagRows = 60_000

    /// Windows currently drawn through live smoothing (their occlusion is frozen until they settle).
    var liveTrackedWindows: Set<Int> { Set(liveTracks.keys) }

    // MARK: Cap windows (per-window snow windows ordered above their app window)

    /// Window id -> the content root of its cap window (live mode). Nodes parented there keep
    /// scene coordinates (see `CapWorld`); everything else stays in this overlay scene.
    private var capWorlds: [Int: CapWorld] = [:]
    var cappedWindows: Set<Int> { Set(capWorlds.keys) }
    var capStripZ: CGFloat { zCaps }
    var capGarlandZ: CGFloat { zLights }
    /// "창 끌 때 눈: 미끄러져 떨어짐" (true) / "붙어 있음" (false).
    var dragSnowSlides = true
    /// Hybrid cap ordering: crop each cap to what front windows leave visible.
    var capMasking = false
    /// Child / popup windows (screen-local) that hide cap snow too (e.g. Chrome's omnibox list).
    var occluderPopups: [CGRect] = []
    /// Per popup: how many windows are in front of it (it hides snow only of windows behind it;
    /// a background app's tooltip never blinks the front window's snow). Missing = in front of all.
    var occluderPopupRanks: [Int] = []
    /// Raw bounds of the latest window event per window (scene coordinates) and when it came:
    /// occlusion uses these (not the smoothed or polled frames), and a window that is being
    /// moved by events counts as frontmost (the click that drags it activates it).
    private var liveOccluder: [Int: (frame: CGRect, t: TimeInterval)] = [:]
    static let liveOccluderHold: TimeInterval = 0.4

    /// A window the user just clicked (it is being raised): front-most for masking until a poll
    /// shows it in front (or `raiseHold` passes), so a cap behind it never shows over it for a poll.
    private var raised: (ids: [Int], pid: Int, t: TimeInterval)?
    /// "Hide early, show late": a prediction may only ADD coverage. While a raise is predicted,
    /// the raised windows cover every other cap; their own caps keep the cover they had (the
    /// windows in front of them at the raise) until a poll confirms the new order, and one more
    /// frame after that (WindowServer composites the reorder before our caps re-render).
    private var heldCover: [Int: [CGRect]] = [:]
    private var heldCoverFrames = -1                 // > 0: frames left after the confirmation
    private func holdCover(of ids: [Int]) {
        for id in ids {
            guard let me = appWindows.first(where: { $0.id == id }) else { continue }
            heldCover[id] = appWindows.filter { $0.order < me.order && !ids.contains($0.id) }.map { $0.frame }
        }
        heldCoverFrames = -1
    }
    static let raiseHold: TimeInterval = 0.6
    func windowRaised(_ id: Int) {
        guard let w = appWindows.first(where: { $0.id == id }), appWindows.first?.id != id else { return }
        holdCover(of: [id])
        raised = ([id], w.pid, liveClock())
        Diag.shared.row("raised", id: id, note: "click: covers other caps until a poll confirms (its own cap unchanged)")
        hideCapsUnder([id], why: "click")
        if !capWorlds.isEmpty { syncCapWorlds() }      // masks now, not at the next frame
    }

    /// Caps of other windows whose drawing region a just-raised window overlaps: their current
    /// drawables (rendered before the raise; strip-only caps render at 15fps) would paint snow
    /// over the raised window until they re-render with the new mask. They are hidden now — a
    /// WindowServer alpha change, no render — and shown again once rendered (live ⌘Tab flash).
    private func hideCapsUnder(_ ids: [Int], why: String) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let raisedWins = appWindows.filter { ids.contains($0.id) }
        let front = raisedWins.map { $0.frame }
        let raisedOrder = raisedWins.map { $0.order }.min() ?? Int.max
        var hidden: [Int] = []
        // Only caps of windows now IN FRONT of the raised window(s) can end up under them; a cap
        // already behind them is already masked by them (live: hiding those too made a capped
        // window's snow and riders blink whenever another window over it was clicked / dragged).
        for (cid, cw) in capWorlds where !ids.contains(cid) {
            guard let w = appWindows.first(where: { $0.id == cid }), w.order < raisedOrder else { continue }
            // Only when a raised window reaches ABOVE this window's top edge over the strip: then
            // the strip / riders would be painted over it. A raised window whose top is at or
            // below this one's (e.g. two maximized windows) leaves the strip visible above it —
            // hiding it then is just a blink (live: cmux ⇄ Spotify, 9 blinks in one diag run).
            let line = CGRect(x: w.frame.minX - CapGeometry.side, y: w.frame.maxY - 8, width: w.frame.width + 2 * CapGeometry.side, height: 8)
            guard front.contains(where: { $0.maxY > w.frame.maxY + 3 && $0.intersection(line).width >= 8 && $0.intersects(line) }) else { continue }
            cw.hideUntilRendered?(why)
            hidden.append(cid)
        }
        lastFastHide = hidden
        if !hidden.isEmpty {
            Diag.shared.row("capHideFast", note: String(format: "%@: caps %@ hidden in %.0fµs", why, hidden.map(String.init).joined(separator: " "), Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000))
        }
    }
    /// Harness: caps hidden by the last raise.
    private(set) var lastFastHide: [Int] = []

    /// An app was activated (⌘Tab, Dock, click): WindowServer brings its windows to the front
    /// now; the window list shows it 30–120ms later. Masks treat that app's windows as
    /// front-most at once, so no back window's snow is ever drawn over them meanwhile.
    func appActivated(pid: Int) {
        let ids = appWindows.filter { $0.pid == pid && pid != 0 }.sorted { $0.order < $1.order }.map { $0.id }
        guard !ids.isEmpty, appWindows.first?.pid != pid else { return }
        holdCover(of: ids)
        raised = (ids, pid, liveClock())
        Diag.shared.row("raised", id: ids[0], note: "app activated pid=\(pid): \(ids.count) window(s) cover other caps until a poll confirms (own caps unchanged)")
        hideCapsUnder(ids, why: "app activated")
        if !capWorlds.isEmpty { syncCapWorlds() }      // masks now, not at the next frame
    }

    /// Windows as occluders: event bounds where fresh, moving windows first, then a just-clicked
    /// window, then poll z-order.
    private func occluderWindows() -> [AppWindow] {
        let now = liveClock()
        var list = appWindows
        var moving = Set<Int>()
        for i in list.indices {
            if let o = liveOccluder[list[i].id], now - o.t < WinterScene.liveOccluderHold {
                list[i].frame = o.frame
                moving.insert(list[i].id)
            }
        }
        if !moving.isEmpty {
            list.sort { (moving.contains($0.id) ? 0 : 1, $0.order) < (moving.contains($1.id) ? 0 : 1, $1.order) }
            for i in list.indices { list[i].order = i }
        }
        return list
    }

    /// Visible region of one cap world (hybrid ordering), from the given occluder list.
    private func updateMask(_ id: Int, _ cw: CapWorld, occluders list: [AppWindow]) {
        guard let w = appWindows.first(where: { $0.id == id }), let me = list.first(where: { $0.id == id }) else { return }
        let region = CGRect(x: w.frame.minX - CapGeometry.side, y: w.frame.maxY - CapGeometry.garlandBelow,
                            width: w.frame.width + 2 * CapGeometry.side, height: CapGeometry.garlandBelow + CapGeometry.maxAbove)
        let pops = occluderPopups.enumerated().filter { k, _ in k >= occluderPopupRanks.count || occluderPopupRanks[k] <= w.order }.map { $0.1 }
        var front = list.filter { $0.order < me.order && $0.id != id }.map { $0.frame } + pops
        // Predictions only add coverage: a raised window covers every other cap; a raised
        // window's own cap keeps the cover it had until the new order is confirmed (+1 frame).
        if let r = raised, liveClock() - r.t < WinterScene.raiseHold, !r.ids.contains(id) {
            front += appWindows.filter { r.ids.contains($0.id) }.map { $0.frame }
        }
        if let held = heldCover[id] { front += held }
        cw.setVisible(CapGeometry.visibleRects(cap: region, occluders: front), region: region)
    }

    /// A window event moved `id` from `old` to `new`: re-mask, right now, every cap behind it whose
    /// region touches either frame (the occluded boundary follows the real window, not the poll).
    private func liveOcclusionChanged(_ id: Int, old: CGRect?, new f: CGRect) {
        liveOccluder[id] = (f, liveClock())
        guard capMasking, !capWorlds.isEmpty else { return }
        let list = occluderWindows()
        for (cid, cw) in capWorlds where cid != id {
            guard let w = appWindows.first(where: { $0.id == cid }) else { continue }
            let region = CGRect(x: w.frame.minX - CapGeometry.side, y: w.frame.maxY - CapGeometry.garlandBelow,
                                width: w.frame.width + 2 * CapGeometry.side, height: CapGeometry.garlandBelow + CapGeometry.maxAbove)
            guard region.intersects(f) || (old.map { region.intersects($0) } ?? false) else { continue }
            updateMask(cid, cw, occluders: list)
        }
    }
    /// A flick / stop faster than this launches the remaining snow off the line (pt/s).
    static let flingSpeed: CGFloat = 2500

    func attachCapWorld(_ w: CapWorld) {
        capWorlds[w.target] = w
        lights.capped = cappedWindows
        syncCapWorlds()
        refreshOccluders()
    }

    /// Before a cap window goes away: its nodes come back into this scene (same coordinates).
    func detachCapWorld(_ id: Int) {
        guard capWorlds.removeValue(forKey: id) != nil else { return }
        lights.capped = cappedWindows
        syncCapWorlds()
        refreshOccluders()
    }

    private func reparent(_ n: SKNode, to p: SKNode) {
        // Plain re-attach: both containers use scene coordinates, so the position stays as is.
        n.removeFromParent()
        p.addChild(n)
    }

    /// Per frame: place each cap world for the frame the simulation uses, and put strips, riders
    /// and garlands into the cap window of their window (or back into the overlay).
    private func syncCapWorlds() {
        var riderTop: [Int: CGFloat] = [:]
        var occluders: [AppWindow]?
        for (id, cw) in capWorlds {
            guard let w = appWindows.first(where: { $0.id == id }) else { continue }
            var off = CapGeometry.worldOffset(targetInScene: w.frame, below: cw.below)
            if cw.anchor != nil {
                let newest = liveTracks[id]?.samples.last?.r ?? w.frame
                cw.cover?(min(w.frame.minX, newest.minX), max(w.frame.maxX, newest.maxX))   // may grow the cap first
            }
            if let a = cw.anchor?() {
                // Held for a resize: content at scene x. Moved: glued to the cap at its offset k
                // to the target (WindowServer carries both; the drawn frame stays inside the cap).
                off.x = (a.resizing || liveTracks[id]?.resized == true) ? -a.x : -(w.frame.minX - a.k)
            }
            cw.place(offset: off)
            if capMasking {
                // Region the cap can draw in (generous height), minus windows in front of it
                // (event bounds for moving windows; see `occluderWindows`).
                updateMask(id, cw, occluders: occluders ?? { occluders = occluderWindows(); return occluders! }())
            } else {
                cw.clearMask()
            }
        }
        for cap in caps.values {
            let want: SKNode = capWorlds[cap.id]?.strips ?? capLayer
            if cap.node.parent !== want { reparent(cap.node, to: want) }
        }
        for b in balls {
            let r = root(of: b)
            var want: SKNode = self
            if !r.held, !b.held, let id = r.restingOn, let cw = capWorlds[id] {
                want = cw.root
                if let w = appWindows.first(where: { $0.id == id }) {
                    // Top of the stack incl. a hat (~0.9r above the head ball).
                    riderTop[id] = max(riderTop[id] ?? 0, b.position.y + b.radius * 1.9 - w.frame.maxY)
                }
            }
            if b.parent !== want { reparent(b, to: want) }
        }
        for g in gifts {
            var want: SKNode = self
            if !g.held, let id = g.restingOn, let cw = capWorlds[id] { want = cw.root }
            if g.parent !== want { reparent(g, to: want) }
        }
        for (id, nodes) in lights.garlandNodes() {
            let want: SKNode = capWorlds[id]?.garland ?? lights
            for n in nodes where n.parent !== want { reparent(n, to: want) }
        }
        for (id, cw) in capWorlds {
            cw.neededAbove = CapGeometry.neededAbove(riderTop: riderTop[id] ?? 0)
            cw.hasRiders = riderTop[id] != nil
            cw.hasGarland = !cw.garland.children.isEmpty
            cw.animated = cw.hasRiders || cw.hasGarland
            cw.neededBelow = CapGeometry.garlandBelow          // constant (see `CapWorld.below`)
        }
    }

    /// True if `p` lies inside a window in front of window `id` (a rider there is hidden; in a cap
    /// window WindowServer hides it), so the overlay must not take that click.
    private func riderCovered(_ p: CGPoint, on id: Int?) -> Bool {
        let list = occluderWindows()
        guard let id, let w = list.first(where: { $0.id == id }) else { return false }
        return list.contains { $0.order < w.order && $0.frame.contains(p) }
    }

    /// Fling (hard stop / flick above `flingSpeed`): the remaining snow launches off the line as
    /// a spray of grains with the window's velocity, arcs down and lands on lower windows, the
    /// Dock or the ground (adding to them).
    private func flingSnow(_ cap: WindowCap, velocity v: CGVector, toTrue: CGVector) {
        let pieces = cap.launch(pieces: 24)
        Diag.shared.row("fling", id: cap.id, note: String(format: "v=%.0f,%.0f pieces=%d", v.dx, v.dy, pieces.count))
        let spread = cap.frame.width / 24
        for piece in pieces {
            let p = CGPoint(x: piece.x + toTrue.dx, y: cap.frame.maxY + toTrue.dy + 2)
            let vel = CGVector(dx: clamp(v.dx * 0.5, -1300, 1300), dy: clamp(v.dy * 0.5, -400, 500) + 160)
            spawnGrains(area: piece.area, at: p, spreadX: spread, velocity: vel, jitter: CGVector(dx: 160, dy: 120), source: cap.id)
        }
    }

    // MARK: Grains (falling "sand" snow)

    private final class Grain {
        let node: SKSpriteNode
        var vel: CGVector
        let area: CGFloat
        let source: Int
        var age: CGFloat = 0
        init(node: SKSpriteNode, vel: CGVector, area: CGFloat, source: Int) {
            self.node = node; self.vel = vel; self.area = area; self.source = source
        }
    }
    private var grains: [Grain] = []
    private var grainPool: [SKSpriteNode] = []
    static let maxGrains = 600
    /// Snow volume carried by one grain (pt²); grains get heavier (fewer) when the budget is tight.
    static let grainArea: CGFloat = 1.2
    private var grainLimit: Int { powerSaver ? WinterScene.maxGrains / 2 : WinterScene.maxGrains }
    /// Spill not yet turned into grains, per cap and side (keeps tiny per-frame spills continuous).
    private var spillBank: [Int: (left: CGFloat, right: CGFloat, l0: CGFloat, l1: CGFloat, r0: CGFloat, r1: CGFloat)] = [:]
    /// Per-window: offset from the simulated to the real frame and path velocity (live windows).
    private var capToTrue: [Int: CGVector] = [:]
    private var capVelocity: [Int: CGVector] = [:]
    /// Harness / diag: grains in flight and their total area, area deposited by grains.
    var activeGrainCount: Int { grains.count }
    var grainAreaInFlight: CGFloat { grains.reduce(0) { $0 + ($1.source >= 0 ? $1.area : 0) } }
    private(set) var grainDepositedArea: CGFloat = 0
    /// Deposits of window-snow grains by destination (window id, or -1 for the ground / Dock) —
    /// harness accounting (Dock-end grains come from the ground and are not counted).
    private(set) var grainDeposits: [Int: CGFloat] = [:]
    /// Spill waiting in the per-cap banks (not yet a grain).
    var spillBankArea: CGFloat { spillBank.values.reduce(0) { $0 + $1.left + $1.right } }
    private(set) var grainsSpawned = 0
    private(set) var grainsSpawnedByWindows = 0

    /// Turns `area` pt² of snow into falling grains around `p` (budgeted; when the budget is used
    /// up the grains get heavier, and as a last resort the snow lands directly below).
    private func spawnGrains(area: CGFloat, at p: CGPoint, spreadX: CGFloat, velocity v: CGVector, jitter: CGVector, source: Int) {
        guard area > 0, p.x.isFinite, p.y.isFinite else { return }
        let free = grainLimit - grains.count
        guard free > 0, isRendering else { depositBelow(x: p.x, y: p.y, area: area, source: source); return }
        let want = max(1, Int(area / WinterScene.grainArea))
        let count = min(want, max(1, free / 4), free)
        let each = area / CGFloat(count)
        for _ in 0..<count {
            let n = grainPool.popLast() ?? {
                let s = SKSpriteNode(texture: Textures.snowflake)
                s.zPosition = zFX
                return s
            }()
            let sz = CGFloat.random(in: 1.2...2.4)
            n.size = CGSize(width: sz, height: sz)
            n.alpha = CGFloat.random(in: 0.7...1)
            n.position = CGPoint(x: p.x + CGFloat.random(in: -0.5...0.5) * spreadX, y: p.y + CGFloat.random(in: -2...0.5))
            if n.parent == nil { addChild(n) }
            n.isHidden = false
            let g = Grain(node: n, vel: CGVector(dx: v.dx + CGFloat.random(in: -0.5...0.5) * jitter.dx,
                                                 dy: v.dy + CGFloat.random(in: -0.5...0.5) * jitter.dy), area: each, source: source)
            grains.append(g)
        }
        grainsSpawned += count
        if source >= 0 { grainsSpawnedByWindows += count }
    }

    /// Lands snow straight down from (x, y) without a visible grain (budget exhausted / not rendering).
    private func depositBelow(x: CGFloat, y: CGFloat, area: CGFloat, source: Int) {
        guard let ground else { return }
        var landY = ground.surface(at: x)
        var landCap: WindowCap?
        for cap in caps.values where cap.id != source {
            if let s = cap.surface(at: x), s <= y, s > landY { landY = s; landCap = cap }
        }
        if let c = landCap { c.deposit(centerX: x, area: area) } else { ground.deposit(centerX: x, area: area) }
        grainDepositedArea += area
        if source >= 0 { grainDeposits[landCap?.id ?? -1, default: 0] += area }
    }

    /// Steps the granular caps and turns their spills (and the Dock ends') into grain streams.
    private func updateGranular(_ dt: CGFloat) {
        for cap in caps.values {
            cap.step(dt: dt)
            cap.lateral = 0                      // set again next frame by a live drag
            let spills = cap.takeSpill()
            guard !spills.isEmpty else { continue }
            var bank = spillBank[cap.id] ?? (0, 0, .infinity, -.infinity, .infinity, -.infinity)
            let mid = cap.frame.midX
            for s in spills {
                if s.x < mid { bank.left += s.area; bank.l0 = min(bank.l0, s.x); bank.l1 = max(bank.l1, s.x) }
                else { bank.right += s.area; bank.r0 = min(bank.r0, s.x); bank.r1 = max(bank.r1, s.x) }
            }
            let off = capToTrue[cap.id] ?? .zero
            let v = capVelocity[cap.id] ?? .zero
            for side in [-1, 1] {
                let amount = side < 0 ? bank.left : bank.right
                guard amount >= WinterScene.grainArea else { continue }
                // A sand stream: grains spread over the span the snow left from (an edge pour is
                // ~2pt wide, a narrowing drops a curtain), starting at the top edge, tiny outward drift.
                let x0 = side < 0 ? bank.l0 : bank.r0, x1 = side < 0 ? bank.l1 : bank.r1
                let p = CGPoint(x: (x0 + x1) / 2 + off.dx + CGFloat(side) * 0.8, y: cap.frame.maxY + off.dy + 1)
                let vel = CGVector(dx: v.dx * 0.8 + CGFloat(side) * 8, dy: v.dy * 0.5 - 30)
                spawnGrains(area: amount, at: p, spreadX: max(2, x1 - x0 + 2), velocity: vel, jitter: CGVector(dx: 12, dy: 60), source: cap.id)
                if side < 0 { bank.left = 0; bank.l0 = .infinity; bank.l1 = -.infinity }
                else { bank.right = 0; bank.r0 = .infinity; bank.r1 = -.infinity }
            }
            spillBank[cap.id] = bank
        }
        if let ground {
            for s in ground.takeDockSpill() {
                let leftEnd = s.x < (dockBand.map { ($0.minX + $0.maxX) / 2 } ?? 0)
                spawnGrains(area: s.area, at: CGPoint(x: s.x, y: s.y + 1), spreadX: 1, velocity: CGVector(dx: leftEnd ? -12 : 12, dy: -5),
                            jitter: CGVector(dx: 10, dy: 6), source: -1)
            }
        }
    }

    /// Grains fall (gravity, a little air drag), land on the highest snow surface below them and
    /// add their snow there.
    private func updateGrains(_ dt: CGFloat) {
        guard !grains.isEmpty, let ground else { return }
        var keep: [Grain] = []
        keep.reserveCapacity(grains.count)
        for g in grains {
            g.age += dt
            let oldY = g.node.position.y
            g.vel.dy -= gravity * 0.75 * dt
            g.vel.dx *= exp(-1.2 * dt)
            var p = g.node.position
            p.x += g.vel.dx * dt
            p.y += g.vel.dy * dt
            guard p.x.isFinite, p.y.isFinite, g.age < 8 else { recycle(g); continue }
            if p.x < 1 || p.x > size.width - 1 { p.x = clamp(p.x, 1, size.width - 1); g.vel.dx = -g.vel.dx * 0.2 }
            var landY = ground.surface(at: p.x)
            var landCap: WindowCap?
            for cap in caps.values where !(cap.id == g.source && g.age < 0.25) {
                if let s = cap.surface(at: p.x), s <= oldY + 0.5, s > landY, cap.isVisible(atX: p.x) { landY = s; landCap = cap }
            }
            if p.y <= landY {
                if let c = landCap { c.deposit(centerX: p.x, area: g.area) } else { ground.deposit(centerX: p.x, area: g.area) }
                grainDepositedArea += g.area
                if g.source >= 0 { grainDeposits[landCap?.id ?? -1, default: 0] += g.area }
                recycle(g)
                continue
            }
            g.node.position = p
            keep.append(g)
        }
        grains = keep
    }

    private func recycle(_ g: Grain) {
        g.node.isHidden = true
        if grainPool.count < WinterScene.maxGrains { grainPool.append(g.node) } else { g.node.removeFromParent() }
    }

    /// Applies a drawn frame: cap transform (no texture re-render), riders, wobble / throw-off.
    private func applyLive(index i: Int, frame f: CGRect, previous old: CGRect, velocity v: CGVector, accel a: CGVector,
                           dt: CGFloat, teleport: Bool, shaking: Bool = true) {
        let id = appWindows[i].id
        appWindows[i].frame = f
        trackedFrames[id] = f
        let d = CGPoint(x: f.minX - old.minX, y: f.maxY - old.maxY)
        if !teleport && shaking && hypot(a.dx, a.dy) > WinterScene.riderFallAccel {
            // Thrown off: hop up and fly opposite to the jolt (balls), gifts inherit motion.
            for b in balls where b.below == nil && !b.held && b.restingOn == id {
                b.vy = 320
                b.vx = clamp(-a.dx * 0.004, -420, 420)
                b.tiltVel += a.dx > 0 ? -2 : 2
            }
            detachRiders(from: id, inherit: CGVector(dx: v.dx * 0.5, dy: max(0, v.dy) * 0.5))
        } else {
            moveRiders(on: id, by: d)
            if !teleport { wobbleRiders(on: id, accel: a) }
        }
        caps[id]?.update(window: appWindows[i])     // position only (same width => no redraw)
    }

    private func moveRiders(on id: Int, by d: CGPoint) {
        guard d.x.isFinite, d.y.isFinite, d.x != 0 || d.y != 0 else { return }
        for b in balls where b.below == nil && b.restingOn == id {
            // A held ball stays under the cursor horizontally but keeps sitting on the (drawn,
            // smoothed) window top, so it doesn't sink / float while the window moves.
            b.position = CGPoint(x: b.position.x + (b.held ? 0 : d.x), y: b.position.y + d.y)
            layout(b)
        }
        for g in gifts where !g.held && g.restingOn == id {
            g.position = CGPoint(x: g.position.x + d.x, y: g.position.y + d.y)
        }
    }

    private func wobbleRiders(on id: Int, accel a: CGVector) {
        for b in balls where b.below == nil && !b.held && b.restingOn == id {
            b.tiltVel = clamp(b.tiltVel + clamp(-a.dx * 0.000012 * 0.5, -0.4, 0.4), -2.5, 2.5)
        }
    }

    static let shedAccel: CGFloat = 8_000          // pt/s² of the sample path while braking (×2 needed: flick / reversal)
    static let shedCooldown: CGFloat = 0.34        // ≤ ~3 bursts per second per window
    static let shedStopSpeed: CGFloat = 600         // pt/s of the sample path when the drag ends

    /// 1–3 soft round clumps (7–12pt, shaded like snowballs) from the strip; no trickle, no powder,
    /// and the strip is not visibly thinned.
    private func shedSoftClumps(_ cap: WindowCap, accel a: CGVector, velocity v: CGVector) {
        guard isRendering, !cap.isEmpty else { return }
        let count = hypot(a.dx, a.dy) > WinterScene.shedAccel * 3 ? 3 : (hypot(a.dx, a.dy) > WinterScene.shedAccel * 1.8 ? 2 : 1)
        for _ in 0..<count where clumps.count < clumpLimit && fxCount < WinterScene.maxFX {
            // From the edge the snow slides off: opposite to the acceleration.
            let fromRight = a.dx < 0
            let x = fromRight ? cap.frame.maxX - CGFloat.random(in: 4...60) : cap.frame.minX + CGFloat.random(in: 4...60)
            let top = cap.surface(at: x) ?? cap.frame.maxY
            let s = CGFloat.random(in: 7...12)
            let n = SKSpriteNode(texture: Textures.ball, size: CGSize(width: s, height: s))
            n.position = CGPoint(x: x, y: top + s * 0.3)
            n.zPosition = zFX
            addChild(n)
            let kick = CGVector(dx: clamp(-a.dx * 0.004, -140, 140) + CGFloat.random(in: -25...25), dy: CGFloat.random(in: 50...130))
            let c = Clump(node: n, vel: kick, area: s * s * 0.6, source: cap.id)
            c.quiet = true
            clumps.append(c)
            liveShedCount += 1
        }
    }

    /// Riders resting on a window hide where a front window covers them (like the reference).
    private func updateRiderOcclusion() {
        guard !appWindows.isEmpty else { return }
        for b in balls where b.below == nil {
            var hidden = false
            if let id = b.restingOn, capWorlds[id] == nil, let w = appWindows.first(where: { $0.id == id }) {
                let base = CGPoint(x: b.position.x, y: b.position.y)
                hidden = appWindows.contains { $0.order < w.order && $0.frame.contains(base) }
            }
            for x in chain(b) where x.isHidden != hidden { x.isHidden = hidden }
        }
        for g in gifts {
            var hidden = false
            if let id = g.restingOn, capWorlds[id] == nil, let w = appWindows.first(where: { $0.id == id }) {
                hidden = appWindows.contains { $0.order < w.order && $0.frame.contains(g.position) }
            }
            if g.isHidden != hidden { g.isHidden = hidden }
        }
    }

    /// Detaches the cap: chunks of its texture slide (opposite to the motion), tilt, break up and
    /// fall; icicles drop; lights on that window drop and fade; riders fall.
    private func slideOff(windowID id: Int, direction: CGVector, reason: String) {
        slideOffCount += 1
        unsettled.insert(id)
        lights.suppressed = unsettled
        detachRiders(from: id)
        guard let cap = caps[id] else { return }
        rememberedHeight[id] = cap.averageHeight
        Diag.shared.row("slideOff", id: id, rect: cap.frame, note: "\(reason) avg=\(Int(cap.averageHeight))")
        caps[id] = nil
        let pieces = isRendering && !cap.isEmpty ? cap.chunkTextures(count: max(4, min(8, Int(cap.frame.width / 70)))) : []
        let icicles = cap.icicleDrops()
        cap.node.removeAllActions()
        cap.node.removeFromParent()
        guard isRendering else { return }
        let dir: CGFloat = direction.dx > 0.5 ? -1 : (direction.dx < -0.5 ? 1 : (Bool.random() ? 1 : -1))
        for (k, p) in pieces.enumerated() where p.center.x.isFinite && p.center.y.isFinite {
            guard chunks.count < WinterScene.maxChunks else { break }
            let n = SKSpriteNode(texture: p.texture, size: p.size)
            n.position = p.center
            n.zPosition = zCaps
            addChild(n)
            let spread = CGFloat(k) / CGFloat(max(pieces.count - 1, 1)) - 0.5
            let c = Chunk(node: n, vel: CGVector(dx: dir * CGFloat.random(in: 50...130) + spread * 60,
                                                 dy: CGFloat.random(in: 10...70)),
                          spin: dir * CGFloat.random(in: 0.15...0.5), area: p.area, source: id,
                          breakAt: CGFloat.random(in: 0.22...0.4))
            chunks.append(c)
        }
        for ic in icicles where fxCount < WinterScene.maxFX {
            fxCount += 1
            let n = SKSpriteNode(texture: WinterScene.icicleTexture, size: CGSize(width: 4, height: clamp(ic.length, 3, 24)))
            n.position = ic.pos
            n.zPosition = zFX
            addChild(n)
            let fall = SKAction.moveBy(x: dir * 20, y: -CGFloat.random(in: 140...220), duration: 0.8)
            fall.timingMode = .easeIn
            n.run(.sequence([.group([fall, .rotate(byAngle: dir * CGFloat.random(in: 0.5...2), duration: 0.8),
                                     .sequence([.wait(forDuration: 0.45), .fadeOut(withDuration: 0.35)])]),
                             .run { [weak self] in self?.fxCount -= 1 }, .removeFromParent()]))
        }
    }

    /// Regrows caps for windows that have been still for `settleDelay` (also creates caps for new
    /// windows and restores caps after Snow on Windows is turned back on).
    private func settleWindows() {
        var changed = false
        var newlyDecorated = false
        for w in appWindows where !decorated.contains(w.id) && elapsed - (stableSince[w.id] ?? elapsed) >= WinterScene.settleInDelay {
            decorated.insert(w.id)
            newlyDecorated = true
        }
        for id in Array(unsettled) where elapsed - (lastBoundsChange[id] ?? -1000) >= WinterScene.settleDelay {
            unsettled.remove(id)
            changed = true
        }
        if windowSnowEnabled {
            for w in appWindows where caps[w.id] == nil && !unsettled.contains(w.id) && decorated.contains(w.id) {
                let cap: WindowCap
                if let h = rememberedHeight.removeValue(forKey: w.id) {
                    cap = WindowCap(window: w, regrowHeight: max(2.5, h * WinterScene.keepFraction),
                                    regrowDuration: WinterScene.regrowDuration)
                    settleFlakes(over: w.frame)
                    Diag.shared.row("regrow", id: w.id, rect: w.frame, note: "target=\(Int(max(2.5, h * WinterScene.keepFraction)))")
                } else {
                    cap = WindowCap(window: w)
                    Diag.shared.row("stripCreate", id: w.id, rect: w.frame, note: "fresh")
                }
                caps[w.id] = cap
                cap.node.alpha = 0
                cap.node.run(.fadeIn(withDuration: 0.3))
                capLayer.addChild(cap.node)
                changed = true
            }
        }
        if changed {
            refreshOccluders()
            lights.suppressed = unsettled
        }
        if newlyDecorated {
            syncLights()
            if lightEditMode { refreshAnchorDots() }
        }
    }

    /// A few flakes drifting down onto a regrowing cap.
    private func settleFlakes(over f: CGRect) {
        guard isRendering else { return }
        let n = min(8, WinterScene.maxFX - fxCount)
        guard n > 0 else { return }
        fxCount += n
        for _ in 0..<n {
            let s = SKSpriteNode(texture: Textures.snowflake, size: CGSize(width: 6, height: 6))
            s.position = CGPoint(x: CGFloat.random(in: f.minX...f.maxX), y: f.maxY + CGFloat.random(in: 30...90))
            s.zPosition = zFX
            s.alpha = 0
            addChild(s)
            let fall = SKAction.moveTo(y: f.maxY + 4, duration: Double.random(in: 0.8...1.3))
            fall.timingMode = .easeOut
            s.run(.sequence([.group([fall, .sequence([.fadeAlpha(to: 0.9, duration: 0.2), .wait(forDuration: 0.6),
                                                      .fadeOut(withDuration: 0.4)])]),
                             .run { [weak self] in self?.fxCount -= 1 }, .removeFromParent()]))
        }
    }

    // Slide-off chunks: pieces of the cap texture with our own physics.
    private final class Chunk {
        let node: SKSpriteNode
        var vel: CGVector
        let spin: CGFloat
        let area: CGFloat
        let source: Int
        let breakAt: CGFloat
        var age: CGFloat = 0
        var broken = false
        init(node: SKSpriteNode, vel: CGVector, spin: CGFloat, area: CGFloat, source: Int, breakAt: CGFloat) {
            self.node = node; self.vel = vel; self.spin = spin; self.area = area; self.source = source; self.breakAt = breakAt
        }
    }
    private var chunks: [Chunk] = []
    static let maxChunks = 64

    /// 60fps: a short slide along the old edge (low gravity, growing tilt), then a fall; each chunk
    /// breaks into clumps + powder part way down, the clumps land and add to snow below.
    private func updateChunks(_ dt: CGFloat) {
        guard !chunks.isEmpty else { return }
        var keep: [Chunk] = []
        for c in chunks {
            c.age += dt
            let sliding = c.age < 0.18
            c.vel.dy -= gravity * (sliding ? 0.25 : 1) * dt
            c.vel.dx *= pow(sliding ? 0.6 : 0.9, dt)
            var p = c.node.position
            p.x += c.vel.dx * dt
            p.y += c.vel.dy * dt
            guard p.x.isFinite, p.y.isFinite else { c.node.removeFromParent(); continue }
            c.node.position = p
            // Tip over the edge while sliding (leading side down), then a slow tumble.
            c.node.zRotation += c.spin * dt * (sliding ? 1.5 : 1)
            c.node.zRotation = clamp(c.node.zRotation, -0.6, 0.6)
            if !c.broken && c.age >= c.breakAt {
                c.broken = true
                breakChunk(c)
                continue
            }
            if c.age > 3 || p.y < -60 { c.node.removeFromParent(); continue }
            keep.append(c)
        }
        chunks = keep
    }

    private func breakChunk(_ c: Chunk) {
        let p = c.node.position
        let pieces = max(2, min(4, Int(c.area / 120) + 1))
        for _ in 0..<pieces where clumps.count < clumpLimit && fxCount < WinterScene.maxFX {
            let s = clamp(sqrt(c.area / CGFloat(pieces)) * 0.9, 5, 13)
            let n = SKSpriteNode(texture: Textures.ball, size: CGSize(width: s, height: s))
            n.position = CGPoint(x: p.x + CGFloat.random(in: -c.node.size.width / 3...c.node.size.width / 3), y: p.y)
            n.zPosition = zFX
            addChild(n)
            clumps.append(Clump(node: n, vel: CGVector(dx: c.vel.dx + CGFloat.random(in: -40...40), dy: c.vel.dy),
                                area: c.area * 0.6 / CGFloat(pieces), source: c.source))
            shedStats.clumps += 1
        }
        powder(at: p, count: 4)
        c.node.run(.sequence([.group([.fadeOut(withDuration: 0.15), .scale(to: 0.8, duration: 0.15)]), .removeFromParent()]))
    }

    /// Chunks still falling (harness / diagnostics).
    var activeChunkCount: Int { chunks.count }
    /// The ground snow (read-only use: diagnostics / offscreen harness).
    var groundForHarness: GroundSnow? { ground }
    /// Falling clumps / current snow birth rate / clump budget (diagnostics / offscreen harness).
    var activeClumpCount: Int { clumps.count }
    var snowBirthRate: CGFloat { emitter?.particleBirthRate ?? 0 }
    var currentClumpLimit: Int { clumpLimit }
    /// A ball's position inside its cap window (nil if it is not in one) — harness.
    func capLocalPosition(of n: SKNode) -> CGPoint? {
        guard let p = n.parent, capWorlds.values.contains(where: { $0.root === p }) else { return nil }
        return CGPoint(x: n.position.x + p.position.x, y: n.position.y + p.position.y)
    }

    /// Read-only access to a window's cap (diagnostics / offscreen harness).
    func cap(for id: Int) -> WindowCap? { caps[id] }

    private func refreshOccluders() {
        // A live-dragged window's own strip keeps its occlusion until the drag settles, so its
        // texture is never re-rendered mid-drag (only its transform changes).
        for cap in caps.values where liveTracks[cap.id] == nil {
            // In a cap window WindowServer does the occlusion (the cap is ordered with its window).
            cap.setOccluders(capWorlds[cap.id] != nil ? [] : appWindows.filter { $0.order < cap.order }.map { $0.frame })
        }
    }

    // MARK: Shed snow (clumps, powder, icicles)

    private final class Clump {
        let node: SKSpriteNode
        var vel: CGVector
        let area: CGFloat
        let source: Int
        var age: CGFloat = 0
        var bounced = false
        /// Live-mode clumps: no powder puff on landing.
        var quiet = false
        init(node: SKSpriteNode, vel: CGVector, area: CGFloat, source: Int) {
            self.node = node; self.vel = vel; self.area = area; self.source = source
        }
    }
    private var clumps: [Clump] = []
    static let maxClumps = 120
    /// Clump budget (halved-ish on battery / Low Power Mode).
    private var clumpLimit: Int { powerSaver ? 40 : WinterScene.maxClumps }
    /// Battery / Low Power Mode: half the snowfall, smaller clump budget, slower twinkle.
    var powerSaver = false {
        didSet {
            guard powerSaver != oldValue else { return }
            applySnowRate()
            lights.twinkleEvery = powerSaver ? 6 : 3
        }
    }
    static let idleRenderBudget = 2      // cap texture redraws per frame
    static let movingRenderBudget = 1
    private(set) var shedStats: (clumps: Int, icicles: Int, depositedArea: CGFloat) = (0, 0, 0)

    private static let icicleTexture: SKTexture = Textures.make(width: 10, height: 40) { ctx in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 1, y: 40)); p.addLine(to: CGPoint(x: 9, y: 40)); p.addLine(to: CGPoint(x: 5, y: 0)); p.closeSubpath()
        ctx.addPath(p); ctx.clip()
        let colors = [rgb(0.72, 0.86, 1, 0.4).cgColor, rgb(0.9, 0.96, 1, 0.95).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 40), options: [])
        }
    }

    /// Fine powder puffs (budgeted transient FX).
    private func powder(at p: CGPoint, count: Int) {
        let n = min(count, WinterScene.maxFX - fxCount)
        guard n > 0 else { return }
        fxCount += n
        for _ in 0..<n {
            let f = SKSpriteNode(texture: Textures.snowflake, size: CGSize(width: 5, height: 5))
            f.position = CGPoint(x: p.x + CGFloat.random(in: -6...6), y: p.y + CGFloat.random(in: -3...3))
            f.zPosition = zFX
            f.alpha = 0.8
            addChild(f)
            let drift = SKAction.moveBy(x: CGFloat.random(in: -20...20), y: -CGFloat.random(in: 20...60), duration: 0.6)
            f.run(.sequence([.group([drift, .fadeOut(withDuration: 0.6), .scale(to: 2, duration: 0.6)]),
                             .run { [weak self] in self?.fxCount -= 1 }, .removeFromParent()]))
        }
    }

    /// Falling clumps: gravity, then they land on a lower cap or the ground snow and add to it.
    private func updateClumps(_ dt: CGFloat) {
        guard !clumps.isEmpty, let ground else { return }
        var keep: [Clump] = []
        for c in clumps {
            c.age += dt
            let oldY = c.node.position.y
            c.vel.dy -= gravity * dt
            var p = c.node.position
            p.x += c.vel.dx * dt
            p.y += c.vel.dy * dt
            guard p.x.isFinite, p.y.isFinite, c.age < 6 else { c.node.removeFromParent(); continue }
            // Flung snow hits the screen edge and drops there (stays in play) instead of vanishing.
            if p.x < 2 || p.x > size.width - 2 {
                p.x = clamp(p.x, 2, size.width - 2)
                c.vel.dx = -c.vel.dx * 0.25
            }
            // Highest surface below the clump, ignoring the cap it fell from.
            var landY = ground.surface(at: p.x)
            var landCap: WindowCap?
            for cap in caps.values where cap.id != c.source {
                if let s = cap.surface(at: p.x), s <= oldY + 1, s > landY, cap.isVisible(atX: p.x) { landY = s; landCap = cap }
            }
            if p.y <= landY && !c.bounced && c.vel.dy < -150 {
                c.bounced = true                       // one small bounce before settling
                c.vel.dy = -c.vel.dy * 0.28
                c.vel.dx *= 0.6
                c.node.position = CGPoint(x: p.x, y: landY + 0.5)
                keep.append(c)
                continue
            }
            if p.y <= landY {
                if let cap = landCap { cap.deposit(centerX: p.x, area: c.area) } else { ground.deposit(centerX: p.x, area: c.area) }
                shedStats.depositedArea += c.area
                if !c.quiet { powder(at: CGPoint(x: p.x, y: landY + 2), count: 1) }
                c.node.removeFromParent()
                continue
            }
            c.node.position = p
            keep.append(c)
        }
        clumps = keep
    }

    // MARK: Vanishing windows (minimize / hide / close)

    /// Window id -> (last listed frame, since) while it is treated as gone.
    private var vanished: [Int: (frame: CGRect, since: TimeInterval)] = [:]
    /// Riders parked from a window that went away (the app keeps them with the saved riders and
    /// restores them onto that window when it is listed again).
    var onRidersParked: (([SavedRider]) -> Void)?

    /// A window is being minimized / hidden / closed: its strip, riders and lights disappear now.
    func windowVanished(_ id: Int, reason: String) {
        guard vanished[id] == nil, let w = appWindows.first(where: { $0.id == id }) else { return }
        vanished[id] = (w.frame, liveClock())
        Diag.shared.row("vanish", id: id, rect: w.frame, note: reason)
        setAppWindows(appWindows, poll: false)        // runs the removal path for it right away
    }

    var vanishedWindows: Set<Int> { Set(vanished.keys) }

    private func parkRiders(of id: Int, window w: AppWindow?) {
        var parked: [SavedRider] = []
        for r in balls where r.below == nil && r.restingOn == id && !r.held {
            if let w, w.frame.width > 0, !w.owner.isEmpty {
                let o = r.outfit
                parked.append(SavedRider(owner: w.owner, index: w.ownerIndex, fx: Double((r.position.x - w.frame.minX) / w.frame.width),
                                         radii: chain(r).map { Double($0.radius) },
                                         hat: o.hat.rawValue, face: o.face.rawValue, body: o.body.rawValue, clothes: o.clothes.rawValue,
                                         windowID: id))
            }
            for b in chain(r) {
                b.removeFromParent()
                balls.removeAll { $0 === b }
                if hoverBall === b { clearBallHover() }
            }
        }
        // Gifts on it go quietly onto the snow below (no fall).
        for g in gifts where g.restingOn == id && !g.held {
            g.restingOn = nil
            g.vel = .zero
            if let ground { g.position = CGPoint(x: g.position.x, y: ground.surface(at: g.position.x) + g.hh) }
        }
        if !parked.isEmpty {
            Diag.shared.row("ridersParked", id: id, note: "n=\(parked.count)")
            onRidersParked?(parked)
        }
    }

    private func detachRiders(from id: Int, inherit: CGVector = .zero) {
        for b in balls where b.restingOn == id { b.restingOn = nil }
        for g in gifts where g.restingOn == id {
            g.restingOn = nil
            if inherit.dx.isFinite, inherit.dy.isFinite {
                g.vel = CGVector(dx: clamp(inherit.dx, -1200, 1200), dy: clamp(inherit.dy, 0, 600))
            }
        }
    }

    /// A little burst of falling snow and clumps from a window's top edge.
    private func snowBurst(x0: CGFloat, x1: CGFloat, top: CGFloat, amount: CGFloat) {
        // Only while frames are being rendered (otherwise the removal actions never run and the
        // flakes pile up), and never beyond the global FX budget.
        guard isRendering, x0.isFinite, x1.isFinite, top.isFinite, amount.isFinite else { return }
        let want = min(36, Int(max(0, x1 - x0) / 25 * min(1, max(0, amount) / 6)) + 4)
        let n = min(want, WinterScene.maxFX - fxCount)
        guard n > 0 else { return }
        fxCount += n
        for i in 0..<n {
            let clump = i % 5 == 0
            let s = CGFloat.random(in: clump ? 9...14 : 4...8)
            let flake = SKSpriteNode(texture: clump ? Textures.ball : Textures.snowflake, size: CGSize(width: s, height: s))
            flake.position = CGPoint(x: CGFloat.random(in: x0...max(x0, x1)), y: top + CGFloat.random(in: 0...8))
            flake.zPosition = zFX
            addChild(flake)
            let fall = SKAction.moveBy(x: CGFloat.random(in: -30...30), y: -CGFloat.random(in: 120...280), duration: 0.9)
            fall.timingMode = .easeIn
            flake.run(.sequence([.group([fall, .sequence([.wait(forDuration: 0.45), .fadeOut(withDuration: 0.45)])]),
                                 .run { [weak self] in self?.fxCount -= 1 },
                                 .removeFromParent()]))
        }
    }

    private struct Support {
        var y: CGFloat
        var cap: WindowCap?
    }

    /// Highest walkable surface at x that is not above `y`: ground/Dock snow or a visible window cap.
    /// `riding`: the window an object already rests on — its cap keeps supporting it even while a
    /// front window covers that spot (the rider is hidden, not dropped, like the reference).
    private func support(at x: CGFloat, below y: CGFloat, riding: Int? = nil) -> Support {
        var best = Support(y: ground?.surface(at: x) ?? 0, cap: nil)
        for cap in caps.values {
            guard let s = cap.surface(at: x), s <= y + 4, s > best.y, cap.id == riding || cap.isVisible(atX: x) else { continue }
            best = Support(y: s, cap: cap)
        }
        return best
    }

    func outfitChanged(_ root: Snowball) { refreshDecor(root) }

    private func applySnowRate() {
        emitter?.particleBirthRate = snowPaused ? 0 : intensity.birthRate * max(size.width, 1) / 1280 * (powerSaver ? 0.5 : 1)
    }

    private func syncSanta() {
        if santaEnabled && isMainScreen && ground != nil {
            if santa == nil {
                let s = Santa()
                s.zPosition = zSanta
                s.scheduleNextPass(in: 3)
                addChild(s)
                santa = s
            }
        } else if let s = santa {
            // Switched off: release any drag and fade the sleigh out gracefully; no new passes.
            if let d = drag, case .santa = d { drag = nil }
            santa = nil
            s.removeAllActions()
            if isRendering && !s.isHidden {
                s.run(.sequence([.fadeOut(withDuration: 0.5), .removeFromParent()]))
            } else {
                s.removeFromParent()
            }
        }
    }

    private func makeEmitter() -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = Textures.snowflake
        e.position = CGPoint(x: size.width / 2, y: size.height + 12)
        e.particlePositionRange = CGVector(dx: size.width * 1.3, dy: 0)
        e.emissionAngle = -.pi / 2
        e.emissionAngleRange = 0.3
        e.particleSpeed = 55
        e.particleSpeedRange = 40
        e.yAcceleration = -6
        e.particleLifetime = (size.height + 40) / 38
        e.particleAlpha = 0.75
        e.particleAlphaRange = 0.3
        e.particleScale = 0.08              // tiny, soft, subtle flakes
        e.particleScaleRange = 0.04
        e.particleColor = .white
        e.particleColorBlendFactor = 0
        e.particleBlendMode = .alpha
        e.zPosition = zSnow
        return e
    }

    // MARK: Stack helpers

    private func root(of b: Snowball) -> Snowball {
        var r = b
        while let d = r.below { r = d }
        return r
    }

    private func chain(_ root: Snowball) -> [Snowball] {
        var out = [root]
        var c = root
        while let a = c.above {
            out.append(a)
            c = a
        }
        return out
    }

    private func restY(_ b: Snowball, _ x: CGFloat) -> CGFloat {
        support(at: x, below: b.position.y - b.radius * 0.9 + 1).y + b.radius * 0.9
    }

    private func refreshDecor(_ root: Snowball) {
        let ch = chain(root)
        let n = ch.count
        let o = root.outfit
        for (i, b) in ch.enumerated() {
            var prims: [Prim] = []
            let isHead = n >= 2 && i == n - 1
            let isBody = (n == 2 && i == 0) || (n == 3 && i == 1)
            if isHead {
                prims += OutfitArt.face(o.face) + OutfitArt.hat(o.hat) + OutfitArt.neckClothes(o.clothes)
            }
            if isBody {
                prims += OutfitArt.body(o.body) + OutfitArt.bodyClothes(o.clothes)
                if n == 3 { prims += OutfitArt.buttons() }
            }
            b.setDecor(prims, key: "\(n)-\(i)-\(o.key)", showShadow: i == 0)
        }
    }

    // MARK: Hit testing

    private func ball(at p: CGPoint) -> Snowball? {
        // Tight to the visible ball (riders sit right on title bars: no padding stealing clicks).
        balls.filter { hypot(p.x - $0.position.x, p.y - $0.position.y) <= $0.radius && !riderCovered(p, on: root(of: $0).restingOn) }
            .max { $0.zPosition < $1.zPosition }
    }

    private func gift(at p: CGPoint, includeDelete: Bool = false) -> Gift? {
        gifts.reversed().first { $0.isHit(p, includeDelete: includeDelete) && !riderCovered(p, on: $0.restingOn) }
    }

    /// Whether the overlay should capture the mouse at scene point `p`.
    /// (Drag capture is decided by the caller, which also checks that a button is down.)
    func wantsMouse(at p: CGPoint) -> Bool { mouseTarget(at: p) != nil }

    /// What the overlay would handle at `p` (nil = click-through), for capture and the diag log.
    func mouseTarget(at p: CGPoint) -> String? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        // Light Edit mode: only the anchor dots and user strands capture the mouse.
        if lightEditMode && (anchorHit(p) != nil || lights.userLink(near: p, tolerance: WinterScene.strandHitTolerance) != nil) {
            return "lightEdit"
        }
        if let s = santa, s.isHit(p) { return "santa" }
        if let pl = plow, pl.isHit(p), !plowUnderDock(pl) { return "plow" }
        if let g = hoverGift, g.deleteHit(p) { return "giftDelete" }
        if ballDeleteHit(p) { return "ballDelete" }
        if let g = gift(at: p) { return "gift" + (g.restingOn.map { " on=\($0)" } ?? "") }
        if let b = ball(at: p) {
            return String(format: "ball r=%.1f", b.radius) + (root(of: b).restingOn.map { " on=\($0)" } ?? "")
        }
        return (ground?.isSnow(at: p) ?? false) ? "groundSnow" : nil
    }

    func updateHover(_ p: CGPoint?) {
        var g: Gift?
        if let p, drag == nil { g = gift(at: p, includeDelete: true) }
        if g !== hoverGift {
            hoverGift?.setDeleteVisible(false)
            if let g { g.setDeleteVisible(true, onRight: nearTrafficLights(x: g.position.x - g.hw, restingOn: g.restingOn)) }
            hoverGift = g
        }
        // Snowballs / snowmen: a ✕ appears after hovering 0.3s (kept while over the ✕ itself).
        guard let p, drag == nil, pendingBall == nil, g == nil else { if p == nil || drag != nil { clearBallHover() }; return }
        if ballDeleteHit(p) { return }
        if let b = ball(at: p) {
            if b !== hoverBall { hoverBall = b; hoverBallSince = elapsed; ballDeleteButton.isHidden = true }
        } else {
            clearBallHover()
        }
    }

    // MARK: Deleting snowballs / snowmen

    static let ballDeleteDelay: CGFloat = 0.3
    private weak var hoverBall: Snowball?
    private var hoverBallSince: CGFloat = 0
    private lazy var ballDeleteButton: SKNode = {
        let n = SKNode()
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
        n.addChild(circle)
        n.addChild(x)
        n.isHidden = true
        return n
    }()

    private func clearBallHover() {
        hoverBall = nil
        ballDeleteButton.isHidden = true
    }

    /// Per frame: show the ✕ at the top-left of the hovered stack's topmost ball after the delay.
    private func updateBallDeleteButton() {
        guard let b = hoverBall, b.parent != nil else { if !ballDeleteButton.isHidden { clearBallHover() }; return }
        guard elapsed - hoverBallSince >= WinterScene.ballDeleteDelay else { return }
        let top = chain(root(of: b)).last ?? b
        // Never over a window's traffic-light buttons: near the window's left edge, top-right.
        let side: CGFloat = nearTrafficLights(x: top.position.x - top.radius, restingOn: root(of: b).restingOn) ? 1 : -1
        ballDeleteButton.position = CGPoint(x: top.position.x + side * top.radius * 0.72, y: top.position.y + top.radius * 0.72)
        ballDeleteButton.isHidden = false
    }

    /// A ✕ at the left of something whose left edge is at `x` would cover the traffic-light buttons
    /// of the window it sits on (within 80pt of that window's left edge).
    private func nearTrafficLights(x: CGFloat, restingOn id: Int?) -> Bool {
        guard let id, let w = appWindows.first(where: { $0.id == id }) else { return false }
        return x - w.frame.minX < WinterScene.trafficLightZone
    }
    static let trafficLightZone: CGFloat = 80

    private func ballDeleteHit(_ p: CGPoint) -> Bool {
        !ballDeleteButton.isHidden && hypot(p.x - ballDeleteButton.position.x, p.y - ballDeleteButton.position.y) <= 10
    }

    /// Click on the ✕: deletes the hovered ball (and the balls above it; on a bottom ball, the
    /// whole snowman). Returns true if it handled the click.
    @discardableResult
    func ballDeleteTap(at p: CGPoint) -> Bool {
        guard ballDeleteHit(p), let b = hoverBall else { return false }
        deleteBalls(from: b)
        return true
    }

    /// Removes `b` and every ball stacked above it (a bottom ball => the whole snowman), with a
    /// poof; the snow goes back into the ground.
    func deleteBalls(from b: Snowball) {
        guard b.parent != nil else { return }
        var victims: [Snowball] = []
        var c: Snowball? = b
        while let x = c { victims.append(x); c = x.above }
        let below = b.below
        below?.above = nil
        b.below = nil
        for v in victims {
            powder(at: v.position, count: 5)
            ground?.deposit(centerX: v.position.x, area: .pi * v.radius * v.radius * 0.5)
            if let d = drag, case .ball(let db) = d, db === v { drag = nil }
            if pendingBall === v { pendingBall = nil }
            v.removeFromParent()
        }
        balls.removeAll { x in victims.contains { $0 === x } }
        if let below { refreshDecor(root(of: below)) }
        clearBallHover()
        CustomizePanel.shared.validate()
    }

    /// Menu "Clear Snowballs & Snowmen": removes every ball (gifts stay).
    func clearBalls() {
        for b in balls { b.removeFromParent() }
        balls.removeAll()
        if let d = drag, case .ball = d { drag = nil }
        pendingBall = nil
        clearBallHover()
        CustomizePanel.shared.validate()
    }

    /// Right-click on a ball or snowman: a small "삭제" menu.
    override func rightMouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        guard let b = ball(at: p), let view else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "삭제", action: #selector(contextDeleteBall(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = b
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func contextDeleteBall(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? Snowball else { return }
        deleteBalls(from: b)
    }

    // MARK: Snowmen riding windows (default snowman + persistence)

    struct SavedRider: Codable, Equatable {
        var owner: String
        var index: Int
        var fx: Double
        var radii: [Double]
        var hat: Int, face: Int, body: Int, clothes: Int
        /// This session only: the exact window it rode (minimized / hidden / other Space). Restored
        /// onto that window when it comes back; cleared on load (window ids change per launch).
        var windowID: Int?
    }

    /// Set by the app when nothing was saved: place one small finished snowman after settle-in.
    var wantsDefaultSnowman = false
    static let defaultSnowmanRadii: [CGFloat] = [11, 8, 6]          // ≈ 40pt tall

    /// Snowman / ball stacks currently resting on window caps, keyed by owner app + window rank.
    func riderSnapshot() -> [SavedRider] {
        balls.filter { $0.below == nil && $0.restingOn != nil }.compactMap { r in
            guard let id = r.restingOn, let w = appWindows.first(where: { $0.id == id }), !w.owner.isEmpty,
                  w.frame.width > 0 else { return nil }
            let o = r.outfit
            return SavedRider(owner: w.owner, index: w.ownerIndex, fx: Double((r.position.x - w.frame.minX) / w.frame.width),
                              radii: chain(r).map { Double($0.radius) },
                              hat: o.hat.rawValue, face: o.face.rawValue, body: o.body.rawValue, clothes: o.clothes.rawValue)
        }
    }

    /// Places saved riders whose window resolves to exactly one decorated window; returns the rest.
    func restoreRiders(_ saved: [SavedRider]) -> [SavedRider] {
        var rest: [SavedRider] = []
        for r in saved {
            let m = r.windowID.map { wid in decoratedWindows.filter { $0.id == wid } }
                ?? decoratedWindows.filter { $0.owner == r.owner && $0.ownerIndex == r.index }
            guard m.count == 1, r.fx.isFinite, !r.radii.isEmpty, balls.count + r.radii.count <= maxBalls else { rest.append(r); continue }
            var o = Outfit()
            o.hat = HatStyle(rawValue: r.hat) ?? .none
            o.face = FaceStyle(rawValue: r.face) ?? .classic
            o.body = BodyStyle(rawValue: r.body) ?? .sticks
            o.clothes = ClothesStyle(rawValue: r.clothes) ?? .none
            let made = placeSnowman(onWindow: m[0], fx: CGFloat(r.fx), radii: r.radii.map { clamp(CGFloat($0), 4, Snowball.maxRadius) }, outfit: o)
            for b in made { b.alpha = 0; b.run(.fadeIn(withDuration: RevealGate.fadeDuration)) }   // returns gently
        }
        return rest
    }

    /// Drops a snowman onto a window's top edge (it lands on the snow strip and rides the window).
    @discardableResult
    func placeSnowman(onWindow w: AppWindow, fx: CGFloat, radii: [CGFloat], outfit: Outfit) -> [Snowball] {
        let x = clamp(w.frame.minX + clamp(fx, 0.05, 0.95) * w.frame.width, 10, size.width - 10)
        let made = placeSnowman(x: x, radii: radii)
        guard let root = made.first else { return made }
        root.position.y = min(size.height - 60, w.frame.maxY + (radii.first ?? 8) + 6)
        root.restingOn = w.id
        root.outfit = outfit
        refreshDecor(root)
        layout(root)
        return made
    }

    private func placeDefaultSnowmanIfNeeded() {
        guard wantsDefaultSnowman, elapsed > WinterScene.settleInDelay + 0.3, ground != nil else { return }
        wantsDefaultSnowman = false
        var o = Outfit()
        o.hat = .santa
        o.face = .classic
        o.clothes = .redScarf
        if let w = decoratedWindows.sorted(by: { $0.order < $1.order }).first(where: { $0.frame.width >= 400 && $0.frame.height >= 250
                && $0.frame.maxY < size.height - 50 && caps[$0.id] != nil }) {
            placeSnowman(onWindow: w, fx: 0.72, radii: WinterScene.defaultSnowmanRadii, outfit: o)
        } else {
            let x = dockBand.map { $0.minX + ($0.maxX - $0.minX) * 0.15 } ?? size.width * 0.2
            let made = placeSnowman(x: x, radii: WinterScene.defaultSnowmanRadii)
            if let root = made.first { root.outfit = o; refreshDecor(root) }
        }
    }

    /// Builds a ball / snowman directly (offscreen harness).
    @discardableResult
    func placeSnowman(x: CGFloat, radii: [CGFloat]) -> [Snowball] {
        guard let ground, !radii.isEmpty else { return [] }
        var made: [Snowball] = []
        for r in radii {
            let b = Snowball(radius: r)
            b.zPosition = 10
            if let view { b.rasterize(view: view) }
            if let below = made.last {
                below.above = b
                b.below = below
                b.position = CGPoint(x: x, y: below.position.y + below.radius * 0.8 + r * 0.8)
            } else {
                b.position = CGPoint(x: x, y: ground.surface(at: x) + r * 0.9)
            }
            addChild(b)
            balls.append(b)
            made.append(b)
        }
        if let first = made.first { refreshDecor(first) }
        return made
    }

    /// Drops any drag / pending press (used when a capture got stuck without a mouse button).
    func cancelCapture() {
        cancelLinkDrag()
        pendingBall = nil
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .ball(let b):
            b.held = false
            b.vy = 0
        case .santa(let s):
            s.endHold(click: false)
        case .gift(let g):
            g.held = false
            g.zPosition = zGift
            g.vel = .zero
        case .plow(let pl):
            pl.held = false
            pl.vy = 0
            pl.airborne = true
        }
    }

    struct SafetyMetrics {
        var nodes = 0
        var additiveArea: CGFloat = 0
        var additiveMaxDimension: CGFloat = 0
        var repaired = 0
    }

    /// Hard invariants: removes nodes with NaN/inf geometry, clamps scales and sprite sizes,
    /// and reports totals for the watchdog.
    func enforceInvariants() -> SafetyMetrics {
        var m = SafetyMetrics()
        let maxDim = max(size.width, size.height, 1) * 1.5
        let maxAdd: CGFloat = 128
        let maxScale: CGFloat = 8
        var broken: [SKNode] = []
        // This scene and the cap worlds it fills (nodes living in cap windows are ours too).
        let roots: [SKNode] = [self] + capWorlds.values.map { $0.root }
        for root in roots { root.enumerateChildNodes(withName: "//*") { n, _ in
            m.nodes += 1
            if !n.position.x.isFinite || !n.position.y.isFinite || !n.xScale.isFinite || !n.yScale.isFinite
                || !n.zRotation.isFinite || !n.alpha.isFinite {
                broken.append(n)
                return
            }
            if abs(n.xScale) > maxScale { n.xScale = n.xScale < 0 ? -maxScale : maxScale; m.repaired += 1 }
            if abs(n.yScale) > maxScale { n.yScale = n.yScale < 0 ? -maxScale : maxScale; m.repaired += 1 }
            if abs(n.position.x) > 100_000 || abs(n.position.y) > 100_000 { broken.append(n); return }
            guard let s = n as? SKSpriteNode else { return }
            guard s.size.width.isFinite, s.size.height.isFinite else { broken.append(n); return }
            let limit = s.blendMode == .add ? maxAdd : maxDim
            if s.size.width > limit || s.size.height > limit {
                s.size = CGSize(width: min(s.size.width, limit), height: min(s.size.height, limit))
                m.repaired += 1
            }
            if s.blendMode == .add && !s.isHidden {
                let w = s.size.width * abs(s.xScale), h = s.size.height * abs(s.yScale)
                m.additiveArea += w * h
                m.additiveMaxDimension = max(m.additiveMaxDimension, w, h)
            }
        } }
        for n in broken { n.removeFromParent() }
        m.repaired += broken.count
        return m
    }

    // MARK: Light Edit mode (user-linked string lights)

    static let anchorHitRadius: CGFloat = 12
    static let snapRadius: CGFloat = 40
    static let gold = rgb(1, 0.8, 0.25)
    static let strandHitTolerance: CGFloat = 6
    static let editIdleTimeout: TimeInterval = 30

    var lightEditMode = false {
        didSet {
            guard lightEditMode != oldValue else { return }
            if !lightEditMode { cancelLinkDrag() }
            lastEditInteraction = ProcessInfo.processInfo.systemUptime
            refreshAnchorDots()
        }
    }
    var autoLightLinks = true { didSet { if autoLightLinks != oldValue { syncLights() } } }
    var windowGarlands = true { didSet { if windowGarlands != oldValue { syncLights() } } }
    private(set) var userLinks: [UserLink] = []
    var onUserLinksChanged: (() -> Void)?
    /// Called when a link drag ends (added / rejected with a reason / nil = cancelled).
    var onLinkResult: ((LinkResult?) -> Void)?
    private(set) var lastEditInteraction: TimeInterval = 0
    private let anchorLayer = SKNode()
    private(set) var linkDrag: LightAnchor?
    private let linkPreview = SKNode()
    private var previewEnd = CGPoint.zero
    /// Dot the preview snapped to while dragging, and whether linking there would be accepted.
    private(set) var snapTarget: (anchor: LightAnchor, point: CGPoint, result: LinkResult)?

    /// Nearest visible anchor within `snapRadius` of p (excluding the drag source itself).
    private func snapCandidate(near p: CGPoint) -> (LightAnchor, CGPoint)? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        var best: ((LightAnchor, CGPoint), CGFloat)?
        for (a, q) in visibleAnchors() where a != linkDrag {
            let d = hypot(p.x - q.x, p.y - q.y)
            if d <= WinterScene.snapRadius, d < (best?.1 ?? .infinity) { best = ((a, q), d) }
        }
        return best?.0
    }

    /// Windows that currently show at least one anchor dot.
    var eligibleWindowCount: Int { Set(visibleAnchors().map { $0.0.window }).count }

    /// Seconds since the last Light Edit interaction (for the 30s auto-exit).
    func editIdleSeconds(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        now - lastEditInteraction
    }

    private func touchEdit() { lastEditInteraction = ProcessInfo.processInfo.systemUptime }

    private func syncLights() {
        if windowLightsEnabled {
            lights.sync(windows: decoratedWindows, userLinks: userLinks, autoPairs: autoLightLinks, garlands: windowGarlands)
        }
    }

    private func anchorPoint(_ a: LightAnchor) -> CGPoint? {
        guard let w = appWindows.first(where: { $0.id == a.window }) else { return nil }
        let p = StringLights.point(w, a.kind.fx)
        return p.x.isFinite && p.y.isFinite ? p : nil
    }

    /// True if the anchor exists, is on this screen and is not covered by a window in front.
    func anchorVisible(_ a: LightAnchor) -> Bool {
        guard decorated.contains(a.window), let w = appWindows.first(where: { $0.id == a.window }), let p = anchorPoint(a)
        else { return false }
        guard p.x >= 0, p.x <= size.width, p.y >= 0, p.y <= size.height else { return false }
        return !StringLights.covered(CGPoint(x: p.x, y: p.y - 2), by: w, in: appWindows)
    }

    private func visibleAnchors() -> [(LightAnchor, CGPoint)] {
        var out: [(LightAnchor, CGPoint)] = []
        for w in decoratedWindows {
            for k in AnchorKind.allCases {
                let a = LightAnchor(window: w.id, kind: k)
                if anchorVisible(a), let p = anchorPoint(a) { out.append((a, p)) }
            }
        }
        return out
    }

    func anchorHit(_ p: CGPoint) -> (LightAnchor, CGPoint)? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        var best: ((LightAnchor, CGPoint), CGFloat)?
        for (a, q) in visibleAnchors() {
            let d = hypot(p.x - q.x, p.y - q.y)
            if d <= WinterScene.anchorHitRadius, d < (best?.1 ?? .infinity) { best = ((a, q), d) }
        }
        return best?.0
    }

    private static let dotTexture: SKTexture = Textures.make(width: 40, height: 40) { ctx in
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [rgb(1, 0.97, 0.8).cgColor, rgb(1, 0.82, 0.3).cgColor, rgb(0.95, 0.62, 0.1).cgColor] as CFArray
        ctx.addEllipse(in: CGRect(x: 2, y: 2, width: 36, height: 36))
        ctx.clip()
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: 16, y: 24), startRadius: 0, endCenter: CGPoint(x: 20, y: 20),
                                   endRadius: 18, options: [.drawsAfterEndLocation])
        }
        ctx.resetClip()
        ctx.setStrokeColor(rgb(1, 1, 1, 0.9).cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: CGRect(x: 3, y: 3, width: 34, height: 34))
    }

    private func refreshAnchorDots() {
        anchorLayer.removeAllChildren()
        guard lightEditMode else { return }
        for (a, p) in visibleAnchors() {
            let glow = SKSpriteNode(texture: LightTextures.glow, size: CGSize(width: 46, height: 46))
            glow.color = WinterScene.gold
            glow.colorBlendFactor = 1
            glow.blendMode = .add
            glow.position = p
            glow.name = "pulse"
            anchorLayer.addChild(glow)
            let dot = SKSpriteNode(texture: WinterScene.dotTexture, size: CGSize(width: 18, height: 18))   // ~9pt radius
            dot.position = p
            dot.zPosition = 0.1
            dot.name = "dot"
            if a == linkDrag { dot.setScale(1.3) }
            anchorLayer.addChild(dot)
        }
        pulseAnchorDots()
    }

    /// Gentle pulse of the anchor glows (cheap: scales existing nodes).
    private func pulseAnchorDots() {
        let s = 1 + 0.22 * sin(elapsed * 5)
        for n in anchorLayer.children where n.name == "pulse" { n.setScale(s); n.alpha = 0.75 + 0.25 * s - 0.25 }
    }

    /// Light Edit mouse-down: start a link from an anchor, or delete a user strand.
    @discardableResult
    func editMouseDown(at p: CGPoint) -> Bool {
        guard lightEditMode, p.x.isFinite, p.y.isFinite else { return false }
        touchEdit()
        if let (a, _) = anchorHit(p) {
            linkDrag = a
            previewEnd = p
            if linkPreview.parent == nil {
                linkPreview.zPosition = zLights + 0.6
                addChild(linkPreview)
            }
            updateLinkPreview()
            refreshAnchorDots()
            return true
        }
        if let link = lights.userLink(near: p, tolerance: WinterScene.strandHitTolerance) {
            removeUserLink(link)
            return true
        }
        return false
    }

    func editMouseDragged(to p: CGPoint) {
        guard let src = linkDrag, p.x.isFinite, p.y.isFinite else { return }
        touchEdit()
        let cursor = CGPoint(x: clamp(p.x, 0, size.width), y: clamp(p.y, 0, size.height))
        if let (a, q) = snapCandidate(near: cursor) {
            let r = LightLinkStore.validate(UserLink(a: src, b: a), existing: userLinks, windows: decoratedWindows,
                                            visible: { self.anchorVisible($0) })
            snapTarget = (a, q, r)
            previewEnd = r == .added ? q : cursor      // valid targets pull the wire onto the dot
        } else {
            snapTarget = nil
            previewEnd = cursor
        }
        updateLinkPreview()
    }

    /// Ends a link drag. Always clears the drag state; returns the outcome (nil = cancelled).
    @discardableResult
    func editMouseUp(at p: CGPoint) -> LinkResult? {
        defer { cancelLinkDrag() }
        guard let src = linkDrag else { return nil }
        touchEdit()
        guard p.x.isFinite, p.y.isFinite, let (target, _) = snapCandidate(near: p) else { return nil }
        return addUserLink(UserLink(a: src, b: target))
    }

    func cancelLinkDrag() {
        guard linkDrag != nil || linkPreview.parent != nil else { return }
        linkDrag = nil
        snapTarget = nil
        linkPreview.removeAllChildren()
        linkPreview.removeFromParent()
        if lightEditMode { refreshAnchorDots() }
    }

    /// Live preview: a sagging wire with a few bulbs from the source anchor to the cursor.
    private func updateLinkPreview() {
        linkPreview.removeAllChildren()
        guard let src = linkDrag else { return }
        guard let p0 = anchorPoint(src) else { cancelLinkDrag(); return }
        let p1 = previewEnd
        let chord = hypot(p1.x - p0.x, p1.y - p0.y)
        guard chord.isFinite else { return }
        let c = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2 - 2 * min(90, 18 + chord * 0.12))
        func bez(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
        }
        let path = CGMutablePath()
        path.move(to: p0)
        path.addQuadCurve(to: p1, control: c)
        let wire = SKShapeNode(path: path)
        wire.strokeColor = rgb(0.06, 0.16, 0.08, 0.95)
        wire.lineWidth = 1.3
        linkPreview.addChild(wire)
        if let t = snapTarget {
            // Target feedback: a big gold ring on a valid dot, a red dot on an invalid one.
            let ok = t.result == .added
            let ring = SKSpriteNode(texture: WinterScene.dotTexture, size: CGSize(width: ok ? 30 : 20, height: ok ? 30 : 20))
            ring.position = t.point
            ring.color = ok ? WinterScene.gold : rgb(1, 0.2, 0.2)
            ring.colorBlendFactor = ok ? 0 : 1
            ring.zPosition = 1
            linkPreview.addChild(ring)
        }
        let count = min(30, max(3, Int(chord / 30)))
        for k in 0..<count {
            let q = bez((CGFloat(k) + 0.5) / CGFloat(count))
            let b = SKSpriteNode(texture: LightTextures.teardrop, size: CGSize(width: 9, height: 12.6))
            b.anchorPoint = CGPoint(x: 0.5, y: 1)
            b.color = LightTextures.palette[k % LightTextures.palette.count]
            b.colorBlendFactor = 1
            b.alpha = 0.8
            b.position = CGPoint(x: q.x, y: q.y + 1)
            linkPreview.addChild(b)
        }
    }

    /// Adds a link after validation (`requireVisible` = both anchors uncovered right now).
    @discardableResult
    func addUserLink(_ link: UserLink, requireVisible: Bool = true) -> LinkResult {
        let r = LightLinkStore.validate(link, existing: userLinks, windows: appWindows,
                                        visible: { requireVisible ? self.anchorVisible($0) : true })
        guard r == .added else { return r }
        userLinks.append(link)
        syncLights()
        onUserLinksChanged?()
        return r
    }

    func removeUserLink(_ link: UserLink) {
        let before = userLinks.count
        userLinks.removeAll { $0.same(as: link) }
        guard userLinks.count != before else { return }
        syncLights()
        onUserLinksChanged?()
    }

    /// Restored links (already resolved against the current windows); visibility is not required.
    func restoreUserLinks(_ links: [UserLink]) {
        var changed = false
        for l in links where addUserLink(l, requireVisible: false) == .added { changed = true }
        if changed { syncLights() }
    }

    /// Current windows (screen-local) — used to persist links by owner app + index.
    var currentWindows: [AppWindow] { appWindows }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        if lightEditMode, editMouseDown(at: p) { return }
        lastMouse = p
        dragDistance = 0
        samples = [(event.timestamp, p)]

        if ballDeleteTap(at: p) { return }
        if let pl = plow, pl.isHit(p), !plowUnderDock(pl) {
            pl.held = true
            drag = .plow(pl)
            dragOffset = pl.position - p
            return
        }
        if let g = hoverGift, g.parent != nil, g.deleteHit(p) {
            deleteGift(g)
            return
        }
        if let s = santa, s.isHit(p) {
            s.beginHold()
            drag = .santa(s)
            dragOffset = s.position - p
            return
        }
        if let g = gift(at: p) {
            if event.clickCount >= 2 {
                openGift(g)
                return
            }
            g.held = true
            g.vel = .zero
            g.angVel = 0
            g.zPosition = zGift + 5
            drag = .gift(g)
            dragOffset = g.position - p
            return
        }
        if let b = ball(at: p) {
            pendingBall = b
            dragOffset = b.position - p
            return
        }
        if let ground, ground.isSnow(at: p) {
            startNewBall(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.location(in: self)
        if linkDrag != nil { editMouseDragged(to: p); return }
        dragDistance += hypot(p.x - lastMouse.x, p.y - lastMouse.y)
        lastMouse = p
        samples.append((event.timestamp, p))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }

        if let b = pendingBall, dragDistance > 3 {
            pendingBall = nil
            if let below = b.below {
                below.above = nil
                b.below = nil
                b.outfit = Outfit()
                refreshDecor(root(of: below))
                refreshDecor(b)
                CustomizePanel.shared.validate()
            }
            b.held = true
            drag = .ball(b)
        }
        guard let d = drag else { return }
        switch d {
        case .ball(let b):
            dragBall(b, to: p + dragOffset)
        case .santa(let s):
            let t = p + dragOffset
            s.position = CGPoint(x: clamp(t.x, 0, size.width), y: clamp(t.y, 0, size.height - 60))
        case .gift(let g):
            let t = p + dragOffset
            g.position = CGPoint(x: clamp(t.x, g.hw, size.width - g.hw), y: clamp(t.y, g.hh, size.height - g.hh))
        case .plow(let pl):
            let t = p + dragOffset
            pl.position = CGPoint(x: clamp(t.x, 20, size.width - 20), y: clamp(t.y, 0, size.height - 40))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if linkDrag != nil {
            let result = editMouseUp(at: event.location(in: self))
            onLinkResult?(result)
            return
        }
        if let b = pendingBall {
            pendingBall = nil
            let r = root(of: b)
            if r.above != nil { openCustomizer(r) }
            return
        }
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .ball(let b):
            b.held = false
            b.vy = 0
        case .santa(let s):
            if dragDistance < 4 {
                s.endHold(click: true)
                s.say("Ho Ho Ho!")
                spawnGift(at: s.giftOrigin, vel: CGVector(dx: s.dir * 60, dy: 120))
            } else {
                s.endHold(click: false)
            }
        case .gift(let g):
            g.held = false
            g.zPosition = zGift
            g.vel = throwVelocity(now: event.timestamp)
            g.angVel = -g.vel.dx * 0.01
        case .plow(let pl):
            pl.held = false
            pl.vy = 0
            pl.airborne = true
            if dragDistance < 4 { pl.honk() }        // click: beacon on/off + honk bounce
        }
    }

    private func throwVelocity(now: TimeInterval) -> CGVector {
        guard let last = samples.last, now - last.t <= 0.08 else { return .zero }
        let old = samples.first { last.t - $0.t <= 0.1 } ?? last
        let dt = CGFloat(last.t - old.t)
        guard dt > 0.004 else { return .zero }
        var v = CGVector(dx: (last.p.x - old.p.x) / dt, dy: (last.p.y - old.p.y) / dt)
        let m = hypot(v.dx, v.dy)
        if m > 2600 {
            v.dx *= 2600 / m
            v.dy *= 2600 / m
        }
        return v
    }

    private func openCustomizer(_ r: Snowball) {
        guard let window = view?.window else { return }
        let ch = chain(r)
        guard let top = ch.last else { return }
        let maxR = ch.map { $0.radius }.max() ?? r.radius
        let bottom = r.position.y - r.radius
        let rect = CGRect(x: r.position.x - maxR, y: bottom, width: 2 * maxR,
                          height: top.position.y + top.radius - bottom)
        CustomizePanel.shared.show(for: r, scene: self,
                                   anchor: rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY))
    }

    // MARK: Snowballs

    private func startNewBall(at p: CGPoint) {
        guard let ground else { return }
        if balls.count >= maxBalls {
            guard let old = balls.first(where: { $0.below == nil && $0.above == nil && !$0.held }) else { return }
            old.removeFromParent()
            balls.removeAll { $0 === old }
        }
        let b = Snowball(radius: 7)
        b.position = CGPoint(x: clamp(p.x, 7, size.width - 7), y: ground.surface(at: p.x) + 7 * 0.9)
        b.zPosition = 10
        if let view { b.rasterize(view: view) }
        addChild(b)
        balls.append(b)
        refreshDecor(b)
        _ = ground.remove(centerX: p.x, halfWidth: 4, depth: 1.5)
        b.held = true
        drag = .ball(b)
        dragOffset = b.position - p
    }

    /// Rolls a ball toward `target` exactly like a mouse drag (offscreen harness).
    func rollBall(_ b: Snowball, to target: CGPoint) {
        b.held = true
        drag = .ball(b)
        dragBall(b, to: target)
    }

    private func dragBall(_ b: Snowball, to target: CGPoint) {
        guard let ground else { return }
        let r = b.radius
        let nx = clamp(target.x, r, size.width - r)
        let sup = support(at: nx, below: target.y - r * 0.9 + 6)
        let rest = sup.y + r * 0.9
        if target.y <= rest + 6 {
            // Rolling along the snow: rotate and grow by picking up snow.
            let dx = nx - b.position.x
            if b.above == nil && dx != 0 {
                b.roll(dx)
                if b.radius < Snowball.maxRadius {
                    let steps = max(1, Int(abs(dx) / 4))
                    let stepDx = dx / CGFloat(steps)
                    var removed: CGFloat = 0
                    for k in 1...steps {
                        let x = b.position.x + stepDx * CGFloat(k)
                        let hw = max(4, b.radius * 0.45), depth = abs(stepDx) * 0.15
                        if let cap = sup.cap {
                            // Only a thin line of snow on a window top: modest growth (20%).
                            removed += cap.remove(centerX: x, halfWidth: hw, depth: depth) * 0.2
                        } else {
                            removed += ground.remove(centerX: x, halfWidth: hw, depth: depth)
                        }
                    }
                    if removed > 0 {
                        let area = CGFloat.pi * b.radius * b.radius + removed * 2.5
                        b.setRadius(sqrt(area / .pi))
                    }
                }
            }
            let x = clamp(nx, b.radius, size.width - b.radius)
            let s = support(at: x, below: target.y - r * 0.9 + 6)
            b.position = CGPoint(x: x, y: s.y + b.radius * 0.9)
            b.restingOn = s.cap?.id
        } else {
            b.position = CGPoint(x: nx, y: min(target.y, size.height - r))
            b.restingOn = nil
        }
        b.vy = 0
    }

    private func updateBalls(_ dt: CGFloat) {
        let roots = balls.filter { $0.below == nil }
        for b in roots {
            // Rider wobble: damped tilt spring (~2Hz), clamped and NaN-safe.
            if b.tilt != 0 || b.tiltVel != 0 {
                b.tiltVel += (-80 * b.tilt - 6 * b.tiltVel) * dt
                b.tilt = clamp(b.tilt + b.tiltVel * dt, -0.5, 0.5)
                if !b.tilt.isFinite || !b.tiltVel.isFinite { b.tilt = 0; b.tiltVel = 0 }
                if abs(b.tilt) < 0.001 && abs(b.tiltVel) < 0.01 { b.tilt = 0; b.tiltVel = 0 }
            }
        }
        for b in roots where !b.held {
            let oldBottom = b.position.y - b.radius * 0.9
            b.vy -= ballGravity * dt
            var p = b.position
            p.y += b.vy * dt
            if b.vx != 0 {
                p.x += b.vx * dt
                if !b.vx.isFinite { b.vx = 0 }
            }
            p.x = clamp(p.x, b.radius, size.width - b.radius)
            let sup = support(at: p.x, below: oldBottom + 1, riding: b.vx == 0 ? b.restingOn : nil)
            let rest = sup.y + b.radius * 0.9
            if p.y <= rest {
                p.y = rest
                b.vy = 0
                b.vx *= pow(0.001, dt)                   // rolls to a stop after landing
                if abs(b.vx) < 5 { b.vx = 0 }
                b.restingOn = sup.cap?.id
            } else {
                b.restingOn = nil
            }
            b.position = p
            if p.y > rest + 0.5 { landOnStacks(b) }
        }
        if roots.count > 1 {
            for i in 0..<(roots.count - 1) {
                for j in (i + 1)..<roots.count { separate(roots[i], roots[j]) }
            }
        }
        for r in roots { layout(r) }
    }

    /// A falling ball either snaps onto a compatible stack top or slides off it.
    private func landOnStacks(_ b: Snowball) {
        let count = chain(b).count
        for t in balls where t.above == nil {
            let tr = root(of: t)
            if tr === b || tr.held { continue }
            let dx = b.position.x - t.position.x
            let dy = b.position.y - t.position.y
            let d = hypot(dx, dy)
            guard d < b.radius + t.radius, dy > 0 else { continue }
            if count + chain(tr).count <= 3 && b.radius <= t.radius * 1.1 && abs(dx) < t.radius * 0.8 {
                t.above = b
                b.below = t
                b.vy = 0
                refreshDecor(tr)
                CustomizePanel.shared.validate()
                return
            }
            let nx = d > 0.01 ? dx / d : 1
            let ny = d > 0.01 ? dy / d : 0
            b.position = CGPoint(x: t.position.x + nx * (b.radius + t.radius),
                                 y: t.position.y + ny * (b.radius + t.radius))
            if abs(nx) < 0.2 { b.position.x += (dx >= 0 ? 1 : -1) * 2 }
            b.vy *= 0.3
        }
    }

    private func separate(_ a: Snowball, _ b: Snowball) {
        guard abs(a.position.y - restY(a, a.position.x)) < 1.5,
              abs(b.position.y - restY(b, b.position.x)) < 1.5 else { return }
        let dx = b.position.x - a.position.x
        let minD = (a.radius + b.radius) * 0.92
        guard abs(dx) < minD, abs(b.position.y - a.position.y) < (a.radius + b.radius) * 0.9 else { return }
        let s: CGFloat = dx >= 0 ? 1 : -1
        let overlap = minD - abs(dx)
        let wa: CGFloat = a.held ? 0 : (b.held ? 1 : 0.5)
        let wb: CGFloat = b.held ? 0 : (a.held ? 1 : 0.5)
        a.position.x = clamp(a.position.x - s * overlap * wa, a.radius, size.width - a.radius)
        b.position.x = clamp(b.position.x + s * overlap * wb, b.radius, size.width - b.radius)
    }

    private func layout(_ root: Snowball) {
        let ch = chain(root)
        let baseZ: CGFloat = root.held ? 14 : 10
        let tilt = root.tilt.isFinite ? clamp(root.tilt, -0.5, 0.5) : 0
        for (i, b) in ch.enumerated() {
            b.zPosition = baseZ + CGFloat(i) * 10
            b.zRotation = tilt
            if i > 0 {
                let below = ch[i - 1]
                let d = below.radius * 0.8 + b.radius * 0.8
                b.position = CGPoint(x: below.position.x - sin(tilt) * d, y: below.position.y + cos(tilt) * d)
                b.vy = 0
            }
        }
    }

    // MARK: Gifts

    /// The gift placed at launch / overlay rebuild; `onStarterGiftGone` fires when the user
    /// deletes, opens or clears it (so it is not respawned again this session).
    private weak var starterGift: Gift?
    var onStarterGiftGone: (() -> Void)?

    /// x on the Dock band about 1/3 from its left end, else 30% across the ground snow.
    private var giftHomeX: CGFloat {
        if let b = dockBand, b.maxX - b.minX > 40 { return b.minX + (b.maxX - b.minX) / 3 }
        return size.width * 0.3
    }

    /// Places the starter gift resting on the Dock-top (or ground) snow. Normal physics from then on.
    func placeStarterGift() {
        guard starterGift == nil, let ground else { return }
        let x = giftHomeX
        guard let g = spawnGift(at: CGPoint(x: x, y: ground.surface(at: x) + 12 - 1), vel: .zero, spin: false, variant: 0) else { return }
        starterGift = g
    }

    /// "Add Gift": drops a new gift onto the Dock (or ground) from a little above it.
    func dropGift() {
        guard let ground else { return }
        let x = clamp(giftHomeX + CGFloat.random(in: -60...60), 20, size.width - 20)
        _ = spawnGift(at: CGPoint(x: x, y: ground.surface(at: x) + 140), vel: .zero)
    }

    var canAddGift: Bool { gifts.count < maxGifts }

    private func starterGone(_ g: Gift) {
        guard g === starterGift else { return }
        starterGift = nil
        onStarterGiftGone?()
    }

    @discardableResult
    private func spawnGift(at p: CGPoint, vel: CGVector, spin: Bool = true,
                           variant: Int = Int.random(in: 0..<Gift.variantCount)) -> Gift? {
        // At the cap nothing new appears (Santa just stops dropping); old gifts are never evicted.
        guard gifts.count < maxGifts, p.x.isFinite, p.y.isFinite else { return nil }
        let g = Gift(variant: variant)
        g.position = CGPoint(x: clamp(p.x, g.hw, size.width - g.hw), y: clamp(p.y, g.hh, size.height - g.hh))
        g.vel = vel
        g.angVel = spin ? CGFloat.random(in: -2...2) : 0
        g.zPosition = zGift
        if let view { g.rasterize(view: view) }
        addChild(g)
        gifts.append(g)
        return g
    }

    private func removeGift(_ g: Gift) {
        gifts.removeAll { $0 === g }
        if hoverGift === g { hoverGift = nil }
        if let d = drag, case .gift(let dg) = d, dg === g { drag = nil }
    }

    private func deleteGift(_ g: Gift) {
        starterGone(g)
        removeGift(g)
        g.setDeleteVisible(false)
        g.run(.sequence([.group([.scale(to: 0.1, duration: 0.18), .fadeOut(withDuration: 0.18)]), .removeFromParent()]))
        for _ in 0..<8 {
            let puff = SKSpriteNode(texture: Textures.snowflake, size: CGSize(width: 10, height: 10))
            puff.position = g.position
            puff.zPosition = zFX
            addChild(puff)
            let a = CGFloat.random(in: 0...(2 * .pi))
            let move = SKAction.moveBy(x: cos(a) * 26, y: sin(a) * 26, duration: 0.35)
            move.timingMode = .easeOut
            puff.run(.sequence([.group([move, .fadeOut(withDuration: 0.35)]), .removeFromParent()]))
        }
    }

    private func openGift(_ g: Gift) {
        let p = g.position
        starterGone(g)
        removeGift(g)
        g.removeFromParent()
        let colors: [NSColor] = [rgb(1, 0.25, 0.3), rgb(1, 0.8, 0.2), rgb(0.3, 0.8, 0.4), rgb(0.35, 0.6, 1), rgb(0.85, 0.45, 1), .white]
        for _ in 0..<28 {
            let c = SKSpriteNode(color: colors.randomElement() ?? .white, size: CGSize(width: 4, height: 7))
            c.position = p
            c.zPosition = zFX
            c.zRotation = CGFloat.random(in: 0...(2 * .pi))
            addChild(c)
            let a = CGFloat.random(in: 0...(2 * .pi))
            let dist = CGFloat.random(in: 40...110)
            let move = SKAction.moveBy(x: cos(a) * dist, y: sin(a) * dist + 30, duration: 0.9)
            move.timingMode = .easeOut
            c.run(.sequence([
                .group([move, .rotate(byAngle: CGFloat.random(in: -6...6), duration: 0.9),
                        .sequence([.wait(forDuration: 0.5), .fadeOut(withDuration: 0.4)])]),
                .removeFromParent()]))
        }
        let sparkle = PrimRender.node(.label("✨", 0, 0, 30))
        sparkle.position = p
        sparkle.zPosition = zFX
        sparkle.setScale(0.3)
        addChild(sparkle)
        sparkle.run(.sequence([.group([.scale(to: 1.5, duration: 0.5), .fadeOut(withDuration: 0.5)]), .removeFromParent()]))

        let surprises = ["🍪", "⭐️", "🧸", "🍬", "❄️", "🍭", "🎄", "🧦", "☕️", "🦌"]
        let s = PrimRender.node(.label(surprises.randomElement() ?? "⭐️", 0, 0, 34))
        s.position = p
        s.zPosition = zFX + 1
        s.setScale(0.2)
        addChild(s)
        let rise = SKAction.moveBy(x: 0, y: 55, duration: 0.6)
        rise.timingMode = .easeOut
        s.run(.sequence([.group([.scale(to: 1.25, duration: 0.25), rise]), .wait(forDuration: 1.0),
                         .group([.fadeOut(withDuration: 0.6), .moveBy(x: 0, y: 20, duration: 0.6)]),
                         .removeFromParent()]))
    }

    /// Gifts stack at most this many high; a gift above that slides off toward the nearer Dock end.
    static let maxGiftStack = 3
    static let giftSlideSpeed: CGFloat = 90

    /// Gift physics: gravity onto snow / window caps / other gifts (box stacking), horizontal-only
    /// separation between side-by-side boxes (no vertical push, so piles rest without jitter),
    /// off-centre or over-tall stacks slide off and can drop off the Dock ends to the floor.
    private func updateGifts(_ dt: CGFloat) {
        guard let ground else { return }
        // Bottom-up so each gift sees the supports below it already resolved this frame.
        for g in gifts.sorted(by: { $0.position.y < $1.position.y }) where !g.held {
            let oldBottom = g.position.y - g.hh
            g.vel.dy -= gravity * dt
            var p = g.position
            p.x += g.vel.dx * dt
            p.y += g.vel.dy * dt
            if p.x < g.hw { p.x = g.hw; g.vel.dx = abs(g.vel.dx) * 0.6 }
            if p.x > size.width - g.hw { p.x = size.width - g.hw; g.vel.dx = -abs(g.vel.dx) * 0.6 }
            if p.y > size.height - g.hh { p.y = size.height - g.hh; g.vel.dy = -abs(g.vel.dy) * 0.5 }
            // Treat the Dock's ends as walls when the gift is below the Dock top.
            if ground.surface(at: p.x) - (g.position.y - g.hh) > 12 {
                p.x = g.position.x
                g.vel.dx = -g.vel.dx * 0.5
            }
            let sup = support(at: p.x, below: oldBottom + 1)
            var floor = sup.y + g.hh - 1
            var under: Gift?
            for o in gifts where o !== g && !o.held && abs(o.position.x - p.x) < g.hw + o.hw - 6 {
                let top = o.position.y + o.hh
                guard top <= oldBottom + 0.5 else { continue }   // only boxes below (no climbing)
                if top + g.hh > floor { floor = top + g.hh; under = o }
            }
            var grounded = false
            g.restingOn = nil
            if p.y <= floor {
                p.y = floor
                g.restingOn = under == nil ? sup.cap?.id : nil
                if g.vel.dy < -90 {
                    g.vel.dy = -g.vel.dy * 0.38
                    g.vel.dx *= 0.8
                    g.angVel *= -0.5
                } else {
                    g.vel.dy = 0
                    grounded = true
                }
            }
            g.stackLevel = under.map { $0.stackLevel + 1 } ?? 0
            if grounded {
                g.vel.dx *= pow(CGFloat(0.02), dt)
                g.zRotation += (0 - g.zRotation) * min(1, 12 * dt)
                g.angVel = 0
                if let u = under {
                    let off = p.x - u.position.x
                    // Stable if any box at the supporting height is roughly centred under it, or if
                    // it bridges boxes on both sides (otherwise a bridged box would slide back and forth).
                    var centred = false, left = false, right = false
                    for o in gifts where o !== g && !o.held && abs(o.position.x - p.x) < g.hw + o.hw - 6
                        && p.y - (o.position.y + o.hh + g.hh) > -0.5 && p.y - (o.position.y + o.hh + g.hh) < 3 {
                        let d = o.position.x - p.x
                        if abs(d) <= g.hw * 0.8 { centred = true }
                        if d < 0 { left = true } else { right = true }
                    }
                    let unstable = !centred && !(left && right)
                    if g.stackLevel >= WinterScene.maxGiftStack || unstable {
                        // Topple: slide sideways off the box below (toward the nearer Dock end
                        // when over-tall, otherwise toward the side it overhangs).
                        var dir: CGFloat = off > 0 ? 1 : -1
                        if g.stackLevel >= WinterScene.maxGiftStack {
                            let mid = dockBand.map { ($0.minX + $0.maxX) / 2 } ?? size.width / 2
                            dir = p.x < mid ? -1 : 1
                        }
                        p.x = clamp(p.x + dir * WinterScene.giftSlideSpeed * dt, g.hw, size.width - g.hw)
                    }
                }
            } else {
                g.zRotation += g.angVel * dt
            }
            g.position = p
        }
        if gifts.count > 1 {
            for i in 0..<(gifts.count - 1) {
                for j in (i + 1)..<gifts.count { separate(gifts[i], gifts[j], ground) }
            }
        }
    }

    /// Horizontal separation for boxes that overlap side by side. Never pushes vertically and
    /// never pushes a box into the side of the Dock from below.
    private func separate(_ a: Gift, _ b: Gift, _ ground: GroundSnow) {
        let dy = b.position.y - a.position.y
        guard abs(dy) < a.hh + b.hh - 6 else { return }
        let dx = b.position.x - a.position.x
        let overlap = a.hw + b.hw - abs(dx)
        guard overlap > 0 else { return }
        let s: CGFloat = dx >= 0 ? 1 : -1
        func canMove(_ g: Gift, _ nx: CGFloat) -> Bool {
            !g.held && nx >= g.hw && nx <= size.width - g.hw && ground.surface(at: nx) - (g.position.y - g.hh) <= 12
        }
        var wa: CGFloat = a.held ? 0 : (b.held ? 1 : 0.5)
        var wb: CGFloat = 1 - wa
        if a.held && b.held { return }
        if !canMove(a, a.position.x - s * overlap * wa) { wa = 0; wb = 1 }
        if !canMove(b, b.position.x + s * overlap * wb) { wb = 0; wa = canMove(a, a.position.x - s * overlap) ? 1 : 0 }
        a.position.x -= s * overlap * wa
        b.position.x += s * overlap * wb
        // Remove the approaching horizontal velocity (inelastic, no bounce jitter).
        let rv = (b.vel.dx - a.vel.dx) * s
        if rv < 0 {
            if wa > 0 { a.vel.dx += rv * s * 0.5 * (wb > 0 ? 1 : 2) }
            if wb > 0 { b.vel.dx -= rv * s * 0.5 * (wa > 0 ? 1 : 2) }
        }
    }

    // MARK: Gift persistence

    struct SavedGift: Codable, Equatable {
        var x: Double
        var y: Double
        var variant: Int
        var starter: Bool
    }

    /// Current gifts (screen-local, full precision so stacks restore exactly).
    func giftSnapshot() -> [SavedGift] {
        gifts.compactMap { g in
            guard g.position.x.isFinite, g.position.y.isFinite else { return nil }
            return SavedGift(x: Double(g.position.x), y: Double(g.position.y), variant: g.variant, starter: g === starterGift)
        }
    }

    /// Restores saved gifts (clamped to this screen; physics settles them on the surface).
    /// Returns true if a starter gift was among them.
    @discardableResult
    func restoreGifts(_ saved: [SavedGift]) -> Bool {
        var hadStarter = false
        // Static bottom-up placement: each box is put exactly at its resting height on the snow /
        // cap / boxes already placed under it (same support rules as the physics), so piles come
        // back as saved even if the snow under them is a little higher or lower now.
        for s in saved.sorted(by: { $0.y < $1.y }) where s.x.isFinite && s.y.isFinite {
            let hw: CGFloat = 15, hh: CGFloat = 12
            let x = clamp(CGFloat(s.x), hw, size.width - hw)
            let savedBottom = clamp(CGFloat(s.y), hh, size.height - hh) - hh
            var y = support(at: x, below: savedBottom + 1).y + hh - 1
            for o in gifts where abs(o.position.x - x) < hw + o.hw - 6 && o.position.y + o.hh <= savedBottom + 3 {
                y = max(y, o.position.y + o.hh + hh)
            }
            guard let g = spawnGift(at: CGPoint(x: x, y: min(y, size.height - hh)), vel: .zero, spin: false,
                                    variant: s.variant) else { break }
            if s.starter && starterGift == nil { starterGift = g; hadStarter = true }
        }
        return hadStarter
    }

    // MARK: Frame update

    override func update(_ currentTime: TimeInterval) {
        guard let ground else { return }
        if lastTime == 0 { lastTime = currentTime }
        let rawDt = currentTime - lastTime
        let dt = CGFloat(min(max(rawDt, 0), 1.0 / 30.0))
        lastTime = currentTime
        // Stutter evidence for "Report a Glitch" (not while paused).
        // (2.5× the target interval: one dropped frame at 30fps is 67ms and is not a hitch.)
        let target = 1.0 / Double(max(1, view?.preferredFramesPerSecond ?? 60))
        if rawDt > 2.5 * target && rawDt < 5 && isRendering {
            Diag.shared.row("hitch", note: String(format: "frame %.0fms target %.0fms isMain=%d", rawDt * 1000, target * 1000, isMainScreen ? 1 : 0))
        }
        elapsed += dt
        lastUpdateUptime = ProcessInfo.processInfo.systemUptime

        emitter?.xAcceleration = 10 * cos(elapsed * 0.7)

        if !snowPaused { ground.accumulate(rate: intensity.accumulation, dt: dt) }
        ground.relax()
        ground.update(dt: dt)

        stepLive(dt)
        settleWindows()
        updateBallDeleteButton()
        updateRiderOcclusion()
        placeDefaultSnowmanIfNeeded()
        if lightEditMode { pulseAnchorDots() }
        updateGranular(dt)
        if !caps.isEmpty {
            let scale = view?.window?.backingScaleFactor ?? 2
            for cap in caps.values {
                if !snowPaused { cap.accumulate(rate: intensity.accumulation * WinterScene.capGrowth, dt: dt) }   // very slow
            }
            // Texture redraws are expensive (Core Graphics, window-wide): share a small per-frame
            // budget, most overdue first, so occlusion changes during a drag never redraw many caps
            // in one frame (that was 15 redraws / 28ms frames before).
            var budget = unsettled.isEmpty ? WinterScene.idleRenderBudget : WinterScene.movingRenderBudget
            for cap in caps.values.sorted(by: { $0.renderPriority > $1.renderPriority }) {
                if cap.render(dt: dt, scale: scale, allowed: budget > 0) { budget -= 1 }
            }
        }
        updateChunks(dt)
        updatePlow(dt)
        updateClumps(dt)
        updateGrains(dt)
        if windowLightsEnabled { lights.update(dt: dt, time: elapsed, windows: appWindows) }

        updateBalls(dt)
        updateGifts(dt)
        if !capWorlds.isEmpty { syncCapWorlds() }
        if heldCoverFrames > 0 { heldCoverFrames -= 1 } else if heldCoverFrames == 0 { heldCover.removeAll(); heldCoverFrames = -1 }
        onUpdate?()

        if let s = santa {
            var landing: ClosedRange<CGFloat>?
            if let b = dockBand, b.maxX > b.minX { landing = b.minX...b.maxX }
            if s.step(dt: dt, size: size, surface: { x, y in self.support(at: x, below: y).y }, landing: landing) {
                spawnGift(at: s.giftOrigin, vel: CGVector(dx: s.dir * 90, dy: 30))
            }
        }
    }
}
