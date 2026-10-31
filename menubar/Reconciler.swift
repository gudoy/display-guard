// Reconciler.swift — `DisplayGuard --reconcile`, run every 15s by a LaunchAgent.
//
// Puts the panels back to 5120x1440 with one at 240Hz and the others at 120Hz, then
// restores their positions. Only one panel can hold 240Hz (only one display pipe offers
// the link it needs), so the order matters: the others go down to 120Hz first to free
// the bandwidth, then the chosen one goes up to 240Hz. Nothing is written when the state
// already matches, so the run is cheap.

import CoreGraphics
import Foundation

enum Reconciler {
    static let width = 5120, height = 1440, hi = 240, lo = 120
    static let breakerMax = 10
    static let breakerWindow: TimeInterval = 300

    static func pass(force: Bool) -> Int32 {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // One run at a time: the agent and "Repair now" can overlap.
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return 0 }
        defer { flock(fd, LOCK_UN); close(fd) }

        guard Displays.available else { return 2 }
        // Paused from the menu, or by the circuit breaker. force = "Repair now".
        if !force && fm.fileExists(atPath: pauseURL.path) { return 0 }
        let cfg = Config.load()
        guard !cfg.serials.isEmpty else { return 0 }
        if !force && tripBreaker() { return 0 }

        let displays = Displays.active()
        let managed = cfg.serials.compactMap { s in displays.first { $0.serial == s } }
        guard !managed.isEmpty else { return 0 }

        // ---- refresh rates: the others down first, then the chosen panel up ----
        let capable = managed.filter { $0.mode(width, height, hi) != nil }
        let primary = (capable.first { $0.serial == cfg.primary } ?? capable.first)?.serial
        for primaryPass in [false, true] {
            for d in managed where (d.serial == primary) == primaryPass {
                let want = d.serial == primary ? hi : lo
                guard let target = d.mode(width, height, want) else { continue }
                if let cur = d.current, cur.width == width, cur.height == height, cur.hz == want { continue }
                Displays.setMode(d.id, target.number)
                Thread.sleep(forTimeInterval: 3)
                appendLog("\(d.serial): \(d.current?.label ?? "?") -> \(Displays.display(d.id).current?.label ?? "?")")
            }
        }

        // ---- positions: only with every panel of the layout connected ----
        // A lone display is always put back at 0,0 by macOS; insisting would loop forever.
        let now = Displays.active()
        let placed: [(Display, Pos)] = cfg.positions.compactMap { entry in
            guard let d = now.first(where: { $0.serial == entry.serial }),
                  let want = Config.parse(entry.pos) else { return nil }
            return (d, want)
        }
        if placed.count == cfg.positions.count, placed.contains(where: { $0.0.origin != $0.1 }) {
            Displays.setOrigins(placed.map { ($0.0.id, $0.1) })
            Thread.sleep(forTimeInterval: 1)
            for (d, want) in placed where d.origin != want {
                appendLog("\(d.serial): placement \(d.origin.text) -> \(Displays.display(d.id).origin.text) (wanted \(want.text))")
            }
        }
        return 0
    }

    /// Every correction blanks the panels. Many corrections in a short time mean something
    /// is fighting the reconciler (another tool, or a state it misreads), and carrying on
    /// makes the screens flicker forever: pause instead and tell the user. A "RESUMED" line
    /// (written by the menu bar app) restarts the count. The pause file holds "breaker:N"
    /// so the menu can word the reason in its own language.
    static func tripBreaker() -> Bool {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return false }
        let since = stamp.string(from: Date().addingTimeInterval(-breakerWindow))
        var n = 0
        for line in text.split(separator: "\n").suffix(400) {
            if line.contains("  RESUMED") || line.contains("  BREAKER") { n = 0; continue }
            if String(line.prefix(19)) >= since { n += 1 }
        }
        guard n >= breakerMax else { return false }
        try? "breaker:\(n)".write(to: pauseURL, atomically: true, encoding: .utf8)
        appendLog("BREAKER: \(n) corrections in 5 min, paused")
        let script = "display notification \"\(t("notify.text", n))\" with title \"\(t("notify.title"))\""
        run("/usr/bin/osascript", ["-e", script])
        return true
    }
}
