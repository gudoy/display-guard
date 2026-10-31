// Shared.swift — paths, layout.conf, the log, and a process helper used by both the menu
// bar app and the reconciler (`DisplayGuard --reconcile`).

import Foundation

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Display Guard")
let legacyDir = home.appendingPathComponent("display-setup")   // layout of the bash-script era
let layoutURL = dir.appendingPathComponent("layout.conf")
let pauseURL = dir.appendingPathComponent("paused")
let logURL = dir.appendingPathComponent("reconcile.log")
let lockPath = dir.appendingPathComponent("reconcile.lock").path

let agentLabel = "com.diginja.displays.reconcile"
let menubarLabel = "com.diginja.displays.menubar"
let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
let agentPlist = launchAgents.appendingPathComponent("\(agentLabel).plist")
let menubarPlist = launchAgents.appendingPathComponent("\(menubarLabel).plist")

let topPos = "0x0", bottomPos = "0x1440"

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// One line per action: "YYYY-MM-DD HH:MM:SS  message". Trimmed to 500 lines past 2000.
/// The log stays in English whatever the app language: it is a technical record.
func appendLog(_ message: String) {
    if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(Data("\(stamp.string(from: Date()))  \(message)\n".utf8))
        try? h.close()
    }
    if let text = try? String(contentsOf: logURL, encoding: .utf8) {
        let lines = text.split(separator: "\n")
        if lines.count > 2000 {
            try? (lines.suffix(500).joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

/// Runs a command to completion; returns its exit status and combined output.
@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
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

    /// "5120x0" or "-5120x1440" -> Pos.
    static func parse(_ text: String) -> Pos? {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return nil }
        return Pos(x: x, y: y)
    }
}
