import Foundation

/// The ⌘Tab / ⌘⇧Tab / ⌘` app- and window-switch gesture, from global key events (only with
/// Accessibility). Pure state machine: it sees a key code and whether ⌘ is held — never key
/// characters, and nothing is stored but the phase.
///
/// WindowServer reorders windows when ⌘ comes up (or at once for a quick tap), before any
/// notification reaches us, so caps hide when the gesture arms and show only after the new order
/// is confirmed: armed (Tab/` with ⌘) → released (⌘ up) → done (a poll ≥ `minHidden` after the
/// release, or `maxHidden` at the latest).
struct SwitchGesture {
    enum Phase: Equatable { case idle, armed, released(at: TimeInterval) }
    static let tabKey: UInt16 = 48          // kVK_Tab
    static let graveKey: UInt16 = 50        // kVK_ANSI_Grave (⌘`: next window of the app)
    static let minHidden: TimeInterval = 0.1
    static let maxHidden: TimeInterval = 0.6

    private(set) var phase: Phase = .idle
    var hiding: Bool { phase != .idle }

    /// A key went down. Returns true when caps must hide now (the gesture armed).
    mutating func keyDown(keyCode: UInt16, command: Bool) -> Bool {
        guard command, keyCode == SwitchGesture.tabKey || keyCode == SwitchGesture.graveKey else { return false }
        let was = phase
        phase = .armed
        return was == .idle
    }

    /// Modifier flags changed. Returns true when ⌘ came up during an armed gesture.
    mutating func flagsChanged(command: Bool, now: TimeInterval) -> Bool {
        guard !command, phase == .armed else { return false }
        phase = .released(at: now)
        return true
    }

    /// A window poll ran (or a timer tick). Returns true when caps may show again: the poll came
    /// at least `minHidden` after ⌘ came up, or `maxHidden` passed.
    mutating func polled(now: TimeInterval) -> Bool {
        guard case .released(let t) = phase, now - t >= SwitchGesture.minHidden else { return false }
        phase = .idle
        return true
    }

    /// Safety: an armed gesture whose ⌘-up was missed (e.g. monitor removed) ends after `maxHidden`
    /// once ⌘ is known to be up.
    mutating func expire(now: TimeInterval, commandDown: Bool) -> Bool {
        switch phase {
        case .released(let t) where now - t >= SwitchGesture.maxHidden:
            phase = .idle; return true
        case .armed where !commandDown:
            phase = .released(at: now); return false
        default:
            return false
        }
    }
}
