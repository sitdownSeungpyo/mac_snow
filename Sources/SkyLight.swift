import AppKit
import Darwin

/// Optional real-time window move/resize notifications through private SkyLight calls.
/// Everything is resolved with dlsym at runtime: if any symbol is missing (or the OS refuses),
/// `SkyLightEvents.shared.available` is false and the app stays on the public-API fallback.
/// Own minimal declarations; API names and event numbers were learned from public documentation
/// of the private SkyLight interface (as used by e.g. JankyBorders/yabai) — no code was copied.
final class SkyLightEvents {
    static let shared = SkyLightEvents()

    // Window notification event numbers (SkyLight).
    static let eventClose: UInt32 = 804
    static let eventMove: UInt32 = 806
    static let eventResize: UInt32 = 807
    /// Window reordered (z-order). Number as documented for the private interface; unverified on
    /// this OS — the 4Hz re-order timer covers it if it never arrives.
    static let eventReorder: UInt32 = 808

    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias RegisterNotifyProc = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias RequestNotifications = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32) -> Int32
    private typealias GetWindowBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    typealias OrderWindow = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32
    typealias MoveWindow = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGPoint>) -> Int32
    typealias UpdateToggle = @convention(c) (Int32) -> Int32
    typealias GetWindowLevel = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32

    private var mainConnection: MainConnectionID?
    private var registerProc: RegisterNotifyProc?
    private var requestNotifications: RequestNotifications?
    private var getBounds: GetWindowBounds?
    // Cap windows (per-window snow windows ordered above their target): optional extras.
    private(set) var orderWindow: OrderWindow?
    private(set) var moveWindow: MoveWindow?
    private(set) var disableUpdate: UpdateToggle?
    private(set) var reenableUpdate: UpdateToggle?
    private(set) var getWindowLevel: GetWindowLevel?
    /// All calls needed for cap windows resolved (and the base notifications available).
    var capsAvailable: Bool {
        available && orderWindow != nil && moveWindow != nil && disableUpdate != nil && reenableUpdate != nil && getWindowLevel != nil
    }
    /// Connection id for cap-window calls (main connection).
    var connection: Int32 { cid != 0 ? cid : (mainConnection?() ?? 0) }
    private(set) var reorderRegistered = false
    private(set) var available = false
    private(set) var registered = false
    private(set) var failure: String?
    private var cid: Int32 = 0
    private var subscribed: [UInt32] = []

    /// Called on the main thread for every move/resize/close event: (event, window id).
    var handler: ((UInt32, Int) -> Void)?
    private(set) var eventCount = 0

    private init() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else {
            failure = "SkyLight framework not loadable"
            return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        mainConnection = sym("SLSMainConnectionID", MainConnectionID.self)
        registerProc = sym("SLSRegisterNotifyProc", RegisterNotifyProc.self)
        requestNotifications = sym("SLSRequestNotificationsForWindows", RequestNotifications.self)
        getBounds = sym("SLSGetWindowBounds", GetWindowBounds.self)
        orderWindow = sym("SLSOrderWindow", OrderWindow.self)
        moveWindow = sym("SLSMoveWindow", MoveWindow.self)
        disableUpdate = sym("SLSDisableUpdate", UpdateToggle.self)
        reenableUpdate = sym("SLSReenableUpdate", UpdateToggle.self)
        getWindowLevel = sym("SLSGetWindowLevel", GetWindowLevel.self)
        let missing = [("SLSMainConnectionID", mainConnection != nil), ("SLSRegisterNotifyProc", registerProc != nil),
                       ("SLSRequestNotificationsForWindows", requestNotifications != nil),
                       ("SLSGetWindowBounds", getBounds != nil)].filter { !$0.1 }.map { $0.0 }
        if missing.isEmpty { available = true } else { failure = "missing symbols: " + missing.joined(separator: ", ") }
    }

    /// The C callback: bounded work, then hop to the main thread.
    private static let callback: NotifyProc = { event, data, length, _ in
        guard let data, length >= MemoryLayout<UInt32>.size else { return }
        let raw = data.load(as: UInt32.self)
        CapMover.shared.noteCallback(onMain: Thread.isMainThread)
        // Cap windows move right here, on the callback's thread, before anything else: no hop,
        // no redraw (bounded work: one bounds read + one move under a lock-protected lookup).
        if event == SkyLightEvents.eventMove || event == SkyLightEvents.eventResize { CapMover.shared.follow(raw) }
        // A closing window's cap goes out right here (like the minimize case), before the hop.
        if event == SkyLightEvents.eventClose { CapMover.shared.closeNow(raw) }
        let wid = Int(raw)
        if Thread.isMainThread {
            SkyLightEvents.shared.deliver(event, wid)
        } else {
            DispatchQueue.main.async { SkyLightEvents.shared.deliver(event, wid) }
        }
    }

    private func deliver(_ event: UInt32, _ wid: Int) {
        eventCount += 1
        handler?(event, wid)
    }

    /// Registers the move/resize/close procs once. Returns false (and sets `failure`) if refused.
    @discardableResult
    func start() -> Bool {
        guard available, !registered, let mainConnection, let registerProc else { return registered }
        cid = mainConnection()
        for e in [SkyLightEvents.eventMove, SkyLightEvents.eventResize, SkyLightEvents.eventClose] {
            let err = registerProc(SkyLightEvents.callback, e, nil)
            if err != 0 { failure = "SLSRegisterNotifyProc(\(e)) = \(err)"; return false }
        }
        registered = true
        // Optional: z-order changes (re-order cap windows right away). A refusal is not an error.
        reorderRegistered = registerProc(SkyLightEvents.callback, SkyLightEvents.eventReorder, nil) == 0
        return true
    }

    /// Current window level of `id` (nil if unavailable).
    func level(of id: Int) -> Int32? {
        guard let getWindowLevel, let wid = UInt32(exactly: id) else { return nil }
        var l: Int32 = 0
        return getWindowLevel(connection, wid, &l) == 0 ? l : nil
    }

    /// Orders our window `wid` directly above `target`. Returns the CGError (0 = ok), -1 if unavailable.
    @discardableResult
    func order(_ wid: Int, above target: Int) -> Int32 {
        guard let orderWindow, let w = UInt32(exactly: wid), let t = UInt32(exactly: target) else { return -1 }
        return orderWindow(connection, w, 1, t)
    }

    /// Asks for notifications about exactly these windows (call when the window list changes).
    /// Always passes the FULL current list (the call sets the subscription, it does not append).
    /// Returns the new count when the subscription changed, nil otherwise.
    @discardableResult
    func subscribe(_ ids: [Int]) -> Int? {
        guard registered, let requestNotifications else { return nil }
        var list = Array(Set(ids.compactMap { UInt32(exactly: $0) })).sorted()
        guard list != subscribed else { return nil }
        subscribed = list
        let n = Int32(list.count)
        _ = list.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress.map { requestNotifications(cid, $0, n) } ?? 0
        }
        return list.count
    }

    /// Current bounds of a window in CG (top-left) global coordinates, or nil.
    func bounds(of id: Int) -> CGRect? {
        guard available, let getBounds, let wid = UInt32(exactly: id) else { return nil }
        var r = CGRect.zero
        let c = cid != 0 ? cid : (mainConnection?() ?? 0)
        guard getBounds(c, wid, &r) == 0, r.width.isFinite, r.height.isFinite, r.width > 0, r.height > 0 else { return nil }
        return r
    }
}

/// Decides, per window and globally, whether live (event-driven) tracking is working.
/// Pure bookkeeping — no SkyLight calls — so it can be tested offscreen.
/// - A settled window whose top edge moved ≥ 3pt (seen by the poll) without any SkyLight event
///   within 2s becomes *non-live* on its own (it gets the slide-off treatment); an event for it
///   makes it live again.
/// - The whole app falls back only if ≥ 3 distinct windows each missed ≥ 2 times AND no move
///   event at all arrived for 10s; any new move event returns the app to live mode.
final class LiveTrackingMonitor {
    static let missWindow: TimeInterval = 2
    static let minMove: CGFloat = 3
    static let globalWindows = 3
    static let globalMisses = 2
    static let globalQuiet: TimeInterval = 10

    private(set) var nonLive = Set<Int>()
    private(set) var globalFallback = false
    private var pending: [Int: TimeInterval] = [:]
    private var lastEvent: [Int: TimeInterval] = [:]
    private var misses: [Int: Int] = [:]
    private var lastAnyEvent: TimeInterval = -1_000

    /// A SkyLight move/resize event for `wid`. Returns true if the global mode changed (back to live).
    @discardableResult
    func eventArrived(_ wid: Int, now: TimeInterval) -> Bool {
        lastEvent[wid] = now
        lastAnyEvent = now
        pending[wid] = nil
        nonLive.remove(wid)
        misses[wid] = 0
        if globalFallback { globalFallback = false; return true }
        return false
    }

    /// The poll saw `wid`'s top edge move by `distance` pt. Unsettled windows and sub-3pt jitter
    /// are ignored (transient open/zoom/close animations).
    func pollMove(_ wid: Int, distance: CGFloat, settled: Bool, now: TimeInterval) {
        guard settled, distance >= LiveTrackingMonitor.minMove else { return }
        if now - (lastEvent[wid] ?? -1_000) < 0.5 { return }       // an event already covered it
        if pending[wid] == nil { pending[wid] = now }
    }

    /// Window closed / gone: forget it.
    func forget(_ wid: Int) {
        pending[wid] = nil; lastEvent[wid] = nil; misses[wid] = nil; nonLive.remove(wid)
    }

    /// Call ~2Hz. Returns true if the global mode changed (to fallback).
    @discardableResult
    func tick(now: TimeInterval) -> Bool {
        for (wid, t) in pending where now - t > LiveTrackingMonitor.missWindow {
            pending[wid] = nil
            misses[wid, default: 0] += 1
            nonLive.insert(wid)
        }
        let bad = misses.values.filter { $0 >= LiveTrackingMonitor.globalMisses }.count
        if !globalFallback && bad >= LiveTrackingMonitor.globalWindows && now - lastAnyEvent > LiveTrackingMonitor.globalQuiet {
            globalFallback = true
            return true
        }
        return false
    }

    var summary: String {
        "nonLive=\(nonLive.sorted()) misses=\(misses.filter { $0.value > 0 }) lastEventAt=\(String(format: "%.1f", lastAnyEvent))"
    }
}


/// Minimize (genie) / programmatic shrink detection from window events. The genie animation shrinks
/// the window's bounds from the first frames on; a user resize or drag always has a mouse button
/// down. Pure (unit-tested offscreen).
enum WindowVanish {
    static func looksLikeMinimize(prev: CGRect, now: CGRect, dt: TimeInterval, mouseDown: Bool) -> Bool {
        guard !mouseDown, dt >= 0, dt < 0.3, prev.width > 40, prev.height > 40,
              now.width.isFinite, now.height.isFinite else { return false }
        // The genie scales the window down: neither side grows. (Live: an app snapping its width
        // 892→711 while its height grew 654→657, 29ms after the mouse came up, is no minimize.)
        guard now.width <= prev.width + 0.5, now.height <= prev.height + 0.5 else { return false }
        return now.width < prev.width * 0.88 || now.height < prev.height * 0.88
    }
}

/// Moves cap windows inside the SkyLight event callback (any thread). The registry is the only
/// shared state and is lock-protected; the main thread registers / unregisters caps.
final class CapMover {
    static let shared = CapMover()
    private struct Entry { var cap: UInt32; var above: CGFloat; var last: CGRect?; var lastT: TimeInterval = 0; var vanished = false; var x: CGFloat?; var resizing = false }
    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    /// A/B switches. Default OFF: SLSDisableUpdate on the shared main connection from the callback
    /// would freeze every window of ours if the re-enable were ever delayed, and a move does not
    /// change z-order (the 4Hz re-order + reorder events keep caps above their targets).
    var useTransaction = UserDefaults.standard.object(forKey: "capMoveTransaction") as? Bool ?? false
    var orderOnMove = UserDefaults.standard.object(forKey: "capMoveOrder") as? Bool ?? false
    private var callbacks = 0, callbacksOnMain = 0

    /// Counts every SkyLight callback (thread noted), so diag shows whether events still arrive.
    func noteCallback(onMain: Bool) {
        lock.lock(); callbacks += 1; if onMain { callbacksOnMain += 1 }; lock.unlock()
    }
    // Timing (µs): total, bounds read, move, order — reset by `drainStats`.
    private var total: [Double] = [], tBounds: [Double] = [], tMove: [Double] = [], tOrder: [Double] = []
    private var moveErrors = 0, roomJumps = 0
    private(set) var vanishedCount = 0

    /// Registers / updates a cap. `x` and `target` (CG global) seed where the cap was put at
    /// creation, so the first event keeps the cap's offset to its target.
    func set(target: Int, cap: Int, above: CGFloat, x: CGFloat? = nil, bounds: CGRect? = nil) {
        guard let t = UInt32(exactly: target), let c = UInt32(exactly: cap) else { return }
        lock.lock()
        var e = entries[t] ?? Entry(cap: c, above: above)
        e.cap = c; e.above = above
        if let x { e.x = x }
        if let bounds { e.last = bounds }
        entries[t] = e
        lock.unlock()
    }

    /// Where the cap of `target` is (global x), its offset `k` = target left edge − cap x, and
    /// whether the newest event resized the target. Read on the main thread every frame: the scene
    /// places the cap content with exactly what WindowServer was told.
    func anchor(target: Int) -> (x: CGFloat, k: CGFloat, resizing: Bool)? {
        guard let t = UInt32(exactly: target) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[t], let x = e.x, let last = e.last else { return nil }
        return (x, last.minX - x, e.resizing)
    }
    func remove(target: Int) {
        guard let t = UInt32(exactly: target) else { return }
        lock.lock(); entries[t] = nil; lock.unlock()
    }
    func removeAll() { lock.lock(); entries.removeAll(); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// The cap's x for a callback (pure). A move carries the cap by the target's displacement (its
    /// offset to the target stays); a resize (width changed) leaves it where it is, so both strip
    /// ends are drawn inside the cap at scene positions and neither depends on when WindowServer
    /// moves the cap. Only when a widening left edge has used up the room left of the overhang does
    /// the cap jump (`CapGeometry.leftRoom` further left; `jumped`).
    static func originX(target b: CGRect, previous: CGRect?, current: CGFloat?) -> (x: CGFloat, resizing: Bool, jumped: Bool) {
        let fresh = b.minX - CapGeometry.side - CapGeometry.leftRoom
        guard let prev = previous, let cur = current, cur.isFinite else { return (fresh, false, false) }
        let resizing = abs(b.width - prev.width) > 0.25
        let x = resizing ? cur : cur + (b.minX - prev.minX)
        if x > b.minX - CapGeometry.side { return (fresh, resizing, true) }
        return (x, resizing, false)
    }

    /// Called from the SkyLight callback for a move / resize of `target`.
    func follow(_ target: UInt32) {
        lock.lock()
        let e = entries[target]
        let tx = useTransaction, ord = orderOnMove
        lock.unlock()
        guard let e, !e.vanished else { return }
        let sls = SkyLightEvents.shared
        guard let move = sls.moveWindow else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let b = sls.bounds(of: Int(target)) else { return }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let cid = sls.connection
        let now = ProcessInfo.processInfo.systemUptime
        if let last = e.last, WindowVanish.looksLikeMinimize(prev: last, now: b, dt: now - e.lastT, mouseDown: NSEvent.pressedMouseButtons != 0) {
            // Minimize / hide: the cap disappears in this very callback (never follows the genie).
            _ = sls.orderWindow?(cid, e.cap, 0, 0)
            lock.lock(); entries[target]?.vanished = true; vanishedCount += 1; lock.unlock()
            return
        }
        lock.lock(); entries[target]?.last = b; entries[target]?.lastT = now; lock.unlock()
        var p = CapGeometry.capOriginCG(target: b, above: e.above)
        let o = CapMover.originX(target: b, previous: e.last, current: e.x)
        p.x = o.x
        lock.lock(); entries[target]?.x = o.x; entries[target]?.resizing = o.resizing; if o.jumped { roomJumps += 1 }; lock.unlock()
        if tx { _ = sls.disableUpdate?(cid) }
        let err = move(cid, e.cap, &p)
        let t2 = DispatchTime.now().uptimeNanoseconds
        if ord { _ = sls.orderWindow?(cid, e.cap, 1, target) }
        if tx { _ = sls.reenableUpdate?(cid) }
        let t3 = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if total.count < 20_000 {
            total.append(Double(t3 - t0) / 1000); tBounds.append(Double(t1 - t0) / 1000)
            tMove.append(Double(t2 - t1) / 1000); tOrder.append(Double(t3 - t2) / 1000)
        }
        if err != 0 { moveErrors += 1 }
        lock.unlock()
    }

    /// The target closed: its cap is ordered out now (callback thread). Returns µs taken, nil if
    /// no cap. The main thread then removes it (`CapWindowManager.remove`).
    @discardableResult
    func closeNow(_ target: UInt32) -> Double? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let e = entries[target]
        lock.unlock()
        guard let e, !e.vanished else { return nil }
        let sls = SkyLightEvents.shared
        _ = sls.orderWindow?(sls.connection, e.cap, 0, 0)
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        lock.lock(); entries[target]?.vanished = true; closedInCallback[target] = us; lock.unlock()
        return us
    }
    private var closedInCallback: [UInt32: Double] = [:]
    /// µs the callback took to order out the cap of `target` on its close event (taken once).
    func takeCloseLatency(_ target: Int) -> Double? {
        guard let t = UInt32(exactly: target) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return closedInCallback.removeValue(forKey: t)
    }

    /// Summary since the last call (diag); always returns a line (an absent row then means the
    /// main-thread timer itself stopped).
    func drainStats() -> String {
        lock.lock()
        let a = total, b = tBounds, m = tMove, o = tOrder, errs = moveErrors, jumps = roomJumps
        let cb = callbacks, cbMain = callbacksOnMain
        total.removeAll(); tBounds.removeAll(); tMove.removeAll(); tOrder.removeAll(); moveErrors = 0; roomJumps = 0
        callbacks = 0; callbacksOnMain = 0
        let tx = useTransaction, ord = orderOnMove
        lock.unlock()
        guard !a.isEmpty else { return "moves=0 callbacks=\(cb) onMain=\(cbMain)" }
        func p(_ x: [Double], _ q: Double) -> Double { let s = x.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        return String(format: "moves=%d errors=%d roomJumps=%d latencyUs p50=%.0f p99=%.0f max=%.0f | p50 bounds=%.0f move=%.0f order+reenable=%.0f | tx=%d orderOnMove=%d callbacks=%d onMain=%d",
                      a.count, errs, jumps, p(a, 0.5), p(a, 0.99), a.max() ?? 0, p(b, 0.5), p(m, 0.5), p(o, 0.5), tx ? 1 : 0, ord ? 1 : 0, cb, cbMain)
    }
}
