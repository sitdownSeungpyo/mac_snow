import AppKit
import SpriteKit

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
        contentView = view
        ensureTransparent()
        view.presentScene(scene)
    }

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
            orderFrontRegardless()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
