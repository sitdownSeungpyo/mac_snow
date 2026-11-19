import AppKit

/// Animated "how to link lights" illustration: a gold dot drags a dashed wire to another gold
/// dot, then bulbs light up along it. Animates only while visible.
final class CoachAnimationView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 1.0 / 60).truncatingRemainder(dividingBy: 1)
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        let gold = NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1)
        let a = NSPoint(x: 26, y: bounds.midY + 6), b = NSPoint(x: bounds.maxX - 26, y: bounds.midY + 6)
        // Two "window tops".
        NSColor(white: 1, alpha: 0.25).setStroke()
        for x in [a.x, b.x] {
            let r = NSRect(x: x - 22, y: bounds.minY + 4, width: 44, height: a.y - bounds.minY - 4)
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).stroke()
        }
        let p = min(1, phase / 0.6)
        let end = NSPoint(x: a.x + (b.x - a.x) * p, y: a.y - sin(.pi * p) * 14)
        let wire = NSBezierPath()
        wire.move(to: a)
        wire.curve(to: end, controlPoint1: NSPoint(x: a.x + (end.x - a.x) * 0.3, y: a.y - 18 * p),
                   controlPoint2: NSPoint(x: a.x + (end.x - a.x) * 0.7, y: end.y - 10 * p))
        wire.lineWidth = 2
        wire.setLineDash([5, 4], count: 2, phase: 0)
        NSColor(white: 1, alpha: 0.85).setStroke()
        wire.stroke()
        // Bulbs once connected.
        if phase > 0.6 {
            let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemYellow, .systemOrange]
            for k in 0..<5 {
                let t = (CGFloat(k) + 0.5) / 5
                let q = NSPoint(x: a.x + (b.x - a.x) * t, y: a.y - sin(.pi * t) * 14 - 4)
                colors[k].withAlphaComponent(min(1, (phase - 0.6) * 4)).setFill()
                NSBezierPath(ovalIn: NSRect(x: q.x - 3, y: q.y - 4, width: 6, height: 8)).fill()
            }
        }
        // Dots (the moving one is the cursor end).
        for (q, r) in [(a, CGFloat(7)), (b, CGFloat(7 + (phase > 0.55 ? 3 : 0)))] {
            gold.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: q.x - r - 5, y: q.y - r - 5, width: 2 * r + 10, height: 2 * r + 10)).fill()
            gold.setFill()
            NSBezierPath(ovalIn: NSRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)).fill()
        }
        if phase <= 0.6 {
            NSColor.white.setFill()
            let c = NSBezierPath()   // tiny cursor arrow
            c.move(to: NSPoint(x: end.x, y: end.y))
            c.line(to: NSPoint(x: end.x, y: end.y - 13))
            c.line(to: NSPoint(x: end.x + 4, y: end.y - 9))
            c.line(to: NSPoint(x: end.x + 9, y: end.y - 9))
            c.close()
            c.fill()
        }
    }
}

/// "알겠어요" button (first click works in a non-activating panel).
final class CoachButton: ClickableView {
    var onClick: () -> Void = {}
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let s = NSAttributedString(string: "알겠어요", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                                                                .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        let sz = s.size()
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
    }
    override func clicked(at p: NSPoint) { onClick() }
}

/// Centered coach mark near the top of the main screen. Click-through everywhere except its
/// button (the owner toggles `ignoresMouseEvents` from the 60Hz poll using `buttonScreenRect`).
final class CoachPanel: NSPanel {
    private let animation: CoachAnimationView
    private let button = CoachButton(frame: .zero)

    init?(text: String, onDismiss: @escaping () -> Void) {
        guard let screen = NSScreen.screens.first else { return nil }
        let W: CGFloat = 460, H: CGFloat = 176
        let vf = screen.visibleFrame
        let frame = NSRect(x: (vf.midX - W / 2).rounded(), y: (vf.maxY - H - 64).rounded(), width: W, height: H)
        animation = CoachAnimationView(frame: NSRect(x: 60, y: 84, width: W - 120, height: 80))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.86).cgColor
        bg.layer?.cornerRadius = 16
        bg.addSubview(animation)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 40, width: W - 40, height: 40)
        bg.addSubview(label)
        button.frame = NSRect(x: W / 2 - 50, y: 8, width: 100, height: 26)
        button.onClick = onDismiss
        bg.addSubview(button)
        contentView = bg
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The button's rectangle in screen coordinates.
    var buttonScreenRect: NSRect { convertToScreen(button.convert(button.bounds, to: nil)) }

    func shutDown() {
        animation.stop()
        ignoresMouseEvents = true
        orderOut(nil)
        close()
    }
}
