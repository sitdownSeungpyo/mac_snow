// capspike: ONE transparent "cap window" (a white snow line) ordered directly above a target app
// window and moved inside the SkyLight move-event callback (no redraw, no interpolation).
// Live feasibility spike for per-window cap windows. Safe by construction:
//   - exits by itself after --seconds (default 20, max 60); a background watchdog hard-exits 2s later
//   - ignores ALL mouse input (click-through), never activates, never takes key focus
//   - exits when the target window closes
// Usage: capspike [--window <id>] [--seconds N] [--dry-run]
//   without --window: the frontmost normal window of another app (CGWindowList order).
//   --dry-run: resolve the target + symbols, print the cap frame, create nothing, exit.
import AppKit
import Darwin
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Arguments
var targetArg: UInt32?
var seconds: Double = 20
var dryRun = false
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--window": targetArg = it.next().flatMap { UInt32($0) }
        case "--seconds": seconds = it.next().flatMap { Double($0) } ?? 20
        case "--dry-run": dryRun = true
        default:
            print("usage: capspike [--window <id>] [--seconds N (3–60)] [--dry-run]"); exit(2)
        }
    }
    seconds = min(max(seconds, 3), 60)
}

// MARK: SkyLight (dlsym; own declarations)
typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
func sym<T>(_ n: String, _ t: T.Type) -> T? { sl.flatMap { dlsym($0, n) }.map { unsafeBitCast($0, to: t) } }
let SLSMainConnectionID = sym("SLSMainConnectionID", (@convention(c) () -> Int32).self)
let SLSRegisterNotifyProc = sym("SLSRegisterNotifyProc", (@convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32).self)
let SLSRequestNotificationsForWindows = sym("SLSRequestNotificationsForWindows", (@convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32) -> Int32).self)
let SLSGetWindowBounds = sym("SLSGetWindowBounds", (@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32).self)
let SLSOrderWindow = sym("SLSOrderWindow", (@convention(c) (Int32, UInt32, Int32, UInt32) -> Int32).self)
let SLSMoveWindow = sym("SLSMoveWindow", (@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGPoint>) -> Int32).self)
let SLSDisableUpdate = sym("SLSDisableUpdate", (@convention(c) (Int32) -> Int32).self)
let SLSReenableUpdate = sym("SLSReenableUpdate", (@convention(c) (Int32) -> Int32).self)
let SLSGetWindowLevel = sym("SLSGetWindowLevel", (@convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32).self)
let kOrderAbove: Int32 = 1

let missing = [("SLSMainConnectionID", SLSMainConnectionID != nil), ("SLSRegisterNotifyProc", SLSRegisterNotifyProc != nil),
               ("SLSRequestNotificationsForWindows", SLSRequestNotificationsForWindows != nil), ("SLSGetWindowBounds", SLSGetWindowBounds != nil),
               ("SLSOrderWindow", SLSOrderWindow != nil), ("SLSMoveWindow", SLSMoveWindow != nil),
               ("SLSDisableUpdate", SLSDisableUpdate != nil), ("SLSReenableUpdate", SLSReenableUpdate != nil),
               ("SLSGetWindowLevel", SLSGetWindowLevel != nil)].filter { !$0.1 }.map { $0.0 }
guard missing.isEmpty, let mainCID = SLSMainConnectionID else { print("capspike: missing SkyLight symbols: \(missing)"); exit(1) }
let cid = mainCID()

// MARK: Target
func frontmostWindow() -> (UInt32, String)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let me = getpid()
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
              let n = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Double],
              (b["Width"] ?? 0) > 120, (b["Height"] ?? 0) > 80 else { continue }
        return (UInt32(n), (w[kCGWindowOwnerName as String] as? String) ?? "?")
    }
    return nil
}
guard let (target, owner) = targetArg.map({ ($0, "--window") }) ?? frontmostWindow() else { print("capspike: no target window"); exit(1) }
func targetBounds() -> CGRect? {
    var r = CGRect.zero
    guard SLSGetWindowBounds!(cid, target, &r) == 0, r.width > 0, r.height > 0 else { return nil }
    return r
}
guard let b0 = targetBounds() else { print("capspike: cannot read bounds of window \(target)"); exit(1) }
var targetLevel: Int32 = 0
_ = SLSGetWindowLevel!(cid, target, &targetLevel)
let primaryH = NSScreen.screens.first?.frame.height ?? 0
let cap0 = CapGeometry.capFrameCG(target: b0)
print(String(format: "capspike: target=%u (%@) bounds CG=(%.0f,%.0f %.0fx%.0f) level=%d | cap CG=(%.0f,%.0f %.0fx%.0f) | %.0fs",
             target, owner, b0.minX, b0.minY, b0.width, b0.height, targetLevel, cap0.minX, cap0.minY, cap0.width, cap0.height, seconds))
if dryRun { print("capspike: dry run, nothing created"); exit(0) }

// MARK: Safety: hard watchdog independent of the main thread
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: seconds + 2)
    print("capspike: watchdog exit"); exit(0)
}

// MARK: Cap window
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let panel = NSPanel(contentRect: CapGeometry.cocoa(fromCG: cap0, primaryHeight: primaryH),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.ignoresMouseEvents = true
panel.hidesOnDeactivate = false
panel.isReleasedWhenClosed = false
panel.level = NSWindow.Level(rawValue: Int(targetLevel))
panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary, .managed]
let view = NSView(frame: NSRect(origin: .zero, size: cap0.size))
view.wantsLayer = true
let line = CALayer()
line.backgroundColor = NSColor.white.cgColor
line.cornerRadius = 1.75
line.shadowColor = NSColor.black.cgColor
line.shadowOpacity = 0.25
line.shadowRadius = 1.5
line.shadowOffset = CGSize(width: 0, height: -1)
func layoutLine(width w: CGFloat) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    line.frame = CGRect(x: CapGeometry.side, y: CapGeometry.edgeY, width: w, height: 3.5)
    CATransaction.commit()
}
layoutLine(width: b0.width)
view.layer!.addSublayer(line)
panel.contentView = view
panel.orderFrontRegardless()
let capWid = UInt32(panel.windowNumber)
let orderErr = SLSOrderWindow!(cid, capWid, kOrderAbove, target)
print("capspike: cap window id=\(capWid) ordered above \(target): SLSOrderWindow=\(orderErr)")

// MARK: Moves inside the event callback
var latencies: [Double] = []      // µs from callback entry to move done
var moveErrors = 0, events = 0, reorders = 0
var lastWidth = b0.width
let lock = NSLock()
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1000 }
func follow() {
    let t0 = now()
    guard let b = targetBounds() else { return }
    var p = CapGeometry.capOriginCG(target: b)
    _ = SLSDisableUpdate!(cid)
    let e = SLSMoveWindow!(cid, capWid, &p)
    _ = SLSOrderWindow!(cid, capWid, kOrderAbove, target)
    _ = SLSReenableUpdate!(cid)
    let dt = now() - t0
    lock.lock(); events += 1; latencies.append(dt); if e != 0 { moveErrors += 1 }; lock.unlock()
    if abs(b.width - lastWidth) > 0.5 {
        lastWidth = b.width
        DispatchQueue.main.async {
            // Resize: new size (AppKit) + line width; origin stays where the move put it.
            let f = CapGeometry.cocoa(fromCG: CapGeometry.capFrameCG(target: b), primaryHeight: primaryH)
            panel.setFrame(f, display: false)
            layoutLine(width: b.width)
        }
    }
}
/// C callbacks cannot capture context: state reached through statics.
enum Bridge {
    static var target: UInt32 = 0
    static var onMove: (() -> Void)?
    static var onClose: (() -> Void)?
}
Bridge.target = target
Bridge.onMove = follow
Bridge.onClose = { DispatchQueue.main.async { print("capspike: target closed"); finish() } }
let callback: NotifyProc = { event, data, length, _ in
    guard let data, length >= MemoryLayout<UInt32>.size, data.load(as: UInt32.self) == Bridge.target else { return }
    if event == 804 { Bridge.onClose?(); return }
    Bridge.onMove?()
}
for e: UInt32 in [806, 807, 804] {
    let r = SLSRegisterNotifyProc!(callback, e, nil)
    if r != 0 { print("capspike: SLSRegisterNotifyProc(\(e))=\(r)") }
}
var subs = [target]
print("capspike: SLSRequestNotificationsForWindows=\(SLSRequestNotificationsForWindows!(cid, &subs, 1))")

// Re-order 4×/s (z-order changes of the target: clicks on other windows) and keep AppKit's cached
// frame in sync with where SkyLight moved the window.
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    _ = SLSOrderWindow!(cid, capWid, kOrderAbove, target)
    reorders += 1
    if let b = targetBounds() {
        let f = CapGeometry.cocoa(fromCG: CapGeometry.capFrameCG(target: b), primaryHeight: primaryH)
        if panel.frame != f { panel.setFrame(f, display: false); layoutLine(width: b.width) }
    }
}

func finish() {
    panel.orderOut(nil)
    lock.lock(); let l = latencies.sorted(); let n = events; let me = moveErrors; lock.unlock()
    if l.isEmpty {
        print("capspike: no move events received")
    } else {
        print(String(format: "capspike: events=%d moveErrors=%d reorders=%d | callback→moved latency µs: p50=%.0f p99=%.0f max=%.0f",
                     n, me, reorders, l[l.count / 2], l[Int(Double(l.count - 1) * 0.99)], l.last!))
    }
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
signal(SIGINT) { _ in exit(0) }
app.run()
