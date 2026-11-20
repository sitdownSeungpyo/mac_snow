import AppKit
import Carbon
import SpriteKit
import ServiceManagement

enum OverlayMode: Int {
    case desktop = 0
    case onTop = 1
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlays: [OverlayWindow] = []
    private var mouseTimer: Timer?
    private var dockTimer: Timer?
    private var windowTimer: Timer?
    private var lastWindowList: [AppWindow] = []
    // Live window tracking: window id -> hot until (uptime; .infinity while the button is held).
    private var mouseWasDown = false
    /// Window whose title bar was pressed; the first drag event while the button is held slides its snow off.
    private var pendingGrab: Int?
    /// Frames of excluded child/popup windows from the last poll (clicks there are never grabs).
    private var lastPopups: [CGRect] = []
    /// While a grab waits for confirmation, the window poll is forced (≤ every 50ms) for 0.3s.
    private var grabPollUntil: TimeInterval = 0
    private var lastForcedPoll: TimeInterval = 0
    static let titleBand: CGFloat = 40
    private var mouseMonitor: Any?
    /// ⌘Tab / ⌘` detection (only with Accessibility): key codes and the ⌘ flag only — never characters.
    private var keyMonitor: Any?
    private var switchGesture = SwitchGesture()
    private var lastAXCheck: TimeInterval = 0
    private var lastWindowChange: TimeInterval = 0
    private var lastWindowPoll: TimeInterval = 0
    private let defaults = UserDefaults.standard
    /// Falling snow on/off (persisted, toggled from the menu or ⌃⌥⌘S). Off = no emitter and no
    /// new accumulation; existing ground snow and caps stay.
    private var snowFalling: Bool {
        get { defaults.bool(forKey: "snowFalling") }
        set { defaults.set(newValue, forKey: "snowFalling") }
    }
    private var snowPaused: Bool { !snowFalling }
    private var toast: NSPanel?
    /// The starter gift is placed on every overlay (re)build until the user deletes/opens/clears it.
    private var starterGiftUsed = false
    // Gift persistence (main screen, screen-local positions).
    private static let savedGiftsKey = "savedGifts"
    private var lastSavedGifts: [WinterScene.SavedGift]?
    private var giftSaveCountdown = 0

    private var mainOverlay: OverlayWindow? { overlays.first { $0.scene.isMainScreen } }

    private func loadSavedGifts() -> [WinterScene.SavedGift] {
        guard let data = defaults.data(forKey: AppDelegate.savedGiftsKey),
              let list = try? JSONDecoder().decode([WinterScene.SavedGift].self, from: data) else { return [] }
        return list
    }

    /// Rounded copy used only to decide whether anything changed (ignores sub-pixel physics noise).
    private static func coarse(_ list: [WinterScene.SavedGift]?) -> [WinterScene.SavedGift]? {
        list?.map { WinterScene.SavedGift(x: ($0.x * 2).rounded() / 2, y: ($0.y * 2).rounded() / 2,
                                          variant: $0.variant, starter: $0.starter) }
    }

    private func writeGifts(_ list: [WinterScene.SavedGift]) {
        guard AppDelegate.coarse(list) != AppDelegate.coarse(lastSavedGifts),
              let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: AppDelegate.savedGiftsKey)
        lastSavedGifts = list
    }

    /// Saves the main scene's gifts if they changed (no-op without overlays, so a torn-down
    /// state never overwrites the saved gifts with an empty list).
    // MARK: Live window tracking state

    enum TrackingMode: String { case live = "실시간", fallback = "기본" }
    private(set) var trackingMode: TrackingMode = .fallback
    private var liveTrackingEnabled: Bool {
        get { defaults.bool(forKey: "liveWindowTracking") }
        set { defaults.set(newValue, forKey: "liveWindowTracking") }
    }
    /// Per-window / global live-tracking health (see LiveTrackingMonitor).
    private let liveMonitor = LiveTrackingMonitor()
    private var trackingFailure: String?
    private let offStateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// What is switched off right now (so an empty screen is never a mystery).
    private var offStateText: String? {
        var parts: [String] = []
        if !effectsOn { parts.append("효과 ⌃⌥⌘E") }
        if !snowFalling { parts.append("눈 내리기 ⌃⌥⌘S") }
        if !santaEnabled { parts.append("산타 ⌃⌥⌘D") }
        return parts.isEmpty ? nil : "꺼져 있음: " + parts.joined(separator: " · ")
    }
    private let trackingStatusItem = NSMenuItem(title: "창 추적: 기본", action: nil, keyEquivalent: "")
    private let liveTrackingItem = NSMenuItem(title: "실시간 창 추적 (실험적)", action: #selector(toggleLiveTracking), keyEquivalent: "")
    private let plowItem = NSMenuItem(title: "제설차   (⌃⌥⌘P)", action: #selector(togglePlow), keyEquivalent: "")
    /// Per-window cap windows (live mode): snow lines / riders / garlands glued to their window.
    private let capManager = CapWindowManager()
    private var dragSnowItems: [NSMenuItem] = []
    private let powerItem = NSMenuItem(title: "절전: 켜짐", action: nil, keyEquivalent: "")
    private var lastFullscreenCheck: TimeInterval = 0
    private var fullscreenState: [Int: Debounced] = [:]
    private var promptPollPending = false
    private var lastPollHeartbeat: TimeInterval = 0
    /// "창 끌 때 눈": true = 미끄러져 떨어짐 (default), false = 붙어 있음.
    private var dragSnowSlides: Bool {
        get { defaults.object(forKey: "dragSnowSlides") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dragSnowSlides") }
    }
    private var plowEnabled: Bool {
        get { defaults.bool(forKey: "snowplow") }
        set { defaults.set(newValue, forKey: "snowplow") }
    }
    private static let savedRidersKey = "savedRiders"
    private var pendingRiders: [WinterScene.SavedRider] = []
    private var ridersLoaded = false

    private func setTrackingMode(_ m: TrackingMode, reason: String) {
        if m != trackingMode { Diag.shared.row("trackingMode", note: "\(m.rawValue) \(reason)") }
        trackingMode = m
        trackingStatusItem.title = "창 추적: \(m.rawValue)" + (m == .fallback && trackingFailure != nil ? " (\(trackingFailure!))" : "")
        for w in overlays { w.scene.liveTracking = (m == .live) }
        if m != .live { capManager.removeAll(reason: "fallback") }
    }

    private func pushNonLive() {
        if let w = overlays.first, w.scene.nonLiveWindows != liveMonitor.nonLive {
            Diag.shared.row("nonLive", note: "\(w.scene.nonLiveWindows.sorted())→\(liveMonitor.nonLive.sorted())")
        }
        for w in overlays where w.scene.nonLiveWindows != liveMonitor.nonLive { w.scene.nonLiveWindows = liveMonitor.nonLive }
    }

    private func subscribeAll() {
        guard trackingMode == .live || liveMonitor.globalFallback else { return }
        // Every discovered window (including ones still in settle-in), full list every time.
        if let n = SkyLightEvents.shared.subscribe(lastWindowList.map { $0.id }) { Diag.shared.row("subscribed", note: "n=\(n)") }
    }

    /// Starts SkyLight notifications if enabled and available; otherwise stays in fallback.
    private func startLiveTracking() {
        guard liveTrackingEnabled else { trackingFailure = "꺼짐"; setTrackingMode(.fallback, reason: "disabled"); return }
        let sls = SkyLightEvents.shared
        guard sls.available, sls.start() else {
            trackingFailure = "사용 불가"
            setTrackingMode(.fallback, reason: sls.failure ?? "unavailable")
            return
        }
        sls.handler = { [weak self] event, wid in self?.windowEvent(event, wid) }
        trackingFailure = nil
        setTrackingMode(.live, reason: "SkyLight notifications registered")
        subscribeAll()
    }

    /// A SkyLight move/resize/close event (main thread): bounded work, update that window now.
    private func windowEvent(_ event: UInt32, _ wid: Int) {
        if event == SkyLightEvents.eventReorder { capManager.reorderEvent(); promptPoll(reason: "reorder"); return }   // z-order only
        let now = ProcessInfo.processInfo.systemUptime
        Diag.shared.row("slsEvent", id: wid, note: "type=\(event)")
        if event != SkyLightEvents.eventClose && liveTrackingEnabled {
            let wasNonLive = liveMonitor.nonLive.contains(wid)
            if liveMonitor.eventArrived(wid, now: now) {
                trackingFailure = nil
                setTrackingMode(.live, reason: "SkyLight events resumed")
            }
            if wasNonLive { pushNonLive() }
        } else if event == SkyLightEvents.eventClose {
            liveMonitor.forget(wid)
        }
        guard trackingMode == .live, let i = lastWindowList.firstIndex(where: { $0.id == wid }) else { return }
        if event == SkyLightEvents.eventClose { vanish(wid, reason: "close"); lastWindowPoll = 0; pollWindows(); return }
        guard let r = SkyLightEvents.shared.bounds(of: wid) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let f = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        guard f.minX.isFinite, f.minY.isFinite, f.width >= 1, f.height >= 1 else { return }
        // Minimize (genie) shrinks the window with no mouse button down: everything goes now.
        let prev = lastEventBounds[wid]
        lastEventBounds[wid] = (f, now)
        if let p = prev, WindowVanish.looksLikeMinimize(prev: p.frame, now: f, dt: now - p.t, mouseDown: NSEvent.pressedMouseButtons != 0) {
            vanish(wid, reason: String(format: "minimize-heuristic %.0fx%.0f→%.0fx%.0f in %.0fms", p.frame.width, p.frame.height, f.width, f.height, (now - p.t) * 1000))
            return
        }
        if overlays.contains(where: { $0.scene.vanishedWindows.contains(wid) }) { return }
        lastWindowList[i].frame = f
        lastWindowChange = now
        for o in overlays {
            let sf = o.hostScreen.frame
            guard f.intersects(sf) else { continue }
            o.scene.liveWindowFrame(wid, f.offsetBy(dx: -sf.minX, dy: -sf.minY))
        }
    }

    private var lastEventBounds: [Int: (frame: CGRect, t: TimeInterval)] = [:]

    /// Z-order changed (reorder event, app activation, a click): re-read the window list now and
    /// once more shortly after, so cap masks follow the new order within ~30ms instead of a poll.
    private func promptPoll(reason: String) {
        guard !promptPollPending else { return }
        promptPollPending = true
        Diag.shared.row("promptPoll", note: reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.promptPollPending = false
            self.lastWindowPoll = 0; self.pollWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.lastWindowPoll = 0; self?.pollWindows() }
        }
    }

    /// Installs the key monitor as soon as Accessibility is granted (no restart), removes it if revoked.
    private func updateKeyMonitor() {
        let trusted = AXIsProcessTrusted()
        if trusted && keyMonitor == nil && mouseMonitor != nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in self?.switchKey(e) }
            Diag.shared.row("switchGesture", note: "monitor installed (Accessibility granted)")
        } else if !trusted, let k = keyMonitor {
            NSEvent.removeMonitor(k); keyMonitor = nil
            Diag.shared.row("switchGesture", note: "monitor removed (Accessibility revoked)")
        }
        axItem.state = trusted ? .on : .off
    }

    /// ⌘Tab / ⌘⇧Tab / ⌘`: hide every cap the moment the gesture arms (WindowServer reorders on
    /// ⌘ up, before any notification); show them after a poll confirms the new order. Reads only
    /// `keyCode` and the ⌘ flag; no characters are read, logged or kept.
    private func switchKey(_ e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch e.type {
        case .keyDown:
            if switchGesture.keyDown(keyCode: e.keyCode, command: cmd) {
                capManager.setSwitchHidden(true, reason: "switch gesture armed")
                Diag.shared.row("switchGesture", note: "armed")
            }
        case .flagsChanged:
            if switchGesture.flagsChanged(command: cmd, now: ProcessInfo.processInfo.systemUptime) {
                Diag.shared.row("switchGesture", note: "released")
                promptPoll(reason: "switch released")
            }
        default:
            break
        }
    }

    @objc private func appActivated(_ n: Notification) {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        Diag.shared.row("appActivated", note: app?.bundleIdentifier ?? "?")
        if let pid = app?.processIdentifier { for o in overlays { o.scene.appActivated(pid: Int(pid)) } }
        promptPoll(reason: "app activated")
    }

    /// Our windows' visibility as WindowServer sees it (the ⌘Tab switcher, Spaces, Mission
    /// Control): logged for "Report a Glitch".
    @objc private func occlusionChanged(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        let kind = (w as? CapWindow).map { "cap \($0.world.target)" } ?? (w is OverlayWindow ? "overlay" : nil)
        guard let kind else { return }
        Diag.shared.row("occlusion", id: w.windowNumber, rect: w.frame,
                        note: "\(kind) visible=\(w.occlusionState.contains(.visible) ? 1 : 0) alpha=\(String(format: "%.2f", w.alphaValue)) opaque=\(w.isOpaque ? 1 : 0)")
    }

    /// Frontmost app as seen by the poll (independent of activation notifications).
    private var lastFrontPID: pid_t = 0

    /// "Report a Glitch" / ⌃⌥⌘G: writes the always-on event ring (cap show / hide / create /
    /// destroy / mask / frame changes, vanish, pause, hitches…) to ~/Library/Logs/WinterDesk.
    @objc private func reportGlitch() {
        let state = "windows=\(lastWindowList.count) caps=\(capManager.caps.count) mode=\(trackingMode.rawValue) paused=\(overlays.filter { $0.isPaused }.count) power=\(PowerMonitor.shared.saving ? 1 : 0)"
        if let p = Diag.shared.dumpRing(note: state) {
            showToast("🧾 기록 저장: " + (p as NSString).lastPathComponent, force: true)
        } else {
            showToast("기록을 저장하지 못했어요", force: true)
        }
    }

    /// A window is going away (minimize / app hide / close): its overlay content and cap window
    /// disappear immediately (riders are parked for its return).
    private func vanish(_ wid: Int, reason: String) {
        for o in overlays { o.scene.windowVanished(wid, reason: reason) }
        capManager.remove(wid, reason: "vanish")
        lastEventBounds[wid] = nil
    }

    @objc private func appHidden(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = Int(app.processIdentifier)
        for w in lastWindowList where w.pid == pid { vanish(w.id, reason: "app hidden") }
    }

    @objc private func toggleLiveTracking() {
        liveTrackingEnabled.toggle()
        if liveTrackingEnabled { startLiveTracking() } else { trackingFailure = "꺼짐"; setTrackingMode(.fallback, reason: "menu") }
    }

    @objc private func togglePlow() {
        plowEnabled.toggle()
        for w in overlays { w.scene.plowEnabled = plowEnabled }
        showToast(plowEnabled ? "🚜 제설차 켜짐" : "🚜 제설차 꺼짐")
    }

    private func loadSavedRiders() -> [WinterScene.SavedRider] {
        guard let data = defaults.data(forKey: AppDelegate.savedRidersKey),
              let list = try? JSONDecoder().decode([WinterScene.SavedRider].self, from: data) else { return [] }
        return list.map { var r = $0; r.windowID = nil; return r }      // window ids are per launch
    }

    private func saveRiders() {
        guard !overlays.isEmpty else { return }
        var all: [WinterScene.SavedRider] = []
        for w in overlays { all += w.scene.riderSnapshot() }
        all += pendingRiders
        if let data = try? JSONEncoder().encode(Array(all.prefix(24))) { defaults.set(data, forKey: AppDelegate.savedRidersKey) }
    }

    private func saveGiftsIfChanged() {
        guard let scene = mainOverlay?.scene else { return }
        writeGifts(scene.giftSnapshot())
    }

    // Safety
    /// Safe mode for this run: desktop level, window features off (not persisted).
    private var safeMode = false
    private var safeModeReason: String?
    private var safetyTimer: Timer?
    private var captureStuckSince: [ObjectIdentifier: TimeInterval] = [:]
    /// Overlays exist only while a display is active and the session is unlocked. An SKView
    /// created without an active display (e.g. launched while the screen slept / was locked)
    /// never gets a working display link, so overlays are torn down on sleep/lock and rebuilt
    /// fresh on wake/unlock.
    private var screensAsleep = false
    private var screenLocked = false
    private let safeNoticeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private let effectsItem = NSMenuItem(title: "Effects On   (⌃⌥⌘E)", action: #selector(toggleEffects), keyEquivalent: "")
    /// Master switch (persisted). Off = no overlays, no 60Hz/window/Dock timers; only the status
    /// item, hot keys and the 2Hz safety heartbeat remain.
    private var effectsOn: Bool {
        get { defaults.bool(forKey: "effectsOn") }
        set { defaults.set(newValue, forKey: "effectsOn") }
    }
    // Light Edit mode / user light links
    private let editLightsItem = NSMenuItem(title: "전구 연결하기…   (⌃⌥⌘L)", action: #selector(toggleLightEdit), keyEquivalent: "")
    private var coachPanel: CoachPanel?
    static let coachText = "창 위 금색 점을 끌어서 다른 창의 금색 점에 놓으면 전구가 연결돼요 · 전구 클릭 = 삭제 · Esc = 끝내기"
    private var linkModeItems: [NSMenuItem] = []
    private let garlandsItem = NSMenuItem(title: "Window Garlands", action: #selector(toggleGarlands), keyEquivalent: "")
    private var lightEditActive = false
    private var hintPanel: NSPanel?
    private var escMonitor: Any?
    private static let userLinksKey = "userLightLinks"
    /// Saved links not (yet) matched to open windows; kept in storage and retried on window changes.
    private var pendingLinks: [SavedLightLink] = []
    private var lightLinksAuto: Bool {
        get { defaults.bool(forKey: "lightLinksAuto") }
        set { defaults.set(newValue, forKey: "lightLinksAuto") }
    }
    private var windowGarlands: Bool {
        get { defaults.bool(forKey: "windowGarlands") }
        set { defaults.set(newValue, forKey: "windowGarlands") }
    }
    private let pauseItem = NSMenuItem(title: "Snow Falling   (⌃⌥⌘S)", action: #selector(togglePause), keyEquivalent: "")
    private var intensityItems: [NSMenuItem] = []
    private var modeItems: [NSMenuItem] = []
    private let addGiftItem = NSMenuItem(title: "Add Gift", action: #selector(addGift), keyEquivalent: "")
    private let santaItem = NSMenuItem(title: "Santa   (⌃⌥⌘D)", action: #selector(toggleSanta), keyEquivalent: "")
    private let axItem = NSMenuItem(title: "Grant Accessibility (Dock snow + no ⌘Tab flash)", action: #selector(grantAccessibility), keyEquivalent: "")
    private let windowSnowItem = NSMenuItem(title: "Snow on Windows", action: #selector(toggleWindowSnow), keyEquivalent: "")
    private let windowLightsItem = NSMenuItem(title: "Window Lights", action: #selector(toggleWindowLights), keyEquivalent: "")
    private var lightStyleItems: [NSMenuItem] = []
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private var intensity: Intensity {
        get { Intensity(rawValue: defaults.integer(forKey: "intensity")) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "intensity") }
    }

    private var mode: OverlayMode {
        get { safeMode ? .desktop : (OverlayMode(rawValue: defaults.integer(forKey: "overlayMode")) ?? .desktop) }
        set { defaults.set(newValue.rawValue, forKey: "overlayMode") }
    }

    private var windowSnow: Bool {
        get { defaults.bool(forKey: "windowSnow") }
        set { defaults.set(newValue, forKey: "windowSnow") }
    }

    private var windowLights: Bool {
        get { defaults.bool(forKey: "windowLights") }
        set { defaults.set(newValue, forKey: "windowLights") }
    }

    private var lightStyle: LightStyle {
        get { LightStyle(rawValue: defaults.integer(forKey: "lightStyle")) ?? .multicolor }
        set { defaults.set(newValue.rawValue, forKey: "lightStyle") }
    }

    /// Window snow and lights only make sense when the overlay is above app windows,
    /// and only after the user explicitly chose On Top (never in safe mode).
    private var windowFeaturesActive: Bool { mode == .onTop && !safeMode }

    private var santaEnabled: Bool {
        get { defaults.bool(forKey: "santa") }
        set { defaults.set(newValue, forKey: "santa") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0 != NSRunningApplication.current }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }
        defaults.register(defaults: ["intensity": Intensity.normal.rawValue, "overlayMode": OverlayMode.desktop.rawValue,
                                     "santa": true, "windowSnow": true, "windowLights": true,
                                     "lightStyle": LightStyle.multicolor.rawValue, "snowFalling": true, "effectsOn": true,
                                     "lightLinksAuto": true, "windowGarlands": true,
                                     "liveWindowTracking": true, "snowplow": true])
        // One-time migration: the build that defaulted to On Top froze a machine; everyone
        // goes back to Desktop once and must pick On Top explicitly.
        if !defaults.bool(forKey: "safetyMigrationV1") {
            defaults.set(OverlayMode.desktop.rawValue, forKey: "overlayMode")
            defaults.set(true, forKey: "safetyMigrationV1")
        }

        // Safety first: the hot key and watchdog work even if everything below misbehaves.
        Safety.installEmergencyHotKey()
        Safety.registerHotKey(.snow, keyCode: kVK_ANSI_S) { [weak self] in self?.togglePause() }
        Safety.registerHotKey(.santa, keyCode: kVK_ANSI_D) { [weak self] in self?.toggleSanta() }
        Safety.registerHotKey(.effects, keyCode: kVK_ANSI_E) { [weak self] in self?.toggleEffects() }
        Safety.registerHotKey(.lightEdit, keyCode: kVK_ANSI_L) { [weak self] in self?.toggleLightEdit() }
        Safety.registerHotKey(.plow, keyCode: kVK_ANSI_P) { [weak self] in self?.togglePlow() }
        Safety.registerHotKey(.glitch, keyCode: kVK_ANSI_G) { [weak self] in self?.reportGlitch() }
        Safety.startWatchdog()
        let previousRunUnhealthy = Safety.armSentinel()
        if NSEvent.modifierFlags.contains(.shift) {
            safeMode = true
            safeModeReason = "Safe mode (Shift held at launch)"
        } else if Safety.safeFlag {
            safeMode = true
            safeModeReason = "Safe mode (--safe)"
        } else if previousRunUnhealthy {
            safeMode = true
            let why = Safety.lastStopReason.map { ": \($0)" } ?? ""
            safeModeReason = "Safe mode — last run did not finish starting cleanly\(why)"
        }

        LoginItem.migrateDefaultOn(defaults: defaults)
        LoginItem.syncAtLaunch(defaults: defaults)      // installed copy only; background queue
        screenLocked = AppDelegate.sessionIsLocked()
        setupStatusItem()
        rebuildOverlays()

        let st = Timer(timeInterval: 0.5, target: self, selector: #selector(safetyTick), userInfo: nil, repeats: true)
        RunLoop.main.add(st, forMode: .common)
        safetyTimer = st

        if effectsOn { startEffectTimers() }
        startLiveTracking()
        PowerMonitor.shared.onChange = { [weak self] in self?.applyPower() }
        PowerMonitor.shared.start()
        applyPower()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appHidden(_:)),
                                                          name: NSWorkspace.didHideApplicationNotification, object: nil)
        if offStateText != nil {
            // One hint at start-up if something was left switched off by an earlier hotkey.
            let msg = !effectsOn ? "✨ 효과가 꺼져 있어요 · ⌃⌥⌘E로 켜기"
                : (!snowFalling ? "❄️ 눈 내리기가 꺼져 있어요 · ⌃⌥⌘S로 켜기" : "🎅 산타가 꺼져 있어요 · ⌃⌥⌘D로 켜기")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showToast(msg, force: true) }
        }
        updateStatusIcon()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        // Running non-pinned apps widen the Dock: re-estimate its frame when apps launch / quit.
        ws.addObserver(self, selector: #selector(runningAppsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(runningAppsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if !DockLocator.isTrusted && !defaults.bool(forKey: "axSwitchHintShown") {
            defaults.set(true, forKey: "axSwitchHintShown")    // once; never prompts by itself
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.showToast("손쉬운 사용 권한을 허용하면 Dock 위 눈이 정확해지고 ⌘Tab 때 깜빡임이 사라져요 (메뉴 ❄️)")
            }
        }
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenDidLock), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenDidUnlock), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    private func startEffectTimers() {
        guard mouseTimer == nil else { return }
        // Global mouse monitor (mouse events need no Accessibility permission; verified live:
        // events arrive with AXIsProcessTrusted=false). Used only to detect a title-bar grab so the
        // snow can slide off the moment the drag starts; the 10Hz poll catches every other move.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] e in
            self?.globalMouse(e)
        }
        updateKeyMonitor()
        logDiagStart()
        let mt = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(pollMouse), userInfo: nil, repeats: true)
        RunLoop.main.add(mt, forMode: .common)
        mouseTimer = mt
        let dt = Timer(timeInterval: 2.0, target: self, selector: #selector(refreshDock), userInfo: nil, repeats: true)
        RunLoop.main.add(dt, forMode: .common)
        dockTimer = dt
        let wt = Timer(timeInterval: 1.0 / 10.0, target: self, selector: #selector(pollWindows), userInfo: nil, repeats: true)
        RunLoop.main.add(wt, forMode: .common)
        windowTimer = wt
    }

    private func stopEffectTimers() {
        mouseTimer?.invalidate(); mouseTimer = nil
        dockTimer?.invalidate(); dockTimer = nil
        windowTimer?.invalidate(); windowTimer = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        if switchGesture.hiding { switchGesture = SwitchGesture(); capManager.setSwitchHidden(false, reason: "effects stopped") }
        lastWindowList = []
        pendingGrab = nil
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.appearsDisabled = !effectsOn
        button.alphaValue = effectsOn ? 1 : 0.4
        button.toolTip = effectsOn ? "WinterDesk" : "WinterDesk (effects off — ⌃⌥⌘E)"
    }

    @objc private func toggleEffects() {
        effectsOn.toggle()
        if effectsOn {
            startEffectTimers()
            rebuildOverlays()
        } else {
            tearDownOverlays()   // saves gifts first, closes overlays and the customize panel
            stopEffectTimers()
        }
        updateStatusIcon()
        showToast(effectsOn ? "✨ 효과 켜짐" : "✨ 효과 꺼짐", force: true)
    }

    private func logDiagStart() {
        guard Diag.shared.enabled else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        var refresh = 0.0
        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) { refresh = mode.refreshRate }
        let fps = (mainOverlay?.contentView as? SKView)?.preferredFramesPerSecond ?? -1
        Diag.shared.row("info", note: "AXIsProcessTrusted=\(AXIsProcessTrusted()) globalMonitorInstalled=\(mouseMonitor != nil) "
                        + "maximumFramesPerSecond=\(screen?.maximumFramesPerSecond ?? -1) skviewPreferredFPS=\(fps) "
                        + "displayModeRefreshHz=\(refresh) path=\(Diag.shared.path ?? "")")
        // Dock-owned windows (what macOS exposes without Accessibility), once.
        let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        for i in infos where (i[kCGWindowOwnerName as String] as? String) == "Dock" {
            let b = (i[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            Diag.shared.row("dockWindow", id: (i[kCGWindowNumber as String] as? Int) ?? 0, rect: b,
                            note: "layer=\(i[kCGWindowLayer as String] ?? "?") onscreen=\(i[kCGWindowIsOnscreen as String] ?? 0)")
        }
        if let main = NSScreen.screens.first {
            let band = DockLocator.band(screenFrame: main.frame, visibleFrame: main.visibleFrame, axFrame: DockLocator.axDockFrame())
            Diag.shared.row("dockBand", note: band.map { String(format: "minX=%.0f maxX=%.0f top=%.0f corner=%.0f ax=%@", $0.minX, $0.maxX, $0.top, $0.corner, "\(DockLocator.isTrusted)") } ?? "none")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveRiders()
        Diag.shared.flush(force: true)
        saveGiftsIfChanged()
        Safety.clearSentinel()
    }

    // MARK: Display / lock lifecycle

    static func activeDisplayCount() -> UInt32 {
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &n) == .success else { return 0 }
        return n
    }

    static func sessionIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? Int) ?? 0 != 0)
    }

    /// Overlays may only exist while a display is awake and drawable and the screen is unlocked.
    private var canShowOverlays: Bool {
        effectsOn && !screensAsleep && !screenLocked && AppDelegate.activeDisplayCount() > 0 && !NSScreen.screens.isEmpty
    }

    private func tearDownOverlays() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rebuildOverlays), object: nil)
        exitLightEdit(silent: true)
        saveGiftsIfChanged()
        saveRiders()
        CustomizePanel.shared.dismiss()
        capManager.removeAll(reason: "teardown")       // cap windows first (their nodes return to the overlays)
        for w in overlays {
            w.ignoresMouseEvents = true
            w.orderOut(nil)
            w.close()
        }
        overlays.removeAll()
        captureStuckSince.removeAll()
    }

    private func scheduleRebuild(after delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rebuildOverlays), object: nil)
        perform(#selector(rebuildOverlays), with: nil, afterDelay: delay)
    }

    @objc private func runningAppsChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshDock), object: nil)
        perform(#selector(refreshDock), with: nil, afterDelay: 0.6)
    }

    @objc private func screensSlept() { screensAsleep = true; tearDownOverlays() }
    @objc private func screensWoke() { screensAsleep = false; scheduleRebuild(after: 1.0) }
    @objc private func sessionResigned() { tearDownOverlays() }
    @objc private func sessionBecameActive() { scheduleRebuild(after: 1.0) }
    @objc private func screenDidLock() { screenLocked = true; exitLightEdit(silent: true); tearDownOverlays() }
    @objc private func screenDidUnlock() { screenLocked = false; scheduleRebuild(after: 1.0) }

    // MARK: Overlays

    @objc private func screensChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rebuildOverlays), object: nil)
        perform(#selector(rebuildOverlays), with: nil, afterDelay: 0.5)
    }

    @objc private func rebuildOverlays() {
        tearDownOverlays()
        screenLocked = AppDelegate.sessionIsLocked()
        guard canShowOverlays else {
            guard effectsOn else { return }   // switched off: stay torn down, no retries
            // No drawable display yet (asleep / locked / headless): try again later instead of
            // creating an overlay whose renderer can never attach to a display.
            scheduleRebuild(after: screensAsleep || screenLocked ? 5.0 : 2.0)
            return
        }
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = OverlayWindow(screen: screen, isMain: i == 0)
            w.scene.intensity = intensity
            w.scene.snowPaused = snowPaused
            w.scene.santaEnabled = santaEnabled
            w.scene.lightStyle = lightStyle
            w.scene.liveTracking = trackingMode == .live
            w.scene.nonLiveWindows = liveMonitor.nonLive
            w.scene.plowEnabled = plowEnabled
            w.scene.autoLightLinks = lightLinksAuto
            w.scene.windowGarlands = windowGarlands
            w.scene.dragSnowSlides = dragSnowSlides
            w.scene.onRidersParked = { [weak self] r in self?.pendingRiders += r }
            w.scene.powerSaver = PowerMonitor.shared.saving
            if PowerMonitor.shared.saving { (w.contentView as? SKView)?.preferredFramesPerSecond = 30 }
            w.scene.onUserLinksChanged = { [weak self] in self?.userLinksChanged() }
            w.scene.onLinkResult = { [weak self] r in self?.linkResult(r) }
            overlays.append(w)
        }
        applyMode()
        refreshDock()
        pendingLinks = loadSavedLinks()   // resolved against windows by pollWindows
        if !ridersLoaded {
            ridersLoaded = true
            pendingRiders = loadSavedRiders()
            // Nothing saved yet: one small snowman goes on the front window after settle-in.
            if pendingRiders.isEmpty { mainOverlay?.scene.wantsDefaultSnowman = true }
        }
        if let main = mainOverlay {
            main.scene.onStarterGiftGone = { [weak self] in self?.starterGiftUsed = true }
            let saved = loadSavedGifts()
            lastSavedGifts = saved
            let hadStarter = main.scene.restoreGifts(saved)
            // One starter gift unless one was saved, or the user removed it this session.
            if !hadStarter && !starterGiftUsed { main.scene.placeStarterGift() }
        }
        for w in overlays { w.orderInRevealing("start") }
        lastFullscreenCheck = 0
        checkFullscreen()
    }

    // MARK: Battery / full-screen pause

    private func applyPower() {
        let saving = PowerMonitor.shared.saving
        for w in overlays {
            w.scene.powerSaver = saving
            (w.contentView as? SKView)?.preferredFramesPerSecond = saving ? 30 : min(120, max(60, w.hostScreen.maximumFramesPerSecond))
        }
        capManager.frameRate = saving ? 30 : 60
        powerItem.isHidden = !saving
    }

    /// Pauses (hides, stops rendering) the overlay and cap windows of each screen a full-screen
    /// app covers; resumes when it is gone. Cheap: one CGWindowList read, at most 1Hz from the poll.
    @objc private func checkFullscreen() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFullscreenCheck >= 0.9 || lastFullscreenCheck == 0 else { return }
        lastFullscreenCheck = now
        guard !overlays.isEmpty else { return }
        let covered = FullscreenDetector.coveredScreens(overlays.map { $0.hostScreen })
        for (i, w) in overlays.enumerated() {
            // Two consecutive readings (the second ~0.3s later) before pausing or resuming: a
            // Space / Mission Control animation frame never blinks everything off and on.
            var d = fullscreenState[i] ?? Debounced(w.isPaused, needed: 2)
            if d.value != w.isPaused { d = Debounced(w.isPaused, needed: 2) }
            let flipped = d.feed(covered.contains(i))
            if d.streak > 0 { lastFullscreenCheck = now - 0.6 }
            fullscreenState[i] = d
            guard flipped else { continue }
            let pause = d.value
            guard pause != w.isPaused else { continue }
            if pause { capManager.setHidden(true, for: w) }
            w.setPaused(pause)
            if !pause { capManager.setHidden(false, for: w) }
            Diag.shared.row(pause ? "pause" : "resume", note: "screen=\(i) reason=\(pause ? "fullscreen" : "uncovered")")
        }
    }

    @objc private func activeSpaceChanged() {
        lastFullscreenCheck = 0
        // The Space switch animation settles first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.lastFullscreenCheck = 0; self?.checkFullscreen() }
    }

    @objc private func setDragSnow(_ sender: NSMenuItem) {
        dragSnowSlides = sender.tag == 1
        for w in overlays { w.scene.dragSnowSlides = dragSnowSlides }
    }

    private func applyWindowFeatures() {
        for w in overlays {
            w.scene.windowSnowEnabled = windowSnow && windowFeaturesActive
            w.scene.windowLightsEnabled = windowLights && windowFeaturesActive
            w.scene.lightStyle = lightStyle
        }
        lastWindowPoll = 0
        pollWindows()
    }

    /// Tracks app windows for snow caps and string lights: 10Hz while windows are moving,
    /// 4Hz when everything has been still for a moment (CGWindowList calls are not free).
    @objc private func pollWindows() {
        let now = ProcessInfo.processInfo.systemUptime
        let idle = now - lastWindowChange > 1.5
        if idle && now - lastWindowPoll < 0.24 { return }
        lastWindowPoll = now
        let wanted = windowFeaturesActive && (windowSnow || windowLights) && !overlays.isEmpty
        let own = Set(NSApp.windows.map { $0.windowNumber })
        checkFullscreen()
        if !overlays.isEmpty && overlays.allSatisfy({ $0.isPaused }) { return }     // full screen everywhere: nothing to track
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != lastFrontPID {
            lastFrontPID = front.processIdentifier
            Diag.shared.row("frontApp", note: "\(front.bundleIdentifier ?? "?") pid=\(front.processIdentifier)")
        }
        let snap = wanted ? WindowTracker.snapshotWithPopups(ownWindows: own) : (windows: [AppWindow](), popups: [CGRect](), popupRanks: [Int]())
        let all = snap.windows
        lastPopups = snap.popups
        if all != lastWindowList {
            let old = Dictionary(lastWindowList.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
            for w in all {
                guard let o = old[w.id], WinterScene.topEdgeMoved(o, w.frame) else { continue }
                Diag.shared.row("fullPoll", id: w.id, rect: w.frame, note: "moved")
                // Live mode: a settled window's real move (≥3pt) must also come as an event within 2s.
                let settled = overlays.contains { $0.scene.isDecorated(w.id) }
                liveMonitor.pollMove(w.id, distance: hypot(w.frame.minX - o.minX, w.frame.maxY - o.maxY), settled: settled, now: now)
            }
            for id in old.keys where !all.contains(where: { $0.id == id }) { liveMonitor.forget(id) }
            lastWindowList = all
            subscribeAll()
            lastWindowChange = now
        }
        for w in overlays {
            let sf = w.hostScreen.frame
            let pops = zip(lastPopups, snap.popupRanks).filter { $0.0.intersects(sf) }
            w.scene.occluderPopups = pops.map { $0.0.offsetBy(dx: -sf.minX, dy: -sf.minY) }
            w.scene.occluderPopupRanks = pops.map { $0.1 }
            w.scene.setAppWindows(WindowTracker.local(all, in: w.hostScreen.frame))
        }
        capManager.reconcile(overlays: overlays, windows: all,
                             enabled: wanted && trackingMode == .live && effectsOn && defaults.object(forKey: "capWindows") as? Bool ?? true)
        if now - lastPollHeartbeat >= 10 {
            // Heartbeat: an absent row in a live diag means the poll itself stopped.
            lastPollHeartbeat = now
            Diag.shared.row("pollAlive", note: "windows=\(all.count) caps=\(capManager.caps.count) slsEvents=\(SkyLightEvents.shared.eventCount) mode=\(trackingMode.rawValue) paused=\(overlays.filter { $0.isPaused }.count)")
        }
        if switchGesture.polled(now: now) { capManager.setSwitchHidden(false, reason: "switch confirmed by poll") }
        resolvePendingLinks()
        if !pendingRiders.isEmpty, let main = mainOverlay {
            pendingRiders = main.scene.restoreRiders(pendingRiders)
        }
    }

    private func applyMode() {
        let level: NSWindow.Level = mode == .desktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
        for w in overlays { w.level = level }
        applyWindowFeatures()
    }

    @objc private func refreshDock() {
        DockLocator.reloadPrefs()
        let ax = DockLocator.axDockFrame()
        for w in overlays {
            w.scene.setDock(DockLocator.band(screenFrame: w.hostScreen.frame,
                                             visibleFrame: w.hostScreen.visibleFrame, axFrame: ax))
        }
    }

    /// Click-through: capture the mouse only over interactive objects, or during a drag
    /// (a capture with no mouse button held for 5s is considered stuck and released).
    @objc private func pollMouse() {
        if !overlays.isEmpty && overlays.allSatisfy({ $0.isPaused }) { return }     // paused for a full-screen app
        let m = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons != 0
        let now = ProcessInfo.processInfo.systemUptime
        if let c = coachPanel {
            let over = c.buttonScreenRect.insetBy(dx: -2, dy: -2).contains(m)
            if c.ignoresMouseEvents == over { c.ignoresMouseEvents = !over }   // only the button takes clicks
        }
        if buttonDown != mouseWasDown {
            Diag.shared.row("pollDetectedButton", note: buttonDown ? "down" : "up")
            mouseWasDown = buttonDown
            if !buttonDown { pendingGrab = nil }
        }
        for w in overlays where !w.isPaused {
            let f = w.frame
            let inside = f.contains(m)
            let local = CGPoint(x: m.x - f.minX, y: m.y - f.minY)
            let key = ObjectIdentifier(w)
            if w.scene.isCapturingMouse && !buttonDown {
                let since = captureStuckSince[key] ?? now
                captureStuckSince[key] = since
                if now - since > 5 {
                    w.scene.cancelCapture()
                    captureStuckSince[key] = nil
                    Diag.shared.row("capture", note: "release reason=stuck(no button 5s)")
                }
            } else {
                captureStuckSince[key] = nil
            }
            w.scene.updateHover(inside ? local : nil)
            let dragging = w.scene.isCapturingMouse && buttonDown
            let target = inside ? w.scene.mouseTarget(at: local) : nil
            // While a button is held for something that isn't ours (e.g. a window being dragged by
            // its title bar under a rider), never start capturing mid-press: the press, its drags and
            // its release stay with the app that got the mouse-down.
            let want: Bool
            if dragging { want = true }
            else if buttonDown { want = !w.ignoresMouseEvents && target != nil }
            else { want = target != nil }
            if w.ignoresMouseEvents == want {
                w.ignoresMouseEvents = !want
                let reason = dragging ? "drag" : (want ? (target ?? "?") : (buttonDown ? "press-elsewhere" : "nothing-under-mouse"))
                Diag.shared.row("capture", rect: CGRect(x: m.x, y: m.y, width: 0, height: 0),
                                note: "\(want ? "on" : "off") reason=\(reason) button=\(buttonDown ? 1 : 0)")
            }
        }
    }

    // MARK: Light Edit mode

    private var lightEditAllowed: String? {
        if !effectsOn { return "효과가 꺼져 있어요 (⌃⌥⌘E)" }
        if screenLocked || screensAsleep { return nil }
        if safeMode { return "안전 모드에서는 전구 편집을 할 수 없어요" }
        if !windowFeaturesActive { return "전구 연결은 On Top 모드에서만 돼요" }
        if !windowLights { return "Window Lights를 먼저 켜 주세요" }
        if overlays.isEmpty { return "" }
        return nil
    }

    @objc private func toggleLightEdit() {
        if lightEditActive { exitLightEdit(silent: false); return }
        if screenLocked || screensAsleep { return }       // ignored entirely while locked
        if !effectsOn { showToast("효과가 꺼져 있어요 (⌃⌥⌘E)"); return }
        if safeMode { showToast("안전 모드에서는 전구 연결을 할 수 없어요"); return }
        if !windowFeaturesActive || !windowLights {
            // Turn on what linking needs instead of silently doing nothing.
            if mode != .onTop { mode = .onTop }
            windowLights = true
            applyMode()                       // also polls the windows right away
            showToast("전구 연결을 위해 On Top 모드와 Window Lights를 켰어요")
        }
        if let why = lightEditAllowed { if !why.isEmpty { showToast(why) }; return }
        lightEditActive = true
        for w in overlays { w.scene.lightEditMode = true }
        Safety.registerHotKey(.escape, keyCode: kVK_Escape) { [weak self] in self?.exitLightEdit(silent: false) }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == UInt16(kVK_Escape), self?.lightEditActive == true { self?.exitLightEdit(silent: false); return nil }
            return e
        }
        let eligible = overlays.reduce(0) { $0 + $1.scene.eligibleWindowCount }
        if eligible < 2 { showToast("연결하려면 창이 2개 이상 보여야 해요") }
        showCoach()
    }

    /// Coach mark with an animated how-to; click-through except its "알겠어요" button. It turns
    /// into the small hint label when dismissed or after 8s.
    private func showCoach() {
        coachPanel?.shutDown()
        coachPanel = CoachPanel(text: AppDelegate.coachText) { [weak self] in self?.dismissCoach() }
        coachPanel?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.dismissCoach() }
    }

    private func dismissCoach() {
        guard let c = coachPanel else { return }
        coachPanel = nil
        c.shutDown()
        if lightEditActive { showHint("금색 점 → 다른 창의 금색 점으로 드래그 · 전구 클릭 = 삭제 · Esc = 끝내기") }
    }

    /// Leaves Light Edit mode on every path (Esc, ⌃⌥⌘L, timeout, effects off, lock, teardown):
    /// cancels any link drag (releasing the mouse capture) and removes the Esc hot key.
    private func exitLightEdit(silent: Bool) {
        guard lightEditActive else { return }
        lightEditActive = false
        for w in overlays {
            w.scene.lightEditMode = false     // also cancels a drag in progress
            w.scene.cancelCapture()
            w.ignoresMouseEvents = true
        }
        Safety.unregisterHotKey(.escape)
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        hintPanel?.orderOut(nil)
        hintPanel?.close()
        hintPanel = nil
        coachPanel?.shutDown()
        coachPanel = nil
        if !silent { showToast("💡 전구 연결 끝") }
    }

    private func showHint(_ text: String) {
        hintPanel?.orderOut(nil); hintPanel?.close()
        hintPanel = makeLabelPanel(text, size: 13, yFromTop: 70)
        hintPanel?.orderFrontRegardless()
    }

    private func linkResult(_ r: LinkResult?) {
        switch r {
        case .added?: showToast("💡 전구 연결됨")
        case .sameWindow?: showToast("같은 창끼리는 연결할 수 없어요")
        case .duplicate?: showToast("이미 연결된 전구예요")
        case .covered?: showToast("가려진 지점에는 연결할 수 없어요")
        case .full?: showToast("전구 줄은 최대 \(LightLinkStore.maxLinks)개까지예요")
        case .invalid?: showToast("연결할 수 없어요")
        case nil: break
        }
    }

    private func loadSavedLinks() -> [SavedLightLink] {
        guard let data = defaults.data(forKey: AppDelegate.userLinksKey),
              let list = try? JSONDecoder().decode([SavedLightLink].self, from: data) else { return [] }
        return list
    }

    private func saveLinks() {
        var all: [SavedLightLink] = []
        for w in overlays { all += LightLinkStore.save(w.scene.userLinks, windows: w.scene.currentWindows) }
        for p in pendingLinks where !all.contains(p) { all.append(p) }
        if let data = try? JSONEncoder().encode(Array(all.prefix(LightLinkStore.maxLinks))) {
            defaults.set(data, forKey: AppDelegate.userLinksKey)
        }
    }

    private var restoringLinks = false

    private func userLinksChanged() {
        guard !restoringLinks else { return }
        let total = overlays.reduce(0) { $0 + $1.scene.userLinks.count }
        // One-time: the first user link switches automatic window-pair strands off.
        if total > 0 && !defaults.bool(forKey: "manualAfterFirstLinkDone") {
            defaults.set(true, forKey: "manualAfterFirstLinkDone")
            lightLinksAuto = false
            for w in overlays { w.scene.autoLightLinks = false }
        }
        saveLinks()
    }

    /// Matches saved links to the open windows (owner app + index); unmatched ones stay pending.
    private func resolvePendingLinks() {
        guard !pendingLinks.isEmpty, !lastWindowList.isEmpty else { return }
        restoringLinks = true
        defer { restoringLinks = false }
        var remaining = pendingLinks
        for w in overlays {
            let r = LightLinkStore.resolve(remaining, windows: w.scene.currentWindows)
            w.scene.restoreUserLinks(r.links)
            remaining = r.unresolved
        }
        pendingLinks = remaining
    }

    @objc private func setLinkMode(_ sender: NSMenuItem) {
        lightLinksAuto = sender.tag == 1
        defaults.set(true, forKey: "manualAfterFirstLinkDone")   // an explicit choice wins
        for w in overlays { w.scene.autoLightLinks = lightLinksAuto }
    }

    @objc private func toggleGarlands() {
        windowGarlands.toggle()
        for w in overlays { w.scene.windowGarlands = windowGarlands }
    }

    /// Global mouse events: a press in a window's title band arms a grab; the first drag while
    /// held tells the scenes to slide that window's snow off (direction = drag direction).
    private func globalMouse(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            Diag.shared.row("globalMouseDown")
            let m = NSEvent.mouseLocation
            pendingGrab = nil
            // A press our overlay handles (a rider on a title bar, a gift, Santa…) never arms a
            // window grab / slide-off (global monitors normally don't see our own clicks; this also
            // covers a capture switching on right around the press).
            if let o = overlays.first(where: { $0.frame.contains(m) }),
               o.scene.isCapturingMouse || (!o.ignoresMouseEvents && o.scene.wantsMouse(at: CGPoint(x: m.x - o.frame.minX, y: m.y - o.frame.minY))) {
                Diag.shared.row("grabSkipped", note: "press handled by overlay")
                return
            }
            // The clicked window comes to the front: masks treat it as front-most right away.
            if let top = lastWindowList.sorted(by: { $0.order < $1.order }).first(where: { $0.frame.contains(m) }),
               !lastPopups.contains(where: { $0.contains(m) }) {
                for o in overlays { o.scene.windowRaised(top.id) }
                promptPoll(reason: "click")
            }
            // Never arm on a popup (e.g. Chrome's omnibox list) or a window not yet decorated.
            guard windowFeaturesActive, windowSnow || windowLights,
                  let id = WindowTracker.grabTarget(at: m, windows: lastWindowList, popups: lastPopups, band: AppDelegate.titleBand),
                  overlays.contains(where: { $0.scene.isDecorated(id) }) else { return }
            pendingGrab = id
        case .leftMouseDragged:
            Diag.shared.row("globalDragged")
            forceGrabPoll()
            guard let id = pendingGrab, e.deltaX != 0 || e.deltaY != 0 else { return }
            pendingGrab = nil
            let dir = CGVector(dx: e.deltaX, dy: -e.deltaY)      // event deltas are y-down
            Diag.shared.row("grab", id: id, note: String(format: "dx=%.1f dy=%.1f (awaiting top-edge move)", dir.dx, dir.dy))
            // Only a recorded intent: the slide-off happens when a poll confirms the top edge moved.
            for o in overlays { o.scene.windowGrabbed(id, direction: dir) }
            grabPollUntil = ProcessInfo.processInfo.systemUptime + 0.3
            forceGrabPoll()
        default:
            Diag.shared.row("globalMouseUp")
            pendingGrab = nil
        }
    }

    /// Polls the window list right away while a grab awaits confirmation (rate-limited to 20Hz).
    private func forceGrabPoll() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now < grabPollUntil, now - lastForcedPoll >= 0.05 else { return }
        lastForcedPoll = now
        lastWindowPoll = 0
        pollWindows()
    }

    /// 2Hz: enforce scene invariants, keep overlays transparent, feed the watchdog.
    @objc private func safetyTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAXCheck >= 3 { lastAXCheck = now; updateKeyMonitor() }      // permission granted / revoked at runtime
        if switchGesture.expire(now: now, commandDown: NSEvent.modifierFlags.contains(.command)) {
            capManager.setSwitchHidden(false, reason: "switch gesture expired")
        }
        var problem: String?
        if capManager.enforce() { NSLog("WinterDesk: a cap window was repaired (transparency / click-through)") }
        for w in overlays {
            if w.ensureTransparent() { NSLog("WinterDesk: overlay transparency was lost and has been restored") }
            let m = w.scene.enforceInvariants()
            let screenArea = max(w.frame.width * w.frame.height, 1)
            if m.nodes > Safety.maxSceneNodes {
                problem = "scene node count \(m.nodes) > \(Safety.maxSceneNodes)"
            } else if m.additiveArea / screenArea > Safety.maxAdditiveAreaScreens {
                problem = String(format: "additive-blend area %.2f screens", m.additiveArea / screenArea)
            } else if m.additiveMaxDimension > Safety.maxAdditiveDimension {
                problem = String(format: "additive sprite %.0fpt", m.additiveMaxDimension)
            }
            if problem != nil { break }
        }
        Safety.tick(metricsProblem: problem)
        Diag.shared.flush()
        if lightEditActive {
            let idle = overlays.map { $0.scene.editIdleSeconds() }.min() ?? .infinity
            if idle > WinterScene.editIdleTimeout {
                exitLightEdit(silent: false)               // 30s without interaction
            } else if lightEditAllowed != nil {
                exitLightEdit(silent: true)                // a precondition went away (mode, lights, ...)
            }
        }
        giftSaveCountdown -= 1
        if giftSaveCountdown <= 0 {
            giftSaveCountdown = 10   // throttled: at most every 5s
            saveGiftsIfChanged()
            saveRiders()
        }
        // Live tracking health: per-window fallback, global fallback only if events stopped overall.
        if trackingMode == .live {
            let before = liveMonitor.nonLive
            if liveMonitor.tick(now: ProcessInfo.processInfo.systemUptime) {
                trackingFailure = "이벤트 없음"
                setTrackingMode(.fallback, reason: "no SkyLight move events for 10s; " + liveMonitor.summary)
            }
            if liveMonitor.nonLive != before {
                Diag.shared.row("trackingMode", note: "per-window fallback " + liveMonitor.summary)
                pushNonLive()
            }
        }
    }

    // MARK: Menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "❄️"
        // Remembers a position the user ⌘-drags the icon to (e.g. out from behind the notch).
        item.autosaveName = "WinterDeskStatusItem"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        offStateItem.isEnabled = false
        offStateItem.isHidden = true
        menu.addItem(offStateItem)
        effectsItem.target = self
        menu.addItem(effectsItem)
        editLightsItem.target = self
        editLightsItem.toolTip = "1. 이 항목을 고르거나 ⌃⌥⌘L을 누르세요.\n2. 창 윗변의 금색 점을 다른 창의 금색 점까지 끌어다 놓으세요.\n3. 전구 줄을 클릭하면 삭제돼요. Esc로 끝내요.\n(On Top 모드와 Window Lights는 자동으로 켜져요.)"
        menu.addItem(editLightsItem)
        menu.addItem(.separator())

        if let reason = safeModeReason {
            safeNoticeItem.title = "⚠️ " + reason
            safeNoticeItem.isEnabled = false
            menu.addItem(safeNoticeItem)
            menu.addItem(.separator())
        }

        pauseItem.target = self
        menu.addItem(pauseItem)

        let intensityMenu = NSMenu()
        for i in Intensity.allCases {
            let mi = NSMenuItem(title: i.title, action: #selector(setIntensity(_:)), keyEquivalent: "")
            mi.tag = i.rawValue
            mi.target = self
            intensityMenu.addItem(mi)
            intensityItems.append(mi)
        }
        let intensityParent = NSMenuItem(title: "Snow Intensity", action: nil, keyEquivalent: "")
        intensityParent.submenu = intensityMenu
        menu.addItem(intensityParent)

        let modeMenu = NSMenu()
        for (m, title) in [(OverlayMode.desktop, "Desktop (behind windows)"), (.onTop, "On Top (over everything)")] {
            let mi = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            mi.tag = m.rawValue
            mi.target = self
            modeMenu.addItem(mi)
            modeItems.append(mi)
        }
        let modeParent = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        trackingStatusItem.isEnabled = false
        liveTrackingItem.target = self
        plowItem.target = self
        santaItem.target = self
        menu.addItem(santaItem)
        menu.addItem(plowItem)
        windowSnowItem.target = self
        menu.addItem(windowSnowItem)
        windowLightsItem.target = self
        menu.addItem(windowLightsItem)
        menu.addItem(liveTrackingItem)
        menu.addItem(trackingStatusItem)
        let dragMenu = NSMenu()
        for (tag, title) in [(1, "미끄러져 떨어짐"), (0, "붙어 있음")] {
            let mi = NSMenuItem(title: title, action: #selector(setDragSnow(_:)), keyEquivalent: "")
            mi.tag = tag
            mi.target = self
            dragMenu.addItem(mi)
            dragSnowItems.append(mi)
        }
        let dragParent = NSMenuItem(title: "창 끌 때 눈", action: nil, keyEquivalent: "")
        dragParent.submenu = dragMenu
        menu.addItem(dragParent)
        powerItem.isEnabled = false
        powerItem.isHidden = !PowerMonitor.shared.saving
        menu.addItem(powerItem)
        let linkMenu = NSMenu()
        for (tag, title) in [(1, "Automatic"), (0, "Manual only")] {
            let mi = NSMenuItem(title: title, action: #selector(setLinkMode(_:)), keyEquivalent: "")
            mi.tag = tag
            mi.target = self
            linkMenu.addItem(mi)
            linkModeItems.append(mi)
        }
        let linkParent = NSMenuItem(title: "Light Links", action: nil, keyEquivalent: "")
        linkParent.submenu = linkMenu
        menu.addItem(linkParent)
        garlandsItem.target = self
        menu.addItem(garlandsItem)
        let styleMenu = NSMenu()
        for st in LightStyle.allCases {
            let mi = NSMenuItem(title: st.title, action: #selector(setLightStyle(_:)), keyEquivalent: "")
            mi.tag = st.rawValue
            mi.target = self
            styleMenu.addItem(mi)
            lightStyleItems.append(mi)
        }
        let styleParent = NSMenuItem(title: "Light Style", action: nil, keyEquivalent: "")
        styleParent.submenu = styleMenu
        menu.addItem(styleParent)
        menu.addItem(.separator())

        addGiftItem.target = self
        menu.addItem(addGiftItem)
        let clearBalls = NSMenuItem(title: "Clear Snowballs & Snowmen", action: #selector(clearSnowballs), keyEquivalent: "")
        clearBalls.target = self
        clearBalls.toolTip = "눈덩이·눈사람만 지워요. 하나만 지우려면 눈덩이 위에 잠깐 올려서 ✕를 누르거나 오른쪽 클릭 → 삭제."
        menu.addItem(clearBalls)
        let clear = NSMenuItem(title: "Clear Snowmen, Snowballs & Gifts", action: #selector(clearObjects), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let reset = NSMenuItem(title: "Reset Snow", action: #selector(resetSnow), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())

        axItem.target = self
        menu.addItem(axItem)
        loginItem.target = self
        menu.addItem(loginItem)
        let glitch = NSMenuItem(title: "Report a Glitch   (⌃⌥⌘G)", action: #selector(reportGlitch), keyEquivalent: "")
        glitch.target = self
        menu.addItem(glitch)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit WinterDesk", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        let emergency = NSMenuItem(title: "Emergency quit from anywhere: ⌃⌥⌘Q  ·  ⌘-drag ❄️ to move it", action: nil, keyEquivalent: "")
        emergency.isEnabled = false
        menu.addItem(emergency)

        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        effectsItem.state = effectsOn ? .on : .off
        offStateItem.title = offStateText.map { "⚠️ " + $0 } ?? ""
        offStateItem.isHidden = offStateText == nil
        pauseItem.state = snowFalling ? .on : .off
        for mi in intensityItems { mi.state = mi.tag == intensity.rawValue ? .on : .off }
        for mi in modeItems { mi.state = mi.tag == mode.rawValue ? .on : .off }
        santaItem.state = santaEnabled ? .on : .off
        plowItem.state = plowEnabled ? .on : .off
        liveTrackingItem.state = liveTrackingEnabled ? .on : .off
        for mi in dragSnowItems { mi.state = (mi.tag == 1) == dragSnowSlides ? .on : .off }
        powerItem.isHidden = !PowerMonitor.shared.saving
        addGiftItem.isEnabled = overlays.first(where: { $0.scene.isMainScreen })?.scene.canAddGift ?? false
        windowSnowItem.state = windowSnow ? .on : .off
        windowLightsItem.state = windowLights ? .on : .off
        editLightsItem.state = lightEditActive ? .on : .off
        editLightsItem.isEnabled = lightEditActive || lightEditAllowed == nil
        for mi in linkModeItems { mi.state = (mi.tag == 1) == lightLinksAuto ? .on : .off }
        garlandsItem.state = windowGarlands ? .on : .off
        for mi in lightStyleItems { mi.state = mi.tag == lightStyle.rawValue ? .on : .off }
        axItem.state = DockLocator.isTrusted ? .on : .off
        if LoginItem.isInstalledCopy {
            loginItem.isEnabled = true
            loginItem.toolTip = nil
            switch LoginItem.current {
            case .appService, .launchAgent: loginItem.state = .on
            case .pendingApproval: loginItem.state = .mixed
            case .none: loginItem.state = .off
            }
        } else {
            loginItem.isEnabled = false
            loginItem.state = .off
            loginItem.toolTip = "설치된 앱에서만 설정 가능"
        }
    }

    @objc private func togglePause() {
        snowFalling.toggle()
        for w in overlays { w.scene.snowPaused = snowPaused }
        showToast(snowFalling ? "❄️ 눈 내리기 켜짐" : "눈 내리기 꺼짐")
    }

    /// Small click-through label near the top-center of the main screen; fades out and is
    /// removed after ~1.2s. Never captures the mouse.
    private func showToast(_ text: String, force: Bool = false) {
        toast?.orderOut(nil)
        toast?.close()
        toast = nil
        // `force`: also shown while effects are off (the effects toggle itself), never while locked/asleep.
        guard canShowOverlays || (force && !screensAsleep && !screenLocked && AppDelegate.activeDisplayCount() > 0),
              let panel = makeLabelPanel(text, size: 15, yFromTop: 24) else { return }
        panel.orderFrontRegardless()
        toast = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                panel.close()
                if self?.toast === panel { self?.toast = nil }
            })
        }
    }

    /// Small rounded dark translucent label panel near the top-center of the main screen.
    /// Click-through (ignoresMouseEvents), never key, status-bar level.
    private func makeLabelPanel(_ text: String, size fontSize: CGFloat, yFromTop: CGFloat) -> NSPanel? {
        guard let screen = NSScreen.screens.first else { return nil }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: ceil(textSize.width) + 36, height: ceil(textSize.height) + 18)
        let vf = screen.visibleFrame
        let origin = NSPoint(x: (vf.midX - size.width / 2).rounded(), y: (vf.maxY - size.height - yFromTop).rounded())
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        bg.layer?.cornerRadius = size.height / 2
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - ceil(textSize.height)) / 2 - 1, width: size.width, height: ceil(textSize.height) + 2)
        bg.addSubview(label)
        panel.contentView = bg
        return panel
    }

    @objc private func setIntensity(_ sender: NSMenuItem) {
        intensity = Intensity(rawValue: sender.tag) ?? .normal
        for w in overlays { w.scene.intensity = intensity }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        mode = OverlayMode(rawValue: sender.tag) ?? .desktop
        // An explicit mode choice ends safe mode for this run.
        if safeMode { safeMode = false; safeModeReason = nil; safeNoticeItem.title = "Safe mode ended (mode chosen)" }
        applyMode()
    }

    @objc private func toggleSanta() {
        santaEnabled.toggle()
        for w in overlays { w.scene.santaEnabled = santaEnabled }
        showToast(santaEnabled ? "🎅 산타 켜짐" : "🎅 산타 꺼짐")
    }

    @objc private func toggleWindowSnow() {
        windowSnow.toggle()
        // Takes effect only in On Top mode, which the user must pick explicitly (no auto-switch).
        applyWindowFeatures()
    }

    @objc private func toggleWindowLights() {
        windowLights.toggle()
        // Takes effect only in On Top mode, which the user must pick explicitly (no auto-switch).
        applyWindowFeatures()
    }

    @objc private func setLightStyle(_ sender: NSMenuItem) {
        lightStyle = LightStyle(rawValue: sender.tag) ?? .multicolor
        applyWindowFeatures()
    }

    @objc private func addGift() {
        mainOverlay?.scene.dropGift()
    }

    @objc private func clearSnowballs() {
        for w in overlays { w.scene.clearBalls() }
    }

    @objc private func clearObjects() {
        for w in overlays { w.scene.clearObjects() }
        writeGifts([])   // clears the saved gifts too
        CustomizePanel.shared.dismiss()
    }

    @objc private func resetSnow() {
        for w in overlays { w.scene.resetSnow() }
    }

    @objc private func grantAccessibility() {
        if DockLocator.isTrusted {
            showAlert("Accessibility is already granted.",
                      "WinterDesk reads the Dock's position so snow can settle on top of it, and notices ⌘Tab (key codes only, nothing is recorded) so window snow never flashes during app switching.")
        } else {
            DockLocator.requestTrust()
        }
        refreshDock()
    }

    @objc private func toggleLogin() {
        guard LoginItem.isInstalledCopy else { return }      // build/ or Downloads copies never register
        let wantOn = !(defaults.bool(forKey: LoginItem.preferenceKey) && LoginItem.isEnabled)
        defaults.set(wantOn, forKey: LoginItem.preferenceKey)
        if !wantOn {
            LoginItem.disable(defaults: defaults)
        } else if let problem = LoginItem.enable(repoint: true, defaults: defaults) {
            showAlert("Couldn't enable Launch at Login", problem
                      + "\n\nYou can add WinterDesk manually in System Settings → General → Login Items.")
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
