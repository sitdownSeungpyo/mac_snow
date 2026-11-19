import CoreGraphics
import Foundation

/// Where a user strand is attached on a window's top edge.
enum AnchorKind: Int, Codable, CaseIterable {
    case left = 0, center = 1, right = 2
    var fx: CGFloat { self == .left ? 0 : (self == .center ? 0.5 : 1) }
}

struct LightAnchor: Hashable {
    let window: Int
    let kind: AnchorKind
}

/// A user-created strand between anchors on two different windows (unordered).
struct UserLink: Hashable {
    let a: LightAnchor
    let b: LightAnchor
    func same(as o: UserLink) -> Bool { (a == o.a && b == o.b) || (a == o.b && b == o.a) }
    func involves(_ window: Int) -> Bool { a.window == window || b.window == window }
}

/// Persisted form: windows are identified by owner bundle id + rank among that app's windows,
/// since window ids change across launches.
struct SavedLightLink: Codable, Equatable {
    var aOwner: String, aIndex: Int, aKind: Int
    var bOwner: String, bIndex: Int, bKind: Int
}

enum LinkResult: Equatable { case added, sameWindow, duplicate, covered, full, invalid }

enum LightLinkStore {
    static let maxLinks = 20

    /// Validation shared by interactive linking and restore. `visible(anchor)` reports whether an
    /// anchor is currently uncovered (pass `{ _ in true }` to skip the check).
    static func validate(_ link: UserLink, existing: [UserLink], windows: [AppWindow],
                         visible: (LightAnchor) -> Bool) -> LinkResult {
        guard link.a.window != link.b.window else { return .sameWindow }
        let ids = Set(windows.map { $0.id })
        guard ids.contains(link.a.window), ids.contains(link.b.window) else { return .invalid }
        for w in windows where w.id == link.a.window || w.id == link.b.window {
            guard w.frame.minX.isFinite, w.frame.maxY.isFinite, w.frame.width.isFinite, w.frame.width > 0 else { return .invalid }
        }
        if existing.contains(where: { $0.same(as: link) }) { return .duplicate }
        if existing.count >= maxLinks { return .full }
        if !visible(link.a) || !visible(link.b) { return .covered }
        return .added
    }

    static func save(_ links: [UserLink], windows: [AppWindow]) -> [SavedLightLink] {
        let byId = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return links.compactMap { l in
            guard let wa = byId[l.a.window], let wb = byId[l.b.window], !wa.owner.isEmpty, !wb.owner.isEmpty else { return nil }
            return SavedLightLink(aOwner: wa.owner, aIndex: wa.ownerIndex, aKind: l.a.kind.rawValue,
                                  bOwner: wb.owner, bIndex: wb.ownerIndex, bKind: l.b.kind.rawValue)
        }
    }

    /// Resolves saved links against the current windows. A link is restored only when both ends
    /// match exactly one window each (and the two are different); everything else is returned in
    /// `unresolved`.
    static func resolve(_ saved: [SavedLightLink], windows: [AppWindow])
        -> (links: [UserLink], unresolved: [SavedLightLink]) {
        var links: [UserLink] = []
        var unresolved: [SavedLightLink] = []
        func find(_ owner: String, _ index: Int) -> Int? {
            let m = windows.filter { $0.owner == owner && $0.ownerIndex == index }
            return m.count == 1 ? m[0].id : nil
        }
        for s in saved {
            guard let ka = AnchorKind(rawValue: s.aKind), let kb = AnchorKind(rawValue: s.bKind),
                  let wa = find(s.aOwner, s.aIndex), let wb = find(s.bOwner, s.bIndex), wa != wb else {
                unresolved.append(s)
                continue
            }
            let link = UserLink(a: LightAnchor(window: wa, kind: ka), b: LightAnchor(window: wb, kind: kb))
            if validate(link, existing: links, windows: windows, visible: { _ in true }) == .added { links.append(link) }
        }
        return (links, unresolved)
    }
}
