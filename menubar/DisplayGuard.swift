// Display Guard — menu bar front-end for ~/display-setup/reconcile.sh.
//
// The app never touches the displays itself. It only edits the reconciler's inputs
// (layout.conf, the "paused" flag file) and can trigger one run. reconcile.sh, run every
// 15s by the com.diginja.displays.reconcile LaunchAgent, stays the single enforcer —
// two enforcers with different rules is exactly what made the panels flicker before.

import AppKit

// Repo folder, passed by the LaunchAgent that build.sh writes. Fallback for a manual launch.
let dir = ProcessInfo.processInfo.environment["DISPLAY_SETUP_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("display-setup")
let layoutURL = dir.appendingPathComponent("layout.conf")
let pauseURL = dir.appendingPathComponent("paused")
let logURL = dir.appendingPathComponent("reconcile.log")
let scriptPath = dir.appendingPathComponent("reconcile.sh").path
let installPath = dir.appendingPathComponent("install-agent.sh").path
let agentLabel = "com.diginja.displays.reconcile"
let topPos = "0x0", bottomPos = "0x1440"

@discardableResult
func run(_ path: String, _ args: [String], env: [String: String] = [:]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// layout.conf: one "SERIAL=XxY" line per panel, plus an optional "PRIMARY=SERIAL".
struct Config {
    var positions: [(serial: String, pos: String)] = []
    var primary = "auto"

    static func load() -> Config {
        var c = Config()
        guard let text = try? String(contentsOf: layoutURL, encoding: .utf8) else { return c }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            if kv[0] == "PRIMARY" { c.primary = kv[1] } else { c.positions.append((kv[0], kv[1])) }
        }
        return c
    }

    func save() throws {
        var lines = positions.map { "\($0.serial)=\($0.pos)" }
        if primary != "auto" { lines.append("PRIMARY=\(primary)") }
        try (lines.joined(separator: "\n") + "\n").write(to: layoutURL, atomically: true, encoding: .utf8)
    }

    var serials: [String] { positions.map(\.serial) }
    var top: String? { positions.first { $0.pos == topPos }?.serial }
}

enum State { case active, paused, stopped }

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshIcon() }
    }

    var state: State {
        if FileManager.default.fileExists(atPath: pauseURL.path) { return .paused }
        return run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]) == 0 ? .active : .stopped
    }

    /// Log lines of the last 5 minutes. Many of them means something is fighting the reconciler.
    func recentLog() -> (last: String?, recentCount: Int) {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return (nil, 0) }
        let lines = text.split(separator: "\n").map(String.init)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let cutoff = Date().addingTimeInterval(-300)
        let recent = lines.suffix(200).filter { line in
            guard let d = fmt.date(from: String(line.prefix(19))) else { return false }
            return d > cutoff
        }
        return (lines.last, recent.count)
    }

    func refreshIcon() {
        let (_, recent) = recentLog()
        let symbol: String
        let tip: String
        switch state {
        case .paused:  symbol = "pause.rectangle";  tip = "Display Guard : en pause"
        case .stopped: symbol = "exclamationmark.triangle"; tip = "Display Guard : agent arrêté"
        case .active where recent >= 6:
            symbol = "display.trianglebadge.exclamationmark"; tip = "Display Guard : corrections répétées"
        case .active:  symbol = "display.2"; tip = "Display Guard : actif"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = tip
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = Config.load()
        let st = state
        let (last, recent) = recentLog()

        let status: String
        switch st {
        case .active:  status = "● Actif — vérifie toutes les 15 s"
        case .paused:  status = "◌ En pause — les écrans ne sont plus corrigés"
        case .stopped: status = "! Agent arrêté"
        }
        menu.addItem(info(status))
        if st == .paused,
           let reason = try? String(contentsOf: pauseURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            menu.addItem(info("⚠︎ " + reason))
        }
        if let last { menu.addItem(info("Dernière action : " + String(last.dropFirst(11)))) }
        if recent >= 6 { menu.addItem(info("⚠︎ \(recent) corrections en 5 min : un autre outil se bat ?")) }
        menu.addItem(.separator())

        switch st {
        case .active:  menu.addItem(action("Mettre en pause", #selector(pause)))
        case .paused:  menu.addItem(action("Reprendre", #selector(resume)))
        case .stopped: menu.addItem(action("Démarrer l'agent", #selector(startAgent)))
        }
        menu.addItem(action("Réparer maintenant", #selector(repairNow)))
        menu.addItem(.separator())

        let top = NSMenuItem(title: "Écran du haut", action: nil, keyEquivalent: "")
        let topMenu = NSMenu()
        for s in cfg.serials {
            let i = action(s, #selector(setTop(_:)))
            i.representedObject = s
            i.state = cfg.top == s ? .on : .off
            topMenu.addItem(i)
        }
        top.submenu = topMenu
        menu.addItem(top)

        let hz = NSMenuItem(title: "Écran à 240 Hz", action: nil, keyEquivalent: "")
        let hzMenu = NSMenu()
        for s in ["auto"] + cfg.serials {
            let i = action(s == "auto" ? "Automatique" : s, #selector(setPrimary(_:)))
            i.representedObject = s
            i.state = cfg.primary == s ? .on : .off
            hzMenu.addItem(i)
        }
        hzMenu.addItem(.separator())
        hzMenu.addItem(info("Seul l'écran branché sur le port rapide peut avoir 240 Hz"))
        hz.submenu = hzMenu
        menu.addItem(hz)

        menu.addItem(.separator())
        menu.addItem(action("Ouvrir le journal", #selector(openLog)))
        menu.addItem(action("Quitter Display Guard", #selector(quit)))
    }

    func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: actions

    @objc func pause() {
        FileManager.default.createFile(atPath: pauseURL.path, contents: nil)
        refreshIcon()
    }

    @objc func resume() {
        try? FileManager.default.removeItem(at: pauseURL)
        // Restarts reconcile.sh's circuit-breaker count, otherwise it would trip again at once.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write("\(fmt.string(from: Date()))  RESUMED (menu)\n".data(using: .utf8)!)
            try? h.close()
        }
        refreshIcon()
        repairNow()
    }

    @objc func startAgent() {
        DispatchQueue.global().async {
            run("/bin/bash", [installPath])
            DispatchQueue.main.async { self.refreshIcon() }
        }
    }

    @objc func repairNow() {
        DispatchQueue.global().async {
            run("/bin/bash", [scriptPath], env: ["RECONCILE_FORCE": "1"])
            DispatchQueue.main.async { self.refreshIcon() }
        }
    }

    @objc func setTop(_ sender: NSMenuItem) {
        guard let chosen = sender.representedObject as? String else { return }
        var cfg = Config.load()
        cfg.positions = cfg.positions.map { ($0.serial, $0.serial == chosen ? topPos : bottomPos) }
        save(cfg)
    }

    @objc func setPrimary(_ sender: NSMenuItem) {
        guard let chosen = sender.representedObject as? String else { return }
        var cfg = Config.load()
        cfg.primary = chosen
        save(cfg)
    }

    func save(_ cfg: Config) {
        do {
            try cfg.save()
            repairNow()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossible d'écrire layout.conf"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
