import Foundation
import DisplayGuardCore

let appVersion = "0.1.0"

let usage = """
mac-display-guard \(appVersion): keeps external displays on modes that actually work.

USAGE
  mac-display-guard list                 displays, their current mode and every mode they offer
  mac-display-guard diagnose [--last 24h] [--all]
                                         what macOS did to your displays: sleeps, disconnects,
                                         mode lists, and the real signal sent down the cable
  mac-display-guard init [--force]       write a starter config from the current displays
  mac-display-guard check [--dry-run]    apply the config once
  mac-display-guard install              run in the background (per-user LaunchAgent)
  mac-display-guard status | restart | uninstall
  mac-display-guard run                  the background loop (what the LaunchAgent runs)

OPTIONS
  --config PATH                          default: ~/.config/mac-display-guard/config.json

CONFIG (JSON)
  {
    "pollSeconds": 5,
    "rules": [
      { "display": { "serial": 123456789, "label": "Odyssey G7" },
        "prefer": ["2560x1440@165 hidpi", "2560x1440@60 hidpi"] }
    ]
  }
  For each matching display the guard uses the first "prefer" mode the display offers,
  and switches back whenever macOS picks something else.
"""

var args = Array(CommandLine.arguments.dropFirst())

func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let configURL = takeOption("--config").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Paths.config

func loadConfig() -> Config {
    do {
        return try Config.load(from: configURL)
    } catch CocoaError.fileReadNoSuchFile {
        fputs("No config at \(configURL.path). Run `mac-display-guard init` first.\n", stderr)
        exit(1)
    } catch {
        fputs("Can't read \(configURL.path): \(error)\n", stderr)
        exit(1)
    }
}

func cmdList() -> Int32 {
    let rules = (try? Config.load(from: configURL).compiled()) ?? []
    let displays = Displays.online()
    if displays.isEmpty { print("No displays found."); return 0 }
    for d in displays {
        print("\(d.label)\(d.builtin ? "" : "")")
        print("  id \(d.id)   serial \(d.serial)   vendor \(d.vendor)   model \(d.model)\(d.builtin ? "   built-in" : "")")
        print("  now:   \(Displays.current(d.id).map(\.description) ?? "?")")
        if let r = rules.rule(for: d) {
            print("  rule:  prefers \(r.prefer.map(\.description).joined(separator: ", "))")
        }
        // Group offered modes by size, e.g. "2560x1440 hidpi  @ 165 120 60 30"
        var groups: [String: (ModeSpec, Set<Int>)] = [:]
        for m in Displays.offered(d.id) {
            let k = "\(m.width)x\(m.height)\(m.hidpi ? " hidpi" : "")"
            groups[k, default: (m, [])].1.insert(m.hz)
        }
        let sorted = groups.values.sorted {
            ($0.0.width, $0.0.height, $0.0.hidpi ? 1 : 0) > ($1.0.width, $1.0.height, $1.0.hidpi ? 1 : 0)
        }
        print("  offers:")
        for (m, hz) in sorted {
            let size = "\(m.width)x\(m.height)\(m.hidpi ? " hidpi" : "")"
            print("    \(size.padding(toLength: 18, withPad: " ", startingAt: 0)) @ \(hz.sorted(by: >).map(String.init).joined(separator: " "))")
        }
        print("")
    }
    print("Write modes in the config as e.g. \"2560x1440@165 hidpi\".")
    return 0
}

func cmdInit(force: Bool) -> Int32 {
    let fm = FileManager.default
    if fm.fileExists(atPath: configURL.path), !force {
        fputs("\(configURL.path) already exists (use --force to overwrite).\n", stderr)
        return 1
    }
    let externals = Displays.online().filter { !$0.builtin }
    if externals.isEmpty {
        fputs("No external display connected; connect it and run init again.\n", stderr)
        return 1
    }
    let rules = externals.compactMap { d -> Rule? in
        guard let now = Displays.current(d.id) else { return nil }
        let match = d.serial != 0
            ? DisplayMatch(serial: d.serial, label: d.name)
            : DisplayMatch(vendor: d.vendor, model: d.model, label: d.name)
        return Rule(display: match, prefer: [now.description])
    }
    let config = Config(pollSeconds: 5, rules: rules)
    do {
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.encoded().write(to: configURL, options: .atomic)
    } catch {
        fputs("Can't write \(configURL.path): \(error)\n", stderr)
        return 1
    }
    print("Wrote \(configURL.path):\n")
    print(String(decoding: (try? config.encoded()) ?? Data(), as: UTF8.self))
    print("""

    Each display prefers its current mode. Add fallbacks after it, in order, e.g.
      "prefer": ["2560x1440@165 hidpi", "2560x1440@60 hidpi"]
    and leave out any refresh rate that gives you a black screen.
    `mac-display-guard list` shows what each display offers. Then: mac-display-guard install
    """)
    return 0
}

func cmdCheck(dryRun: Bool) -> Int32 {
    do {
        let g = try Guardian(config: loadConfig(), dryRun: dryRun)
        let lines = g.check(reason: "manual check", quiet: true)
        if lines.isEmpty { print("No connected display matches the config.") }
        lines.forEach { print($0) }
        return 0
    } catch {
        fputs("Config problem: \(error)\n", stderr)
        return 1
    }
}

func cmdRun() -> Never {
    do {
        try Guardian(config: loadConfig()).run()
    } catch {
        fputs("Config problem: \(error)\n", stderr)
        // Don't let launchd restart us in a tight loop on a bad config.
        sleep(60)
        exit(1)
    }
}

let command = args.first ?? "help"
if !args.isEmpty { args.removeFirst() }

let status: Int32
switch command {
case "list": status = cmdList()
case "diagnose":
    let last = takeOption("--last") ?? "24h"
    status = Diagnose.run(last: last, showAll: takeFlag("--all"))
case "init": status = cmdInit(force: takeFlag("--force"))
case "check": status = cmdCheck(dryRun: takeFlag("--dry-run"))
case "run": cmdRun()
case "install": status = Install.install()
case "uninstall": status = Install.uninstall()
case "restart": status = Install.restart()
case "status": status = Install.status()
case "version", "--version", "-v": print(appVersion); status = 0
case "help", "--help", "-h": print(usage); status = 0
default:
    fputs("Unknown command \"\(command)\".\n\n\(usage)\n", stderr)
    status = 2
}
exit(status)
