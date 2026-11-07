import AppKit
import CoreGraphics
import DisplayGuardCore

/// Thin wrappers over CoreGraphics display APIs.
enum Displays {
    /// All online displays (including sleeping/mirrored ones).
    static func online() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let names = screenNames()
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(id: id,
                        serial: CGDisplaySerialNumber(id),
                        vendor: CGDisplayVendorNumber(id),
                        model: CGDisplayModelNumber(id),
                        name: names[id],
                        builtin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// Display names from AppKit (e.g. "Odyssey G7"). Best effort: only for displays that have a screen.
    static func screenNames() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                out[n.uint32Value] = screen.localizedName
            }
        }
        return out
    }

    /// Every mode the display offers for the desktop, including HiDPI ("scaled") ones.
    static func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return [] }
        return list.filter { $0.isUsableForDesktopGUI() }
    }

    static func spec(_ m: CGDisplayMode) -> ModeSpec {
        ModeSpec(width: m.width, height: m.height,
                 hz: Int(m.refreshRate.rounded()),
                 hidpi: m.pixelWidth > m.width)
    }

    static func current(_ id: CGDirectDisplayID) -> ModeSpec? {
        CGDisplayCopyDisplayMode(id).map(spec)
    }

    static func offered(_ id: CGDirectDisplayID) -> Set<ModeSpec> {
        Set(modes(id).map(spec))
    }

    /// Switches the display to a mode matching `target` and makes it the saved setting.
    /// Returns true if the display reports the target afterwards.
    static func set(_ id: CGDirectDisplayID, to target: ModeSpec) -> Bool {
        // Several CGDisplayModes can share a spec (different pixel formats); take the one
        // with the most backing pixels, which is what System Settings picks.
        let candidates = modes(id).filter { spec($0) == target }
            .sorted { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        guard let mode = candidates.first else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { return false }
        return current(id) == target
    }
}
