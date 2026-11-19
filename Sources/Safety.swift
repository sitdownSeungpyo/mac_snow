import AppKit
import Carbon
import os

/// Last-resort protections for a full-screen overlay app:
/// - ⌃⌥⌘Q emergency quit (Carbon hot key; works without Accessibility permission)
/// - launch sentinel (a run that never reached 10s of healthy operation => next launch is safe mode)
/// - background watchdog (main-thread stall, runaway scene metrics, --test-seconds auto quit)
enum Safety {
    // MARK: Launch options

    static let args = CommandLine.arguments
    static let safeFlag = args.contains("--safe")
    static let testSeconds: Double? = {
        guard let i = args.firstIndex(of: "--test-seconds"), i + 1 < args.count,
              let v = Double(args[i + 1]), v > 0 else { return nil }
        return v
    }()

    private static let sentinelKey = "launchSentinel"
    private static let stopReasonKey = "lastSafetyStop"

    /// Reads (and then arms) the crash/hang sentinel. Returns true if the previous run never
    /// finished 10s of healthy running (killed, hung, rebooted) or tripped a safety stop.
    static func armSentinel() -> Bool {
        let d = UserDefaults.standard
        let previousUnhealthy = d.bool(forKey: sentinelKey)
        d.set(true, forKey: sentinelKey)
        d.synchronize()
        return previousUnhealthy
    }

    static func clearSentinel() {
        UserDefaults.standard.set(false, forKey: sentinelKey)
        UserDefaults.standard.synchronize()
    }

    static var lastStopReason: String? { UserDefaults.standard.string(forKey: stopReasonKey) }

    private static func recordStop(_ reason: String) {
        let d = UserDefaults.standard
        d.set(reason, forKey: stopReasonKey)
        d.set(true, forKey: sentinelKey)   // next launch starts in safe mode
        d.synchronize()
        NSLog("WinterDesk safety stop: %@", reason)
    }

    // MARK: Emergency quit

    /// Main thread only: make every window of ours invisible and click-through, then exit now.
    static func emergencyQuit(reason: String, recordAsFailure: Bool = true) {
        if recordAsFailure { recordStop(reason) } else { clearSentinel() }
        for w in NSApp.windows {
            w.ignoresMouseEvents = true
            w.alphaValue = 0
            w.orderOut(nil)
        }
        exit(0)
    }

    private static let hotKeySignature = OSType(0x5744_5351)   // 'WDSQ'
    private static let quitHotKeyID: UInt32 = 1
    private static var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private static var hotKeyHandlers: [UInt32: () -> Void] = [:]

    /// Global hot key ids (all ⌃⌥⌘ except Esc).
    enum HotKey: UInt32 {
        case snow = 2, santa = 3, effects = 4, lightEdit = 5, escape = 6, plow = 7
    }

    /// Installs the Carbon handler and ⌃⌥⌘Q. Carbon hot keys need no Accessibility /
    /// Input Monitoring permission.
    static func installEmergencyHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            // Safety first: if the event cannot be read, treat it as the emergency quit.
            guard err == noErr else {
                Safety.emergencyQuit(reason: "emergency hot key ⌃⌥⌘Q (unreadable event)", recordAsFailure: false)
                return noErr
            }
            guard hk.signature == Safety.hotKeySignature else { return OSStatus(eventNotHandledErr) }
            if hk.id == Safety.quitHotKeyID {
                Safety.emergencyQuit(reason: "emergency hot key ⌃⌥⌘Q", recordAsFailure: false)
            } else {
                Safety.hotKeyHandlers[hk.id]?()   // unknown but readable ids are ignored
            }
            return noErr
        }, 1, &spec, nil, nil)
        register(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | optionKey | cmdKey), id: quitHotKeyID, name: "⌃⌥⌘Q")
    }

    /// Registers a ⌃⌥⌘ hot key (or, for `.escape`, plain Esc) that calls `handler` on the main thread.
    static func registerHotKey(_ key: HotKey, keyCode: Int, handler: @escaping () -> Void) {
        hotKeyHandlers[key.rawValue] = handler
        let mods = key == .escape ? UInt32(0) : UInt32(controlKey | optionKey | cmdKey)
        register(keyCode: UInt32(keyCode), modifiers: mods, id: key.rawValue, name: "\(key)")
    }

    /// Removes a hot key (used for the transient Esc key while Light Edit mode is on).
    static func unregisterHotKey(_ key: HotKey) {
        if let ref = hotKeyRefs.removeValue(forKey: key.rawValue) { UnregisterEventHotKey(ref) }
        hotKeyHandlers[key.rawValue] = nil
    }

    private static func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, name: String) {
        if let old = hotKeyRefs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: hotKeySignature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { hotKeyRefs[id] = ref } else { NSLog("WinterDesk: could not register hot key %@ (status %d)", name, status) }
    }

    // MARK: Watchdog

    /// Sane bounds for one overlay scene (normal operation measured offscreen: ~700 nodes,
    /// additive area ~0.12 x screen, largest additive sprite 46pt).
    static let maxSceneNodes = 6000
    static let maxAdditiveAreaScreens: CGFloat = 1.0
    static let maxAdditiveDimension: CGFloat = 256
    static let stallLimit: TimeInterval = 3

    private struct State {
        var lastTick: TimeInterval = ProcessInfo.processInfo.systemUptime
        var tripReason: String?
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static var timer: DispatchSourceTimer?
    private static let start = ProcessInfo.processInfo.systemUptime
    private static var sentinelCleared = false

    /// Main thread: heartbeat. `metricsProblem` is non-nil when a scene exceeded a bound.
    static func tick(metricsProblem: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock {
            $0.lastTick = now
            if let p = metricsProblem, $0.tripReason == nil { $0.tripReason = p }
        }
        if let p = metricsProblem {
            emergencyQuit(reason: p)
        }
        if !sentinelCleared && now - start >= 10 {
            sentinelCleared = true
            clearSentinel()
        }
    }

    static func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        t.schedule(deadline: .now() + 1, repeating: 0.5)
        var quitRequestedAt: TimeInterval?
        t.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            let last = state.withLock { $0.lastTick }
            if now - last > stallLimit {
                // The main thread is stuck, so AppKit cannot be used. Exiting tears down every
                // window we own inside WindowServer immediately.
                recordStop(String(format: "main thread stalled for %.1fs", now - last))
                _exit(3)
            }
            if let limit = testSeconds, now - start >= limit {
                if quitRequestedAt == nil {
                    quitRequestedAt = now
                    DispatchQueue.main.async { emergencyQuit(reason: "test-seconds elapsed", recordAsFailure: false) }
                } else if let q = quitRequestedAt, now - q > 1.5 {
                    _exit(0)
                }
            }
        }
        t.resume()
        timer = t
    }
}
