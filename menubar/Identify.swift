// Identify.swift — "Identify screens": a card in the middle of every screen saying which
// panel it is (position, serial, refresh rate), like macOS's own display badges.

import AppKit

private final class ClickToClose: NSVisualEffectView {
    var onClick: () -> Void = {}
    override func mouseDown(with event: NSEvent) { onClick() }
}

final class IdentifyOverlay {
    private var windows: [NSWindow] = []
    private var timer: Timer?

    func show() {
        close()
        let cfg = Config.load()
        let displays = Displays.active()

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            var title = t("identify.builtin")
            var lines: [String] = []
            if let d = displays.first(where: { $0.id == id }) {
                if let pos = cfg.positions.first(where: { $0.serial == d.serial })?.pos {
                    title = Config.parse(pos)?.y == 0 ? t("identify.top") : t("identify.bottom")
                } else {
                    title = t("identify.unmanaged")
                }
                lines.append(d.serial)
                if let cur = d.current { lines.append("\(cur.width) × \(cur.height) · \(cur.hz) Hz") }
                if cfg.primary == d.serial {
                    lines.append(t("identify.primary"))
                } else if d.mode(Reconciler.width, Reconciler.height, Reconciler.hi) != nil {
                    lines.append(t("identify.capable"))
                }
            }
            windows.append(card(on: screen, title: title, lines: lines))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.close() }
    }

    func close() {
        timer?.invalidate()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func card(on screen: NSScreen, title: String, lines: [String]) -> NSWindow {
        let size = NSSize(width: 480, height: 120 + CGFloat(lines.count) * 30)
        let f = screen.frame
        let rect = NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false

        let v = ClickToClose(frame: NSRect(origin: .zero, size: size))
        v.material = .hudWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 24
        v.layer?.masksToBounds = true
        v.onClick = { [weak self] in self?.close() }

        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 52, weight: .bold)
        var views: [NSView] = [head]
        for (i, line) in lines.enumerated() {
            let l = NSTextField(labelWithString: line)
            l.font = i == 0 ? .monospacedSystemFont(ofSize: 22, weight: .semibold) : .systemFont(ofSize: 19)
            l.textColor = i == 0 ? .labelColor : .secondaryLabelColor
            views.append(l)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        w.contentView = v
        w.orderFrontRegardless()
        return w
    }
}
