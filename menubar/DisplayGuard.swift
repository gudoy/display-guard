// DisplayGuard.swift — the menu bar app, and its own installer.
//
// The app never fights the reconciler: it only edits its inputs (layout.conf, the
// "paused" flag file) and can trigger one run. `DisplayGuard --reconcile`, run every 15s
// by the com.diginja.displays.reconcile LaunchAgent, stays the single enforcer — two
// enforcers with different rules is exactly what made the panels flicker before.
//
// On every launch the app makes sure both LaunchAgents point at its current location,
// and on the very first launch it saves the screen arrangement.

import AppKit

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let overlay = IdentifyOverlay()
    var timer: Timer?

    enum State { case unsupported, unconfigured, active, paused, stopped }

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
            alert(t("error.install"), error.localizedDescription)
        }
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshIcon() }

        if !Displays.available {
            alert(t("unsupported.title"), t("unsupported.text"))
        } else if fm.fileExists(atPath: layoutURL.path) {
            ensureReconcileAgent()
        } else {
            DispatchQueue.main.async { self.firstRun() }
        }
    }

    // MARK: install

    func installFiles() throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Keep the arrangement and history of a setup made before the app existed.
        if !fm.fileExists(atPath: layoutURL.path) {
            for name in ["layout.conf", "reconcile.log"] {
                let old = legacyDir.appendingPathComponent(name)
                let new = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                    try fm.copyItem(at: old, to: new)
                }
            }
        }
        // Up to 1.1 the reconciler was a set of bash scripts driving BetterDisplay.
        for old in ["reconcile.sh", "odyssey-setup.sh", "install-agent.sh"] {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }

        // Start at login. Written on every launch so a moved app keeps working.
        guard let exe = Bundle.main.executablePath else { return }
        try writeIfChanged(menubarPlist, plist(label: menubarLabel, args: [exe], extra: """
                <key>ProcessType</key><string>Interactive</string>
            """))
    }

    func plist(label: String, args: [String], extra: String) -> String {
        let argv = args.map { "        <string>\($0)</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(argv)
            </array>
            <key>RunAtLoad</key><true/>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
        \(extra)
        </dict>
        </plist>

        """
    }

    /// Returns true when the file content changed.
    @discardableResult
    func writeIfChanged(_ url: URL, _ content: String) throws -> Bool {
        try fm.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        guard (try? String(contentsOf: url, encoding: .utf8)) != content else { return false }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// (Re)loads the reconciler agent when its plist changed or it is not running.
    func ensureReconcileAgent(reload: Bool = false) {
        guard let exe = Bundle.main.executablePath else { return }
        let content = plist(label: agentLabel, args: [exe, "--reconcile"], extra: """
                <key>StartInterval</key><integer>15</integer>
                <key>ProcessType</key><string>Background</string>
                <key>LowPriorityIO</key><true/>
                <key>StandardErrorPath</key><string>\(dir.appendingPathComponent("reconcile.err").path)</string>
            """)
        let changed = (try? writeIfChanged(agentPlist, content)) ?? false
        let domain = "gui/\(getuid())"
        let loaded = run("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"]).status == 0
        if changed || !loaded || reload {
            run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
            run("/bin/launchctl", ["bootstrap", domain, agentPlist.path])
        }
        refreshIcon()
    }

    func firstRun() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = t("welcome.title")
        a.informativeText = t("welcome.text")
        a.addButton(withTitle: t("button.setup"))
        a.addButton(withTitle: t("button.later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        configure()
    }

    /// Saves the current macOS arrangement of every 5120x1440 panel as the one to enforce.
    func configure() {
        let panels = Displays.active().filter {
            $0.mode(Reconciler.width, Reconciler.height, Reconciler.lo) != nil
                || $0.mode(Reconciler.width, Reconciler.height, Reconciler.hi) != nil
        }
        guard !panels.isEmpty else {
            alert(t("noscreen.title"), t("noscreen.text"))
            return
        }
        var cfg = Config()
        cfg.positions = panels
            .sorted { ($0.origin.y, $0.origin.x) < ($1.origin.y, $1.origin.x) }
            .map { ($0.serial, $0.origin.text) }
        do {
            try cfg.save()
        } catch {
            alert(t("error.save"), error.localizedDescription)
            return
        }
        ensureReconcileAgent()
        repairNow()
        let summary = cfg.positions.map {
            Config.parse($0.pos)?.y == 0 ? t("done.top", $0.serial) : t("done.bottom", $0.serial)
        }
        alert(t("done.title"), t("done.text", summary.joined(separator: ", ")))
    }

    // MARK: state

    var state: State {
        if !Displays.available { return .unsupported }
        if !fm.fileExists(atPath: layoutURL.path) { return .unconfigured }
        if fm.fileExists(atPath: pauseURL.path) { return .paused }
        return run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status == 0 ? .active : .stopped
    }

    /// Log lines of the last 5 minutes. Many of them means something is fighting the reconciler.
    func recentLog() -> (last: String?, recentCount: Int) {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return (nil, 0) }
        let lines = text.split(separator: "\n").map(String.init)
        let since = stamp.string(from: Date().addingTimeInterval(-300))
        return (lines.last, lines.suffix(200).filter { String($0.prefix(19)) >= since }.count)
    }

    func refreshIcon() {
        let (_, recent) = recentLog()
        let symbol: String
        let tip: String
        switch state {
        case .unsupported, .unconfigured:
            symbol = "exclamationmark.triangle"; tip = t("tip.unconfigured")
        case .paused:  symbol = "pause.rectangle"; tip = t("tip.paused")
        case .stopped: symbol = "exclamationmark.triangle"; tip = t("tip.stopped")
        case .active where recent >= 6:
            symbol = "display.trianglebadge.exclamationmark"; tip = t("tip.loop")
        case .active:  symbol = "display.2"; tip = t("tip.active")
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = tip
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = state
        switch st {
        case .unsupported:
            menu.addItem(info(t("status.unsupported")))
            footer(menu)
            return
        case .unconfigured:
            menu.addItem(info(t("status.unconfigured")))
            menu.addItem(.separator())
            menu.addItem(action(t("menu.configure"), #selector(startFirstRun)))
            menu.addItem(action(t("menu.identify"), #selector(identify)))
            footer(menu)
            return
        default: break
        }

        let cfg = Config.load()
        let displays = Displays.active()
        let (last, recent) = recentLog()

        switch st {
        case .active: menu.addItem(info(t("status.active")))
        case .paused: menu.addItem(info(t("status.paused")))
        default:      menu.addItem(info(t("status.stopped")))
        }
        if st == .paused, let reason = try? String(contentsOf: pauseURL, encoding: .utf8),
           reason.hasPrefix("breaker:"), let n = Int(reason.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)) {
            menu.addItem(info(t("status.breaker", n)))
        }
        if let last { menu.addItem(info(t("status.last", String(last.dropFirst(11))))) }
        if recent >= 6 { menu.addItem(info(t("status.loop", recent))) }
        menu.addItem(.separator())

        switch st {
        case .active: menu.addItem(action(t("menu.pause"), #selector(pause)))
        case .paused: menu.addItem(action(t("menu.resume"), #selector(resume)))
        default:      menu.addItem(action(t("menu.start"), #selector(startAgent)))
        }
        menu.addItem(action(t("menu.repair"), #selector(repairNow)))
        menu.addItem(action(t("menu.identify"), #selector(identify)))
        menu.addItem(.separator())

        // "HNTX104094 · 120 Hz", so the serials in the submenus mean something.
        func label(_ serial: String) -> String {
            guard let d = displays.first(where: { $0.serial == serial }) else { return t("menu.serialOff", serial) }
            return d.current.map { "\(serial) · \($0.hz) Hz" } ?? serial
        }
        menu.addItem(submenu(t("menu.top"), cfg.serials.map { s in
            choice(label(s), s, cfg.top == s, #selector(setTop(_:)))
        }))
        var hz = [choice(t("menu.auto"), "auto", cfg.primary == "auto", #selector(setPrimary(_:)))]
        hz += cfg.serials.map { s in choice(label(s), s, cfg.primary == s, #selector(setPrimary(_:))) }
        hz += [.separator(), info(t("menu.hzNote"))]
        menu.addItem(submenu(t("menu.hz"), hz))
        footer(menu)
    }

    /// Language, log, uninstall and quit: present in every state.
    func footer(_ menu: NSMenu) {
        menu.addItem(.separator())
        let names: [Language: String] = [.auto: t("menu.langAuto"), .en: "English", .fr: "Français"]
        menu.addItem(submenu(t("menu.language"), Language.allCases.map { l in
            choice(names[l]!, l.rawValue, Language.setting == l, #selector(setLanguage(_:)))
        }))
        menu.addItem(action(t("menu.log"), #selector(openLog)))
        menu.addItem(action(t("menu.uninstall"), #selector(uninstall)))
        menu.addItem(action(t("menu.quit"), #selector(quit)))
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

    func choice(_ title: String, _ value: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = action(title, sel)
        i.representedObject = value
        i.state = on ? .on : .off
        return i
    }

    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        items.forEach(m.addItem)
        i.submenu = m
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
    @objc func identify() { overlay.show() }

    @objc func pause() {
        fm.createFile(atPath: pauseURL.path, contents: nil)
        refreshIcon()
    }

    @objc func resume() {
        try? fm.removeItem(at: pauseURL)
        appendLog("RESUMED (menu)")   // restarts the circuit-breaker count
        refreshIcon()
        repairNow()
    }

    @objc func startAgent() { ensureReconcileAgent(reload: true) }

    /// One forced pass in a separate process, sharing the reconciler's lock.
    @objc func repairNow() {
        guard let exe = Bundle.main.executablePath else { return }
        DispatchQueue.global().async {
            run(exe, ["--reconcile", "--force"])
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

    @objc func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Language(rawValue: raw) else { return }
        Language.setting = l
        refreshIcon()
    }

    func save(_ cfg: Config) {
        do {
            try cfg.save()
            repairNow()
        } catch {
            alert(t("error.save"), error.localizedDescription)
        }
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    @objc func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = t("uninstall.title")
        a.informativeText = t("uninstall.text")
        a.addButton(withTitle: t("button.uninstall"))
        a.addButton(withTitle: t("button.cancel"))
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
