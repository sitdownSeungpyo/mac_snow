import AppKit
import IOKit.ps

/// Battery / Low Power Mode detection. `saving` is true on battery power or in Low Power Mode;
/// `onChange` fires on the main thread when it flips.
final class PowerMonitor {
    static let shared = PowerMonitor()
    private(set) var saving = false
    private(set) var reason = ""
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                               name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        if source == nil, let s = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { PowerMonitor.shared.evaluate() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            source = s
        }
        evaluate()
    }

    @objc private func changed() { DispatchQueue.main.async { self.evaluate() } }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    /// Pure decision (tested offscreen).
    static func decide(onBattery: Bool, lowPower: Bool) -> (Bool, String) {
        if lowPower { return (true, "lowPowerMode") }
        if onBattery { return (true, "battery") }
        return (false, "ac")
    }

    func evaluate() {
        let (s, r) = PowerMonitor.decide(onBattery: PowerMonitor.onBattery(), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard s != saving || r != reason else { return }
        saving = s
        reason = r
        Diag.shared.row("power", note: "saving=\(s ? 1 : 0) reason=\(r)")
        onChange?()
    }
}

/// Which screens are covered by a full-screen app (or any screen-sized normal-layer window of
/// another app): the effects pause there.
/// A boolean that flips only after `needed` consecutive readings of the other value (pure).
struct Debounced {
    private(set) var value: Bool
    let needed: Int
    private(set) var streak = 0
    init(_ value: Bool, needed: Int) { self.value = value; self.needed = needed }
    /// Feeds one reading; returns true when `value` flipped.
    mutating func feed(_ v: Bool) -> Bool {
        guard v != value else { streak = 0; return false }
        streak += 1
        guard streak >= needed else { return false }
        value = v; streak = 0
        return true
    }
}

enum FullscreenDetector {
    /// Screen frames in CG global coordinates (top-left origin).
    static func cgFrame(of screen: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: h - screen.maxY, width: screen.width, height: screen.height)
    }

    /// Pure: indices of `screensCG` fully covered by one of `windows` (CG bounds of layer-0
    /// windows of other apps), within 1pt.
    static func covered(screensCG: [CGRect], windows: [CGRect]) -> Set<Int> {
        var out = Set<Int>()
        for (i, s) in screensCG.enumerated() where windows.contains(where: {
            abs($0.minX - s.minX) <= 1 && abs($0.minY - s.minY) <= 1 && abs($0.width - s.width) <= 1 && abs($0.height - s.height) <= 1
        }) { out.insert(i) }
        return out
    }

    /// Covered screen indices right now (CGWindowList, on-screen windows only).
    static func coveredScreens(_ screens: [NSScreen]) -> Set<Int> {
        guard let primaryH = screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = getpid()
        let rects: [CGRect] = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d as CFDictionary) else { return nil }
            return r
        }
        return covered(screensCG: screens.map { cgFrame(of: $0.frame, primaryHeight: primaryH) }, windows: rects)
    }
}
