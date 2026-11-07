import Foundation
import DisplayGuardCore

/// Runs a program and returns its stdout lines.
func runLines(_ path: String, _ args: [String]) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

enum Diagnose {
    static let predicate = """
        process == "WindowServer" AND (eventMessage CONTAINS "Processing hotplug" \
        OR eventMessage CONTAINS "timing modes" OR eventMessage CONTAINS "set digital mode" \
        OR eventMessage CONTAINS "Adjusting:" OR eventMessage CONTAINS "Broadcast: Did Wake" \
        OR eventMessage CONTAINS "Broadcast: Did Sleep")
        """

    static func run(last: String, showAll: Bool) -> Int32 {
        guard let seconds = parseDuration(last) else {
            fputs("diagnose: --last wants a duration like 90m, 24h or 2d\n", stderr)
            return 2
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let since = f.string(from: Date().addingTimeInterval(-seconds))

        print("Reading macOS logs for the last \(last) (this can take ~30 s)…\n")
        var events = runLines("/usr/bin/log", ["show", "--style", "compact", "--last", last, "--predicate", predicate])
            .compactMap(parseWindowServerLine)
        events += runLines("/usr/bin/pmset", ["-g", "log"]).compactMap(parsePowerLogLine)
        let timeline = buildTimeline(events, since: since)

        if timeline.isEmpty {
            print("No display events found. (Logs may have rotated; try a shorter --last right after the problem happens.)")
            return 0
        }

        print("TIMELINE")
        var lastSignal: String?
        for e in timeline {
            // Without --all, skip repeated identical signals and the Mac's short
            // maintenance sleeps (background wake/sleep cycles) to keep it readable.
            if !showAll {
                if case let .signal(s) = e.kind {
                    if s == lastSignal { continue }
                    lastSignal = s
                }
                if case let .macSleep(reason) = e.kind, reason == "Maintenance Sleep" { continue }
            }
            if case .macSleep = e.kind { print("") }
            print("  \(e.time)  \(e.text)")
        }

        let stats = signalStats(timeline)
        if !stats.isEmpty {
            print("\nSIGNALS SENT TO EXTERNAL DISPLAYS (the real format on the cable, not shown in System Settings)")
            let width = stats.map(\.signal.count).max() ?? 0
            for s in stats {
                print("  \(s.signal.padding(toLength: width, withPad: " ", startingAt: 0))  \(s.count)×  last \(s.lastSeen)")
            }
        }

        var lists: [Int: Int] = [:]
        for e in timeline { if case let .modeList(_, t, _) = e.kind { lists[t, default: 0] += 1 } }
        if lists.count > 1 {
            print("\nMODE LISTS: the display reported \(lists.count) different mode lists: "
                  + lists.keys.sorted().map { "\($0) timings (\(lists[$0]!)×)" }.joined(separator: ", "))
            print("  A display that comes back from sleep with a shorter list is a classic cause of a wrong refresh rate after wake.")
        }

        print("""

        HOW TO READ THIS
          • Note when your screen was black. The last "signal sent" before that moment is the suspect.
          • If one signal is always the black one, keep the display off the refresh rate behind it:
            put working modes in "prefer" (see `mac-display-guard list` for what the display offers).
          • "disconnected" right after "Mac went to sleep" means the link drops in sleep. On a dock,
            "Prevent automatic sleeping on power adapter when the display is off" avoids that.
          • Display numbers here are WindowServer ids; `mac-display-guard list` shows them as "id".
        """)
        return 0
    }
}
