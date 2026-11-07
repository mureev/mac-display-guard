import AppKit
import CoreGraphics
import DisplayGuardCore

func log(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(message)")
}

/// Keeps matching displays on their best preferred mode.
final class Guardian {
    let rules: [CompiledRule]
    let pollSeconds: Double
    let dryRun: Bool

    private var lastState: [String: String] = [:]
    private var backoff: [String: Backoff] = [:]
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(config: Config, dryRun: Bool = false) throws {
        rules = try config.compiled()
        pollSeconds = config.effectivePollSeconds
        self.dryRun = dryRun
    }

    private func key(_ d: DisplayInfo) -> String { d.serial != 0 ? "s\(d.serial)" : "id\(d.id)" }

    /// One pass over all displays. Returns one status line per matching display.
    @discardableResult
    func check(reason: String, quiet: Bool = false) -> [String] {
        var lines: [String] = []
        let now = Date()
        for d in Displays.online() {
            guard let rule = rules.rule(for: d) else { continue }
            let k = key(d)
            let current = Displays.current(d.id)
            let offered = Displays.offered(d.id)
            let state: String
            switch decide(current: current, offered: offered, prefer: rule.prefer) {
            case let .keep(m):
                backoff[k]?.recordSuccess()
                state = "\(d.label): on \(m) (preferred)"
            case .nothingOffered:
                state = "\(d.label): on \(current.map(\.description) ?? "?"); none of the preferred modes is offered, leaving it"
            case let .switchTo(target):
                let from = current.map(\.description) ?? "?"
                if backoff[k, default: Backoff()].isActive(now: now) {
                    state = "\(d.label): on \(from), want \(target), paused after repeated failures"
                } else if dryRun {
                    state = "\(d.label): on \(from), would switch to \(target)"
                } else if Displays.set(d.id, to: target) {
                    backoff[k, default: Backoff()].recordSuccess()
                    log("\(d.label): \(from) -> \(target) [\(reason)]")
                    state = "\(d.label): on \(target) (preferred)"
                } else {
                    let paused = backoff[k, default: Backoff()].recordFailure(now: now)
                    log("\(d.label): switching \(from) -> \(target) failed [\(reason)]"
                        + (paused ? "; pausing this display for 5 min" : ""))
                    state = "\(d.label): on \(Displays.current(d.id).map(\.description) ?? "?"), switch to \(target) failed"
                }
            }
            lines.append(state)
            if !quiet, lastState[k] != state {
                log("state: \(state)")
                lastState[k] = state
            }
        }
        return lines
    }

    /// Runs a check shortly after an event (mode lists settle a moment after wake/reconnect).
    func schedule(reason: String, after seconds: Double = 1.5) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check(reason: reason) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        log("mac-display-guard \(appVersion) started (pid \(getpid())), \(rules.count) rule(s), poll every \(Int(pollSeconds)) s")

        let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            Unmanaged<Guardian>.fromOpaque(userInfo).takeUnretainedValue().schedule(reason: "display change")
        }
        CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(self).toOpaque())

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule(reason: "Mac woke")
        })
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule(reason: "displays woke")
        })

        let t = Timer(timeInterval: pollSeconds, repeats: true) { [weak self] _ in self?.check(reason: "poll") }
        t.tolerance = min(1, pollSeconds / 5)
        RunLoop.main.add(t, forMode: .common)
        timer = t

        check(reason: "start")
        RunLoop.main.run()
        exit(0)
    }
}
