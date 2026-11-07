import Foundation
import Testing
@testable import DisplayGuardCore

@Suite struct ModeSpecTests {
    @Test func parsesCanonicalForm() {
        #expect(ModeSpec(parsing: "2560x1440@165 hidpi") == ModeSpec(width: 2560, height: 1440, hz: 165, hidpi: true))
        #expect(ModeSpec(parsing: "1920x1080@60") == ModeSpec(width: 1920, height: 1080, hz: 60, hidpi: false))
    }

    @Test func toleratesLooseInput() {
        #expect(ModeSpec(parsing: " 2560 × 1440 @ 119.88Hz HiDPI ") == ModeSpec(width: 2560, height: 1440, hz: 120, hidpi: true))
        #expect(ModeSpec(parsing: "3840x2160@60 scaled")?.hidpi == true)
    }

    @Test func rejectsGarbage() {
        #expect(ModeSpec(parsing: "2560x1440") == nil)
        #expect(ModeSpec(parsing: "fast") == nil)
        #expect(ModeSpec(parsing: "0x0@60") == nil)
    }

    @Test func roundTrips() {
        let m = ModeSpec(width: 2560, height: 1440, hz: 165, hidpi: true)
        #expect(ModeSpec(parsing: m.description) == m)
    }
}

@Suite struct DecisionTests {
    let m165 = ModeSpec(width: 2560, height: 1440, hz: 165, hidpi: true)
    let m120 = ModeSpec(width: 2560, height: 1440, hz: 120, hidpi: true)
    let m60 = ModeSpec(width: 2560, height: 1440, hz: 60, hidpi: true)

    @Test func keepsPreferredMode() {
        #expect(decide(current: m165, offered: [m165, m120, m60], prefer: [m165, m60]) == .keep(m165))
    }

    @Test func leavesTheBlackModeForTheBestOffered() {
        // The case this tool was written for: after wake the display offers no 165 Hz,
        // macOS falls back to 120 Hz (black on that monitor), and 60 Hz is the way out.
        #expect(decide(current: m120, offered: [m120, m60], prefer: [m165, m60]) == .switchTo(m60))
    }

    @Test func upgradesWhenTheBetterModeReturns() {
        #expect(decide(current: m60, offered: [m165, m120, m60], prefer: [m165, m60]) == .switchTo(m165))
    }

    @Test func doesNothingWhenNothingPreferredIsOffered() {
        #expect(decide(current: m120, offered: [m120], prefer: [m165, m60]) == .nothingOffered)
    }
}

@Suite struct BackoffTests {
    @Test func pausesAfterThreeFailures() {
        var b = Backoff(maxFailures: 3, pause: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(b.recordFailure(now: t0) == false)
        #expect(b.recordFailure(now: t0) == false)
        #expect(b.recordFailure(now: t0) == true)
        #expect(b.isActive(now: t0.addingTimeInterval(299)))
        #expect(!b.isActive(now: t0.addingTimeInterval(301)))
    }

    @Test func successResets() {
        var b = Backoff(maxFailures: 2, pause: 300)
        let t0 = Date()
        _ = b.recordFailure(now: t0)
        b.recordSuccess()
        #expect(b.recordFailure(now: t0) == false)
    }
}

@Suite struct ConfigTests {
    let json = """
    {
      "pollSeconds": 5,
      "rules": [
        { "display": { "serial": 123456789, "label": "Odyssey G7" },
          "prefer": ["2560x1440@165 hidpi", "2560x1440@60 hidpi"] },
        { "display": { "name": "dell" }, "prefer": ["1920x1080@60"] }
      ]
    }
    """

    @Test func decodesAndCompiles() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let rules = try c.compiled()
        #expect(rules.count == 2)
        #expect(rules[0].prefer.first == ModeSpec(width: 2560, height: 1440, hz: 165, hidpi: true))
    }

    @Test func matchesBySerialAndByName() throws {
        let rules = try JSONDecoder().decode(Config.self, from: Data(json.utf8)).compiled()
        let g7 = DisplayInfo(id: 3, serial: 123456789, vendor: 19501, model: 29375, name: "Odyssey G7", builtin: false)
        let dell = DisplayInfo(id: 4, serial: 0, vendor: 4268, model: 1, name: "DELL U2723QE", builtin: false)
        let other = DisplayInfo(id: 5, serial: 42, vendor: 1, model: 1, name: "LG", builtin: false)
        #expect(rules.rule(for: g7)?.prefer.count == 2)
        #expect(rules.rule(for: dell)?.prefer.first?.hz == 60)
        #expect(rules.rule(for: other) == nil)
    }

    @Test func rejectsBadModesAndEmptyMatches() {
        let bad = Config(rules: [Rule(display: DisplayMatch(serial: 1), prefer: ["165Hz"])])
        #expect(throws: ConfigError.self) { try bad.compiled() }
        let empty = Config(rules: [Rule(display: DisplayMatch(label: "x"), prefer: ["1920x1080@60"])])
        #expect(throws: ConfigError.self) { try empty.compiled() }
    }
}

@Suite struct LogParsingTests {
    @Test func windowServerLines() {
        let lines = [
            #"2026-11-07 00:55:23.568 Df WindowServer[616:1404] [com.apple.SkyLight:display] [ Display:Power      ] Broadcast: Did Wake"#,
            #"2026-11-07 00:55:23.568 Df WindowServer[616:1404] [com.apple.SkyLight:display] [ Display:Hotplug    ] Processing hotplug "out" for display id: 3 (CA)"#,
            #"2026-11-07 00:55:33.995 Df WindowServer[616:1573] [com.apple.coreanimation:WindowServer] Display 3 41 timing modes, 22 color modes"#,
            #"2026-11-07 00:55:34.625 Df WindowServer[616:1573] [com.apple.coreanimation:WindowServer] set digital mode [90 71] 3840x2160 119hz YCbCr422_10bit"#,
            #"2026-11-07 00:55:34.286 Df WindowServer[616:1404] [com.apple.SkyLight:display] [ Display:Persist    ] Adjusting: 'C49305F6-6339-49FC-ABB2-5216CC78511B': 7BAA-01ED1636D84C -> CB72-E60014E0210A"#,
            #"2026-11-07 00:55:23.577 Df WindowServer[616:1404] [com.apple.SkyLight:SystemGestures] Detaching targetIdentifier 0/7A1"#,
        ]
        let kinds = lines.compactMap(parseWindowServerLine).map(\.kind)
        #expect(kinds == [
            .displayWake,
            .disconnected(3),
            .modeList(display: 3, timing: 41, color: 22),
            .signal("3840x2160 119hz YCbCr422_10bit"),
            .identityChanged(from: "7BAA-01ED1636D84C", to: "CB72-E60014E0210A"),
        ])
    }

    @Test func powerLogLines() {
        let sleep = "2026-11-07 00:52:49 +0300 Sleep               \tEntering Sleep state due to 'Idle Sleep':TCPKeepAlive=disabled Using AC (Charge:80%) 3 secs"
        let wake = "2026-11-07 00:55:23 +0300 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to HID Activity Using AC (Charge:80%)"
        let requests = "2026-11-07 00:52:51 +0300 Wake Requests       \t[process=dasd request=SleepService]"
        #expect(parsePowerLogLine(sleep)?.kind == .macSleep("Idle Sleep"))
        #expect(parsePowerLogLine(wake)?.kind == .macWake("HID Activity"))
        #expect(parsePowerLogLine(requests) == nil)
    }

    @Test func timelineSortsDedupesAndFilters() {
        let a = TimelineEvent(time: "2026-11-07 00:55:33", kind: .modeList(display: 3, timing: 41, color: 22))
        let b = TimelineEvent(time: "2026-11-07 00:55:23", kind: .displayWake)
        let old = TimelineEvent(time: "2026-11-06 10:00:00", kind: .displayWake)
        let t = buildTimeline([a, a, b, old], since: "2026-11-07 00:00:00")
        #expect(t == [b, a])
    }

    @Test func durations() {
        #expect(parseDuration("90m") == 5400)
        #expect(parseDuration("24h") == 86400)
        #expect(parseDuration("2d") == 172800)
        #expect(parseDuration("soon") == nil)
    }
}
