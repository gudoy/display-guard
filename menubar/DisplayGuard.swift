// Display Guard — menu bar front-end for reconcile.sh, and its own installer.
//
// The app never touches the displays itself. It only edits the reconciler's inputs
// (layout.conf, the "paused" flag file) and can trigger one run. reconcile.sh, run every
// 15s by the com.diginja.displays.reconcile LaunchAgent, stays the single enforcer —
// two enforcers with different rules is exactly what made the panels flicker before.
//
// Self-install: the scripts ship inside the app bundle. On every launch the app copies
// them to ~/Library/Application Support/Display Guard (so an updated app updates them),
// makes sure both LaunchAgents point at the right place, and on the very first launch
// walks the user through saving the screen arrangement.

import AppKit

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Display Guard")
let legacyDir = home.appendingPathComponent("display-setup")   // before the app shipped its scripts
let layoutURL = dir.appendingPathComponent("layout.conf")
let pauseURL = dir.appendingPathComponent("paused")
let logURL = dir.appendingPathComponent("reconcile.log")
let bundledScripts = ["reconcile.sh", "odyssey-setup.sh", "install-agent.sh"]
func script(_ name: String) -> String { dir.appendingPathComponent(name).path }

let agentLabel = "com.diginja.displays.reconcile"
let menubarLabel = "com.diginja.displays.menubar"
let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
let agentPlist = launchAgents.appendingPathComponent("\(agentLabel).plist")
let menubarPlist = launchAgents.appendingPathComponent("\(menubarLabel).plist")
let betterDisplay = "/Applications/BetterDisplay.app"
let topPos = "0x0", bottomPos = "0x1440"

/// Runs a command to completion; returns its exit status and combined output.
@discardableResult
func run(_ path: String, _ args: [String], env: [String: String] = [:]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
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

enum State { case unconfigured, active, paused, stopped }

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var busy: String?          // shown in the menu while a long setup step runs

    func applicationDidFinishLaunching(_ n: Notification) {
        // One instance only: an install over an older copy can briefly start a second one.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) {
            NSApp.terminate(nil)
            return
        }

        menu.delegate = self
        item.menu = menu
        do {
            try installFiles()
        } catch {
            alert("Display Guard n'a pas pu s'installer", error.localizedDescription)
        }
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshIcon() }

        if fm.fileExists(atPath: layoutURL.path) {
            ensureReconcileAgent()
        } else {
            DispatchQueue.main.async { self.firstRun() }
        }
    }

    // MARK: install

    /// Scripts from the bundle, migration from ~/display-setup, and the login agent.
    func installFiles() throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in bundledScripts {
            guard let src = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw NSError(domain: "DisplayGuard", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(name) manque dans l'app. Réinstalle-la."])
            }
            let dst = dir.appendingPathComponent(name)
            let data = try Data(contentsOf: src)
            if (try? Data(contentsOf: dst)) != data {
                try data.write(to: dst, options: .atomic)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        // Keep the arrangement and history of a setup made before the app shipped its scripts.
        if !fm.fileExists(atPath: layoutURL.path) {
            for name in ["layout.conf", "reconcile.log"] {
                let old = legacyDir.appendingPathComponent(name)
                let new = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                    try fm.copyItem(at: old, to: new)
                }
            }
        }

        // Start at login. Written on every launch so a moved app keeps working.
        guard let exe = Bundle.main.executablePath else { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(menubarLabel)</string>
            <key>Program</key><string>\(exe)</string>
            <key>RunAtLoad</key><true/>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>

        """
        try fm.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        if (try? String(contentsOf: menubarPlist, encoding: .utf8)) != plist {
            try plist.write(to: menubarPlist, atomically: true, encoding: .utf8)
        }
    }

    /// (Re)installs the reconciler agent when it is missing or points at another folder.
    func ensureReconcileAgent() {
        let current = (try? String(contentsOf: agentPlist, encoding: .utf8)) ?? ""
        let loaded = run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status == 0
        guard !current.contains(script("reconcile.sh")) || !loaded else { return }
        DispatchQueue.global().async {
            run("/bin/bash", [script("install-agent.sh")])
            DispatchQueue.main.async { self.refreshIcon() }
        }
    }

    func firstRun() {
        guard fm.fileExists(atPath: betterDisplay) else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "BetterDisplay est nécessaire"
            a.informativeText = "Display Guard pilote les écrans via BetterDisplay (licence Pro). Installe-le dans Applications, lance-le une fois, puis choisis « Configurer les écrans… » dans le menu de Display Guard."
            a.addButton(withTitle: "Ouvrir betterdisplay.pro")
            a.addButton(withTitle: "Plus tard")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://betterdisplay.pro")!)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Configurer les écrans"
        a.informativeText = """
        1. Branche les deux écrans en DisplayPort.
        2. Dispose-les dans Réglages Système > Moniteurs comme tu les veux.
        3. Clique sur Configurer.

        Display Guard applique les réglages BetterDisplay, enregistre cette disposition, puis la rétablit toutes les 15 s. Les écrans peuvent clignoter une fois pendant la configuration.
        """
        a.addButton(withTitle: "Configurer")
        a.addButton(withTitle: "Plus tard")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        configure()
    }

    @objc func configure() {
        busy = "Configuration des écrans…"
        refreshIcon()
        DispatchQueue.global().async {
            var log = ""
            let setup = run("/bin/bash", [script("odyssey-setup.sh")])
            log += setup.output
            var ok = setup.status == 0
            if ok && !fm.fileExists(atPath: layoutURL.path) {
                let save = run("/bin/bash", [script("odyssey-setup.sh"), "--save-layout"])
                log += save.output
                ok = save.status == 0 && fm.fileExists(atPath: layoutURL.path)
            }
            if ok { log += run("/bin/bash", [script("install-agent.sh")]).output }
            DispatchQueue.main.async {
                self.busy = nil
                self.refreshIcon()
                if ok {
                    let layout = Config.load().positions.map { "\($0.serial) en \($0.pos == topPos ? "haut" : "bas")" }
                    self.alert("Écrans configurés", "Disposition enregistrée : \(layout.joined(separator: ", ")).\nDisplay Guard la rétablit maintenant toutes les 15 s.")
                } else {
                    let tail = log.split(separator: "\n").suffix(8).joined(separator: "\n")
                    self.alert("La configuration a échoué", "Vérifie que les deux écrans sont branchés et que BetterDisplay tourne, puis réessaie avec « Configurer les écrans… ».\n\n\(tail)")
                }
            }
        }
    }

    // MARK: state

    var state: State {
        if !fm.fileExists(atPath: layoutURL.path) { return .unconfigured }
        if fm.fileExists(atPath: pauseURL.path) { return .paused }
        return run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status == 0 ? .active : .stopped
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
        case _ where busy != nil: symbol = "hourglass"; tip = busy!
        case .unconfigured: symbol = "exclamationmark.triangle"; tip = "Display Guard : écrans pas encore configurés"
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
        if let busy {
            menu.addItem(info(busy))
            return
        }
        let st = state
        if st == .unconfigured {
            menu.addItem(info("! Écrans pas encore configurés"))
            menu.addItem(.separator())
            menu.addItem(action("Configurer les écrans…", #selector(startFirstRun)))
            menu.addItem(.separator())
            menu.addItem(action("Désinstaller Display Guard…", #selector(uninstall)))
            menu.addItem(action("Quitter Display Guard", #selector(quit)))
            return
        }

        let cfg = Config.load()
        let (last, recent) = recentLog()
        let status: String
        switch st {
        case .active:  status = "● Actif — vérifie toutes les 15 s"
        case .paused:  status = "◌ En pause — les écrans ne sont plus corrigés"
        default:       status = "! Agent arrêté"
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
        default:       menu.addItem(action("Démarrer l'agent", #selector(startAgent)))
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
        menu.addItem(action("Désinstaller Display Guard…", #selector(uninstall)))
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

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: actions

    @objc func startFirstRun() { firstRun() }

    @objc func pause() {
        fm.createFile(atPath: pauseURL.path, contents: nil)
        refreshIcon()
    }

    @objc func resume() {
        try? fm.removeItem(at: pauseURL)
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
            run("/bin/bash", [script("install-agent.sh")])
            DispatchQueue.main.async { self.refreshIcon() }
        }
    }

    @objc func repairNow() {
        DispatchQueue.global().async {
            run("/bin/bash", [script("reconcile.sh")], env: ["RECONCILE_FORCE": "1"])
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
            alert("Impossible d'enregistrer la disposition", error.localizedDescription)
        }
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    @objc func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Désinstaller Display Guard ?"
        a.informativeText = "Les écrans ne seront plus surveillés. La disposition enregistrée, le journal et l'app partent à la corbeille. Les réglages BetterDisplay restent en place."
        a.addButton(withTitle: "Désinstaller")
        a.addButton(withTitle: "Annuler")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        // Not booting out our own job: that would kill this process before the cleanup ends.
        // Without its plist it simply does not start at the next login.
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? fm.removeItem(at: agentPlist)
        try? fm.removeItem(at: menubarPlist)
        NSWorkspace.shared.recycle([dir, Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
