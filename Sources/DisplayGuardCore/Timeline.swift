import Foundation

/// One display-related event reconstructed from macOS logs.
public struct TimelineEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case macSleep(String)            // reason, e.g. "Idle Sleep"
        case macWake(String)             // reason, e.g. "HID Activity"
        case displaySleep
        case displayWake
        case connected(Int)              // WindowServer display id
        case disconnected(Int)
        case modeList(display: Int, timing: Int, color: Int)
        case signal(String)              // what actually goes down the cable, e.g. "3840x2160 119hz YCbCr422_10bit"
        case identityChanged(from: String, to: String)  // the display's mode list / EDID identity flipped
    }

    /// `YYYY-MM-DD HH:MM:SS`
    public var time: String
    public var kind: Kind

    public init(time: String, kind: Kind) {
        self.time = time
        self.kind = kind
    }

    public var text: String {
        switch kind {
        case let .macSleep(r): return "Mac went to sleep" + (r.isEmpty ? "" : " (\(r))")
        case let .macWake(r): return "Mac woke up" + (r.isEmpty ? "" : " (\(r))")
        case .displaySleep: return "displays went to sleep"
        case .displayWake: return "displays woke up"
        case let .connected(d): return "display \(d) connected"
        case let .disconnected(d): return "display \(d) disconnected"
        case let .modeList(d, t, c): return "display \(d) reports \(t) timings / \(c) color formats"
        case let .signal(s): return "signal sent: \(s)"
        case let .identityChanged(a, b): return "display identity changed \(a) -> \(b) (different mode list)"
        }
    }
}

private func firstMatch(_ pattern: String, in s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}

/// Parses one line of `log show --style compact` output from WindowServer.
public func parseWindowServerLine(_ line: String) -> TimelineEvent? {
    guard let ts = firstMatch(#"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#, in: line)?[1] else { return nil }
    if line.contains("Broadcast: Did Wake") { return .init(time: ts, kind: .displayWake) }
    if line.contains("Broadcast: Did Sleep") { return .init(time: ts, kind: .displaySleep) }
    if let m = firstMatch(#"Processing hotplug "(in|out)" for display id: (\d+)"#, in: line), let d = Int(m[2]) {
        return .init(time: ts, kind: m[1] == "in" ? .connected(d) : .disconnected(d))
    }
    if let m = firstMatch(#"Display (\d+) (\d+) timing modes, (\d+) color modes"#, in: line),
       let d = Int(m[1]), let t = Int(m[2]), let c = Int(m[3]) {
        return .init(time: ts, kind: .modeList(display: d, timing: t, color: c))
    }
    if let m = firstMatch(#"set digital mode \[[^\]]*\] (.+?)\s*$"#, in: line) {
        return .init(time: ts, kind: .signal(m[1]))
    }
    if let m = firstMatch(#"Adjusting: '[^']*': (\S+) -> (\S+)"#, in: line) {
        return .init(time: ts, kind: .identityChanged(from: m[1], to: m[2]))
    }
    return nil
}

/// Parses one line of `pmset -g log` (only full Sleep and Wake entries).
public func parsePowerLogLine(_ line: String) -> TimelineEvent? {
    guard let m = firstMatch(#"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) [+-]\d{4} (Sleep|Wake)\s{2,}(.*)$"#, in: line) else { return nil }
    let ts = m[1], rest = m[3]
    if m[2] == "Sleep" {
        let reason = firstMatch(#"due to '([^']+)'"#, in: rest)?[1] ?? ""
        return .init(time: ts, kind: .macSleep(reason))
    } else {
        var reason = firstMatch(#"due to (.+?)(?: Using |$)"#, in: rest)?[1] ?? ""
        if reason.count > 40 { reason = String(reason.prefix(40)) + "…" }
        return .init(time: ts, kind: .macWake(reason))
    }
}

/// Sorts events by time and drops exact repeats within the same second
/// (WindowServer logs most hotplug and mode-list lines twice).
public func buildTimeline(_ events: [TimelineEvent], since: String? = nil) -> [TimelineEvent] {
    var out: [TimelineEvent] = []
    let sorted = events.enumerated()
        .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        .map(\.element)
        .filter { since == nil || $0.time >= since! }
    for e in sorted where !out.suffix(4).contains(e) {
        out.append(e)
    }
    return out
}

public struct SignalStat: Equatable, Sendable {
    public var signal: String
    public var count: Int
    public var lastSeen: String
}

/// Which signals were sent, how often, and when last.
public func signalStats(_ timeline: [TimelineEvent]) -> [SignalStat] {
    var stats: [String: SignalStat] = [:]
    for e in timeline {
        if case let .signal(s) = e.kind {
            var st = stats[s] ?? SignalStat(signal: s, count: 0, lastSeen: e.time)
            st.count += 1
            st.lastSeen = e.time
            stats[s] = st
        }
    }
    return stats.values.sorted { $0.lastSeen > $1.lastSeen }
}

/// Parses durations like `90m`, `24h`, `2d` into seconds.
public func parseDuration(_ s: String) -> TimeInterval? {
    guard let unit = s.last, let n = Double(s.dropLast()), n > 0 else { return nil }
    switch unit {
    case "m": return n * 60
    case "h": return n * 3600
    case "d": return n * 86400
    default: return nil
    }
}
