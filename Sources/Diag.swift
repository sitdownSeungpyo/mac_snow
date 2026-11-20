import AppKit
import SpriteKit

/// `--diag`: compact CSV log of window-snow events at ~/Library/Logs/WinterDesk/diag-<timestamp>.csv.
/// One row per event (grab, slide-off, regrow, mouse, poll). Rows are buffered
/// in memory and written by a background queue about once a second (no per-frame disk I/O).
final class Diag {
    static let shared = Diag()
    let enabled = CommandLine.arguments.contains("--diag")
    private var buffer: [String] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "winterdesk.diag", qos: .utility)
    private var handle: FileHandle?
    private(set) var path: String?
    private var lastFlush: TimeInterval = 0
    private let maxRows = 200_000   // ~20MB cap per run
    private var rows = 0

    static let header = "t,event,id,x,y,w,h,note"

    private init() {
        guard enabled else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WinterDesk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("diag-\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path, contents: (Diag.header + "\n").data(using: .utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        path = url.path
    }

    private static func n(_ v: CGFloat) -> String { v.isFinite ? String(format: "%.1f", v) : "" }

    /// One event row: grab / slideOff / regrow / globalMouseDown / globalDragged / globalMouseUp /
    /// pollDetectedButton / fullPoll / info. Always also kept in the in-memory ring (`dumpRing`),
    /// except the per-frame / per-event kinds.
    func row(_ event: String, id: Int = 0, rect: CGRect? = nil, note: String = "") {
        let now = ProcessInfo.processInfo.systemUptime
        if !Diag.ringSkipped.contains(event) { ring(now, event, id, rect, note) }
        guard enabled, rows < maxRows else { return }
        let line = Diag.line(now, event, id, rect, note)
        lock.lock()
        buffer.append(line)
        rows += 1
        lock.unlock()
    }

    private static func line(_ t: TimeInterval, _ event: String, _ id: Int, _ rect: CGRect?, _ note: String) -> String {
        let r = rect.map { "\(Diag.n($0.minX)),\(Diag.n($0.minY)),\(Diag.n($0.width)),\(Diag.n($0.height))" } ?? ",,,"
        return [String(format: "%.4f", t), event, id == 0 ? "" : "\(id)", r, note.replacingOccurrences(of: ",", with: ";")].joined(separator: ",")
    }

    // MARK: Always-on ring ("Report a Glitch")

    /// High-rate kinds that would flush the ring in seconds (they stay in the --diag CSV).
    static let ringSkipped: Set<String> = ["liveFrame", "slsEvent", "globalDragged", "pollDetectedButton"]
    static let ringCapacity = 2000
    private struct RingRow { let t: TimeInterval; let event: String; let id: Int; let rect: CGRect?; let note: String }
    private var ringRows: [RingRow] = []
    private var ringNext = 0
    private let ringLock = NSLock()

    private func ring(_ t: TimeInterval, _ event: String, _ id: Int, _ rect: CGRect?, _ note: String) {
        let r = RingRow(t: t, event: event, id: id, rect: rect, note: note)
        ringLock.lock()
        if ringRows.count < Diag.ringCapacity { ringRows.append(r) } else { ringRows[ringNext] = r }
        ringNext = (ringNext + 1) % Diag.ringCapacity
        ringLock.unlock()
    }

    /// The ring, oldest first, as CSV lines (header first).
    func ringLines() -> [String] {
        ringLock.lock()
        let rows = ringRows.count < Diag.ringCapacity ? ringRows : Array(ringRows[ringNext...] + ringRows[..<ringNext])
        ringLock.unlock()
        return [Diag.header] + rows.map { Diag.line($0.t, $0.event, $0.id, $0.rect, $0.note) }
    }

    /// Writes the ring to ~/Library/Logs/WinterDesk/flicker-<time>.csv; returns the path.
    @discardableResult
    func dumpRing(note: String = "") -> String? {
        row("glitchReport", note: note)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WinterDesk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("flicker-\(f.string(from: Date())).csv")
        guard (try? (ringLines().joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }

    /// Writes buffered rows (call ~1Hz from the main thread; the write happens on a background queue).
    func flush(force: Bool = false) {
        guard enabled, let h = handle else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastFlush >= 1 else { return }
        lastFlush = now
        lock.lock()
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !out.isEmpty else { return }
        let data = (out.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        if force { h.write(data) } else { queue.async { h.write(data) } }
    }
}
