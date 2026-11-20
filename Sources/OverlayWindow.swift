import AppKit
import SpriteKit

/// Keeps a window at alpha 0 from the moment it is ordered in until its SKView has run two scene
/// updates plus one more main-thread turn (so a rendered frame is presented), failsafe 0.35s:
/// WindowServer never composites a window whose drawable is empty, uninitialised or stale.
final class RevealGate {
    private weak var window: NSWindow?
    private let label: String
    private var token = 0, frames = 0, reason = ""
    private var since: TimeInterval?
    static let failsafe: TimeInterval = 0.35
    /// How the window is ordered in (the offscreen harness replaces it: nothing goes on screen).
    var orderFront: (NSWindow) -> Void = { $0.orderFrontRegardless() }
    /// Whether the window is on screen (the harness replaces it).
    var isShown: (NSWindow) -> Bool = { $0.isVisible }
    /// Harness / diag: alpha changes made by this gate.
    private(set) var alphaChanges = 0

    init(window: NSWindow, label: String) { self.window = window; self.label = label }

    var pending: Bool { since != nil }

    /// Orders the window in, invisible until its first frames are rendered.
    func orderIn(_ why: String) {
        guard let w = window else { return }
        token += 1; frames = 0; reason = why
        since = ProcessInfo.processInfo.systemUptime
        setAlpha(w, 0)
        orderFront(w)
        if held { since = nil; return }              // shown by `release`
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + RevealGate.failsafe) { [weak self] in self?.reveal(t, how: "failsafe") }
    }

    /// Hides an already shown window NOW (a WindowServer alpha change, no render needed) until it
    /// has rendered two more frames: its current drawable is wrong (e.g. a back window's snow that
    /// the ⌘Tab-raised window now covers, at a strip-only cap's 15fps).
    func hideUntilRendered(_ why: String) {
        guard !held, let w = window, isShown(w) else { return }
        token += 1; frames = 0; reason = why
        since = ProcessInfo.processInfo.systemUptime
        setAlpha(w, 0)
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + RevealGate.failsafe) { [weak self] in self?.reveal(t, how: "failsafe") }
    }

    /// Held hidden (⌘Tab gesture): alpha 0 now, and no reveal of any kind until `release`.
    private(set) var held = false
    func hold() {
        guard let w = window else { return }
        held = true
        token += 1; since = nil
        setAlpha(w, 0)
    }
    /// End of a hold: shown again after two more rendered frames (failsafe as usual).
    func release(_ why: String) {
        guard held, let w = window else { return }
        held = false
        token += 1; frames = 0; reason = why
        since = ProcessInfo.processInfo.systemUptime
        setAlpha(w, 0)
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + RevealGate.failsafe) { [weak self] in self?.reveal(t, how: "failsafe") }
    }

    /// From the scene's update (any thread).
    func sceneUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.since != nil else { return }
            self.frames += 1
            if self.frames == 2 {
                let t = self.token
                DispatchQueue.main.async { [weak self] in self?.reveal(t, how: "rendered") }
            }
        }
    }

    private func setAlpha(_ w: NSWindow, _ a: CGFloat) {
        if a == 0 { fadeTimer?.invalidate(); fadeTimer = nil }      // a hide cancels a fade at once
        if w.alphaValue != a { alphaChanges += 1 }
        w.alphaValue = a
    }

    /// Showing fades in (ease-out over `fadeDuration`); hiding is always instant. The fade starts
    /// only from `reveal`, i.e. after the rendered-frames condition: it fades in correct content.
    static let fadeDuration: TimeInterval = 0.22
    private var fadeTimer: Timer?
    var fading: Bool { fadeTimer != nil }
    private func fadeIn(_ w: NSWindow) {
        fadeTimer?.invalidate()
        let t = token, start = ProcessInfo.processInfo.systemUptime
        alphaChanges += 1
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] tm in
            // Any hide / hold / new order-in bumps the token: the fade stops where it is (the hide
            // itself already set alpha 0).
            guard let self, t == self.token, !self.held, let w = self.window else { tm.invalidate(); return }
            let u = min(1, (ProcessInfo.processInfo.systemUptime - start) / RevealGate.fadeDuration)
            w.alphaValue = CGFloat(1 - pow(1 - u, 3))
            if u >= 1 { tm.invalidate(); self.fadeTimer = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func reveal(_ t: Int, how: String) {
        guard t == token, !held, let s = since, let w = window else { return }
        since = nil
        fadeIn(w)
        Diag.shared.row("reveal", note: String(format: "%@ %@ after %.0fms (%@)", label, how, (ProcessInfo.processInfo.systemUptime - s) * 1000, reason))
    }
}

final class OverlayView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, transparent, non-activating full-screen overlay hosting the winter scene.
final class OverlayWindow: NSPanel {
    let scene: WinterScene
    let hostScreen: NSScreen

    init(screen: NSScreen, isMain: Bool) {
        hostScreen = screen
        scene = WinterScene(size: screen.frame.size, isMainScreen: isMain)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.allowsTransparency = true
        // Match the display (120 on ProMotion); non-key, non-activating panels still render at full rate.
        view.preferredFramesPerSecond = min(120, max(60, screen.maximumFramesPerSecond))
        view.isAsynchronous = true
        view.ignoresSiblingOrder = false
        view.shouldCullNonVisibleNodes = true
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true            // the layer exists (and is made transparent) before any order-in
        contentView = view
        ensureTransparent()
        view.presentScene(scene)
        alphaValue = 0                    // shown by `reveal` once the scene has rendered
        revealGate = RevealGate(window: self, label: "overlay")
        scene.onUpdate = { [weak self] in self?.revealGate?.sceneUpdated() }
    }

    private(set) var revealGate: RevealGate?
    /// Orders the overlay in; it becomes visible only after its first rendered frames.
    func orderInRevealing(_ why: String) { revealGate?.orderIn(why) }

    /// The SKView's Metal layer must never be opaque: an opaque full-screen panel above every
    /// window hides the whole desktop. Re-applied defensively by the safety tick.
    /// Returns true if something had to be repaired.
    @discardableResult
    func ensureTransparent() -> Bool {
        guard let view = contentView as? SKView else { return false }
        var repaired = false
        if !view.allowsTransparency { view.allowsTransparency = true; repaired = true }
        if let layer = view.layer {
            if layer.isOpaque { layer.isOpaque = false; repaired = true }
            if layer.backgroundColor?.alpha ?? 0 > 0 { layer.backgroundColor = CGColor.clear; repaired = true }
        }
        if isOpaque { isOpaque = false; repaired = true }
        if backgroundColor != .clear { backgroundColor = .clear; repaired = true }
        if scene.backgroundColor.alphaComponent > 0 { scene.backgroundColor = .clear; repaired = true }
        return repaired
    }

    /// Paused (a full-screen app covers this screen): hidden, no rendering.
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        (contentView as? SKView)?.isPaused = paused
        if paused {
            ignoresMouseEvents = true
            orderOut(nil)
        } else {
            orderInRevealing("resume")     // its last drawable is stale: shown after a fresh frame
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
