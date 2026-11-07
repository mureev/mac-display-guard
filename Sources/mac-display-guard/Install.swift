import Foundation
import DisplayGuardCore

enum Paths {
    static let label = "io.github.mureev.mac-display-guard"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = home.appendingPathComponent(".config/mac-display-guard")
    static let config = configDir.appendingPathComponent("config.json")
    static let binDir = home.appendingPathComponent("Library/Application Support/mac-display-guard")
    static let bin = binDir.appendingPathComponent("mac-display-guard")
    static let agent = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let log = home.appendingPathComponent("Library/Logs/mac-display-guard.log")
    static var domain: String { "gui/\(getuid())" }
}

@discardableResult
func launchctl(_ args: String...) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

enum Install {
    static func install() -> Int32 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.config.path) else {
            fputs("No config yet. Run `mac-display-guard init`, edit \(Paths.config.path), then install.\n", stderr)
            return 1
        }
        do {
            _ = try Config.load(from: Paths.config).compiled()
        } catch {
            fputs("Config problem: \(error)\n", stderr)
            return 1
        }
        guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            fputs("Can't find my own executable.\n", stderr)
            return 1
        }
        do {
            try fm.createDirectory(at: Paths.binDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: Paths.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            if me.path != Paths.bin.path {
                if fm.fileExists(atPath: Paths.bin.path) { try fm.removeItem(at: Paths.bin) }
                try fm.copyItem(at: me, to: Paths.bin)
            }
            let plist: [String: Any] = [
                "Label": Paths.label,
                "ProgramArguments": [Paths.bin.path, "run"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Background",
                "LimitLoadToSessionType": "Aqua",
                "StandardOutPath": Paths.log.path,
                "StandardErrorPath": Paths.log.path,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: Paths.agent, options: .atomic)
        } catch {
            fputs("Install failed: \(error)\n", stderr)
            return 1
        }
        launchctl("bootout", "\(Paths.domain)/\(Paths.label)")   // ignore "not loaded"
        let r = launchctl("bootstrap", Paths.domain, Paths.agent.path)
        if r.status != 0 {
            fputs("launchctl bootstrap failed (\(r.status)): \(r.output)\n", stderr)
            return 1
        }
        print("""
        Installed and running.
          binary: \(Paths.bin.path)
          agent:  \(Paths.agent.path)
          config: \(Paths.config.path)
          log:    \(Paths.log.path)
        After editing the config, run `mac-display-guard restart`.
        """)
        return 0
    }

    static func uninstall() -> Int32 {
        launchctl("bootout", "\(Paths.domain)/\(Paths.label)")
        let fm = FileManager.default
        for url in [Paths.agent, Paths.bin] where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        try? fm.removeItem(at: Paths.binDir)
        print("Stopped and removed. Your config is kept at \(Paths.config.path) and the log at \(Paths.log.path).")
        return 0
    }

    static func restart() -> Int32 {
        let r = launchctl("kickstart", "-k", "\(Paths.domain)/\(Paths.label)")
        if r.status != 0 {
            fputs("Not running? (\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))) Try `mac-display-guard install`.\n", stderr)
            return 1
        }
        print("Restarted.")
        return 0
    }

    static func status() -> Int32 {
        let r = launchctl("print", "\(Paths.domain)/\(Paths.label)")
        if r.status == 0 {
            let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let state = lines.first { $0.hasPrefix("state = ") } ?? "state = ?"
            let pid = lines.first { $0.hasPrefix("pid = ") } ?? ""
            print("Agent: \(state)\(pid.isEmpty ? "" : ", \(pid)")")
        } else {
            print("Agent: not installed (run `mac-display-guard install`)")
        }
        print("Config: \(Paths.config.path)")
        if let tail = try? String(contentsOf: Paths.log, encoding: .utf8) {
            let last = tail.split(separator: "\n").suffix(5)
            if !last.isEmpty {
                print("Recent log (\(Paths.log.path)):")
                last.forEach { print("  \($0)") }
            }
        }
        return 0
    }
}
