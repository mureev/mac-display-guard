import Foundation

/// A display mode as people think about it: "looks like" size, refresh rate, and whether it is HiDPI.
///
/// Text form, used in the config and printed by `mac-display-guard list`:
///
///     2560x1440@165 hidpi
///     1920x1080@60
public struct ModeSpec: Hashable, CustomStringConvertible, Sendable {
    public var width: Int
    public var height: Int
    public var hz: Int
    public var hidpi: Bool

    public init(width: Int, height: Int, hz: Int, hidpi: Bool) {
        self.width = width
        self.height = height
        self.hz = hz
        self.hidpi = hidpi
    }

    /// Parses `2560x1440@165 hidpi`. Tolerates spaces, `Hz`, upper case and `×`.
    public init?(parsing text: String) {
        var s = text.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "hz", with: "")
        var hidpi = false
        for word in ["hidpi", "scaled", "retina"] where s.contains(word) {
            hidpi = true
            s = s.replacingOccurrences(of: word, with: "")
        }
        s = s.replacingOccurrences(of: " ", with: "")
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let size = parts[0].split(separator: "x", omittingEmptySubsequences: false)
        guard size.count == 2,
              let w = Int(size[0]), let h = Int(size[1]),
              let r = Double(parts[1]),
              w > 0, h > 0, r > 0
        else { return nil }
        self.init(width: w, height: h, hz: Int(r.rounded()), hidpi: hidpi)
    }

    public var description: String {
        "\(width)x\(height)@\(hz)" + (hidpi ? " hidpi" : "")
    }
}

/// What the guard should do with one display.
public enum Decision: Equatable, Sendable {
    /// Already on the best preferred mode that is offered.
    case keep(ModeSpec)
    /// Switch to this mode (the first preferred mode that is offered).
    case switchTo(ModeSpec)
    /// None of the preferred modes is offered right now; leave the display alone.
    case nothingOffered
}

/// The whole policy: use the first mode in `prefer` that the display offers.
public func decide(current: ModeSpec?, offered: Set<ModeSpec>, prefer: [ModeSpec]) -> Decision {
    guard let target = prefer.first(where: { offered.contains($0) }) else { return .nothingOffered }
    return current == target ? .keep(target) : .switchTo(target)
}

/// Stops the guard from fighting a mode switch that keeps failing
/// (for example after an OS update changes behaviour): after `maxFailures`
/// failures in a row it pauses that display for `pause` seconds.
public struct Backoff: Sendable {
    public private(set) var failures = 0
    public private(set) var until: Date?
    public let maxFailures: Int
    public let pause: TimeInterval

    public init(maxFailures: Int = 3, pause: TimeInterval = 300) {
        self.maxFailures = maxFailures
        self.pause = pause
    }

    public func isActive(now: Date) -> Bool {
        if let until { return now < until }
        return false
    }

    /// Returns true when this failure starts a pause.
    public mutating func recordFailure(now: Date) -> Bool {
        failures += 1
        if failures >= maxFailures {
            failures = 0
            until = now.addingTimeInterval(pause)
            return true
        }
        return false
    }

    public mutating func recordSuccess() {
        failures = 0
        until = nil
    }
}
