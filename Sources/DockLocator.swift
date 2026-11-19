import AppKit
import ApplicationServices

/// Finds the Dock's top edge so snow and objects can rest on it.
/// Primary: Accessibility (AXList child of the Dock process). Fallback: visibleFrame gap + Dock prefs.
enum DockLocator {
    private static let dockDomain = "com.apple.dock" as CFString

    private static func pref(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, dockDomain)
    }

    static func reloadPrefs() { CFPreferencesAppSynchronize(dockDomain) }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Dock tile-list frame in Cocoa global coordinates, or nil if unavailable.
    static func axDockFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXChildren" as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for el in children {
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, "AXRole" as CFString, &roleRef) == .success,
                  (roleRef as? String) == "AXList" else { continue }
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sizeRef) == .success,
                  let posVal = posRef, let sizeVal = sizeRef,
                  CFGetTypeID(posVal) == AXValueGetTypeID(), CFGetTypeID(sizeVal) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
                  AXValueGetValue(sizeVal as! AXValue, .cgSize, &size),
                  size.width > 0, size.height > 0 else { continue }
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
        }
        return nil
    }

    /// Dock band for `screen` in screen-local coordinates; nil means "use the screen bottom".
    static func band(screenFrame: CGRect, visibleFrame: CGRect, axFrame: CGRect?) -> DockBand? {
        if (pref("autohide") as? Bool) == true { return nil }
        let orientation = (pref("orientation") as? String) ?? "bottom"
        guard orientation == "bottom" else { return nil }

        if let f = axFrame {
            guard f.width > f.height,
                  f.midX >= screenFrame.minX, f.midX <= screenFrame.maxX,
                  f.minY < screenFrame.minY + 40, f.maxY > screenFrame.minY else { return nil }
            return DockBand(minX: f.minX - screenFrame.minX, maxX: f.maxX - screenFrame.minX, top: f.maxY - screenFrame.minY,
                            corner: clamp(f.height * 0.42, 10, 26))
        }

        let gap = visibleFrame.minY - screenFrame.minY
        guard gap > 8 else { return nil }
        let w = screenFrame.width
        var width = w * 0.9
        if let tile = (pref("tilesize") as? NSNumber).map({ CGFloat($0.doubleValue) }), tile > 0 {
            // Finder + pinned apps + running non-pinned apps + pinned files/folders + Trash.
            // Recents can't be known without Accessibility, so they are left out on purpose:
            // erring NARROWER keeps snow from overhanging empty space; the rounded, tapered ends
            // make a slightly short cap look natural rather than cut.
            let pinned = (pref("persistent-apps") as? [[String: Any]]) ?? []
            let pinnedIDs = Set(pinned.compactMap { (($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) })
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                    && !pinnedIDs.contains($0.bundleIdentifier ?? "")
            }.count
            let others = (pref("persistent-others") as? [Any])?.count ?? 0
            let tiles = 1 + pinned.count + running + others + 1
            width = min(w * 0.98, CGFloat(tiles) * (tile + 3) + 12)
        }
        return DockBand(minX: (w - width) / 2, maxX: (w + width) / 2, top: gap, corner: clamp((gap - 6) * 0.42, 10, 22))
    }
}
