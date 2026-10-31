// Displays.swift — read and change display modes and positions with macOS itself.
//
// Public CoreGraphics hides some modes (the 1x 5120x1440 ones on the 120Hz pipe, among
// others), so modes are listed and set through SkyLight's CGS calls, the same ones
// displayplacer uses. Both G93SC panels report the same numeric serial; the alphanumeric
// one ("HNTX104094") is read from the panel's IORegistry node, found through CoreDisplay.
// All private symbols are looked up at runtime; `available` is false if one disappears.

import CoreGraphics
import Foundation
import IOKit

struct Pos: Equatable {
    var x: Int
    var y: Int
    var text: String { "\(x)x\(y)" }
}

struct Mode {
    let number: Int32
    let width: Int
    let height: Int
    let hz: Int
    let density: Float          // 1 = native pixels, 2 = HiDPI
    var label: String { "\(width)x\(height) \(hz)Hz" }
}

struct Display {
    let id: CGDirectDisplayID
    let serial: String
    let origin: Pos
    let modes: [Mode]
    let current: Mode?

    /// Native-pixel mode with this resolution and refresh rate. Variable (48-120Hz) and
    /// fixed (120Hz) modes are indistinguishable here, so either counts.
    func mode(_ width: Int, _ height: Int, _ hz: Int) -> Mode? {
        modes.first { $0.width == width && $0.height == height && $0.hz == hz && $0.density == 1 }
    }
}

enum Displays {
    private typealias ModeNumberFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias ModeDescFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Int32
    private typealias ConfigureModeFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> Int32
    private typealias InfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
    private static func load<T>(_ lib: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        dlsym(lib, name).map { unsafeBitCast($0, to: type) }
    }
    private static let modeCount = load(skyLight, "CGSGetNumberOfDisplayModes", as: ModeNumberFn.self)
    private static let modeDesc = load(skyLight, "CGSGetDisplayModeDescriptionOfLength", as: ModeDescFn.self)
    private static let currentMode = load(skyLight, "CGSGetCurrentDisplayMode", as: ModeNumberFn.self)
    private static let configureMode = load(skyLight, "CGSConfigureDisplayMode", as: ConfigureModeFn.self)
    private static let info = load(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", as: InfoFn.self)

    static var available: Bool {
        modeCount != nil && modeDesc != nil && currentMode != nil && configureMode != nil && info != nil
    }

    /// External displays that are on and part of the desktop.
    static func active() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard available, CGGetActiveDisplayList(16, &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }.map(display)
    }

    static func display(_ id: CGDirectDisplayID) -> Display {
        let all = modes(id)
        var cur: Int32 = -1
        _ = currentMode?(id, &cur)
        let o = CGDisplayBounds(id).origin
        return Display(id: id, serial: serial(id), origin: Pos(x: Int(o.x), y: Int(o.y)),
                       modes: all, current: all.first { $0.number == cur })
    }

    private static func modes(_ id: CGDirectDisplayID) -> [Mode] {
        guard let modeCount, let modeDesc else { return [] }
        var count: Int32 = 0
        _ = modeCount(id, &count)
        // CGSDisplayModeDescription: 0xD4 bytes are filled; the layout is displayplacer's.
        var buf = [UInt8](repeating: 0, count: 0xDC)
        return (0..<max(count, 0)).map { i in
            _ = modeDesc(id, i, &buf, 0xD4)
            return buf.withUnsafeBytes { b in
                Mode(number: Int32(bitPattern: b.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
                     width: Int(b.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                     height: Int(b.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                     hz: Int(b.loadUnaligned(fromByteOffset: 190, as: UInt16.self)),
                     density: b.loadUnaligned(fromByteOffset: 208, as: Float.self))
            }
        }
    }

    /// The panel's alphanumeric serial (e.g. "HNTX104094"), falling back to the numeric
    /// EDID fields plus manufacture date when the registry does not expose it.
    private static func serial(_ id: CGDirectDisplayID) -> String {
        let numeric = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        guard let dict = info?(id)?.takeRetainedValue() as? [String: Any] else { return numeric }
        let dated = "\(numeric)-\(dict["DisplayYearManufacture"] ?? "?")w\(dict["DisplayWeekManufacture"] ?? "?")"
        guard let location = dict["IODisplayLocation"] as? String else { return dated }
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, location)
        guard entry != 0 else { return dated }
        defer { IOObjectRelease(entry) }
        let attrs = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "DisplayAttributes" as CFString,
                                                    nil, IOOptionBits(kIORegistryIterateRecursively)) as? [String: Any]
        let product = attrs?["ProductAttributes"] as? [String: Any]
        if let s = product?["AlphanumericSerialNumber"] as? String, !s.isEmpty { return s }
        return dated
    }

    @discardableResult
    static func setMode(_ id: CGDirectDisplayID, _ number: Int32) -> Bool {
        guard let configureMode else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        _ = configureMode(cfg, id, number)
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    /// All origins in one transaction: moving panels one by one lets macOS shove the
    /// others around in between, which is how two layout tools ended up fighting.
    @discardableResult
    static func setOrigins(_ list: [(CGDirectDisplayID, Pos)]) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        for (id, p) in list { CGConfigureDisplayOrigin(cfg, id, Int32(p.x), Int32(p.y)) }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }
}
