# mac-display-guard

**Your Mac's external monitor is black after sleep. System Settings says it's connected. Unplugging the cable fixes it, until tomorrow.** This tool finds out what macOS is actually sending to the monitor, and keeps it on a mode that shows a picture.

---

## The short version

On some monitor + dock + Mac combinations, one particular mode simply doesn't work: the Mac sends it, the monitor shows black. macOS doesn't know that. After a wake, a replug or a lid change it often picks exactly that mode, because the "good" mode is temporarily missing from the list the monitor reports.

`mac-display-guard` does three things:

1. **`diagnose`** reads the macOS logs and shows you, for the last day, every sleep, wake, disconnect, mode-list change, and **the real signal sent down the cable** (e.g. `3840x2160 119hz YCbCr422_10bit`). System Settings never shows you that last part, and it's usually the culprit.
2. **`list`** shows what each display offers right now.
3. **`install`** runs a small background guard: for each display in your config, it uses the first mode in your `prefer` list that the display offers, and switches back within seconds whenever macOS picks something else.

## The long version (how this was found)

The monitor in question was a 32" Samsung Odyssey G7 behind a Dell WD22TB4 Thunderbolt dock, used as "looks like 2560×1440" at 165 Hz. Every morning: black screen, "connected". The internet's advice was the usual mix: toggle the refresh rate after wake, turn off "Wake for network access", install a sleep-hook. All of it was tried. None of it worked.

What did work was reading what WindowServer writes to the system log, which turns out to be quite candid:

- When the Mac slept, the monitor dropped off the link a couple of seconds later.
- On wake it came back, but sometimes with a **shorter mode list**: 41 timings instead of 44, no 165 Hz.
- macOS, unable to restore 165 Hz, fell back to 120 Hz, which on this monitor and dock goes down the cable as `3840x2160 119hz YCbCr422_10bit`. **That signal was black. Every time.** 165 Hz (`YCbCr422_8bit`) and 60 Hz (`RGB 10-bit`) were fine.
- The "toggle the refresh rate after wake" hook made it worse: it switched *to* 120 Hz on its way somewhere else, and when the somewhere else wasn't offered it just stayed there.

Once you know that the problem is one specific signal, the fix is boring: never stay on it. Use the best mode that's offered, and fall back to one that works. That's this tool.

Two things that helped and need no software at all:

- **On a dock, let only the display sleep, not the Mac.** System Settings → Battery → Options → *Prevent automatic sleeping on power adapter when the display is off*. The link stays up overnight, so there is no reconnect lottery in the morning.
- **Turn the monitor off and on.** If the monitor is stuck reporting the short mode list (your good refresh rate is missing from System Settings), a power cycle of the *monitor* restores the full list. Replugging the cable worked only sometimes.

## Install

Needs macOS 13 or later and Apple's Swift toolchain (`xcode-select --install` is enough; full Xcode not required).

```sh
git clone https://github.com/mureev/mac-display-guard.git
cd mac-display-guard
make build
.build/release/mac-display-guard diagnose          # optional: see what happened in the last 24 h
.build/release/mac-display-guard list             # what your displays offer
.build/release/mac-display-guard init             # writes ~/.config/mac-display-guard/config.json
# edit the config: put your working modes in "prefer", best first
.build/release/mac-display-guard check --dry-run  # what it would do now
make install                                      # copies the binary, starts the LaunchAgent
```

`install` copies the binary to `~/Library/Application Support/mac-display-guard/` and adds a per-user LaunchAgent (`io.github.mureev.mac-display-guard`). Nothing runs as root.

## Config

`~/.config/mac-display-guard/config.json`:

```json
{
  "pollSeconds": 5,
  "rules": [
    {
      "display": { "serial": 123456789, "label": "Odyssey G7" },
      "prefer": ["2560x1440@165 hidpi", "2560x1440@60 hidpi"]
    }
  ]
}
```

- **`display`** picks the monitor: any of `serial`, `vendor`, `model` (numbers from `list`) or `name` (case-insensitive substring, e.g. `"Odyssey"`). All given fields must match. `label` is a note for you.
- **`prefer`** lists modes, best first, as `WIDTHxHEIGHT@HZ`, plus `hidpi` for scaled ("looks like") modes. Copy them from `list`. **Leave out the refresh rate that gives you a black screen.**
- **`pollSeconds`**: the guard reacts to display events immediately; this is the safety-net check. Default 5.

After editing: `mac-display-guard restart`.

## Commands

| | |
|---|---|
| `list` | displays, current mode, every mode offered |
| `diagnose [--last 24h] [--all]` | timeline of sleeps, wakes, disconnects, mode lists and real signals |
| `init [--force]` | starter config from the connected displays |
| `check [--dry-run]` | apply the config once |
| `install` / `uninstall` / `restart` / `status` | the background guard |

## What `diagnose` looks like

```
  2026-11-07 00:52:49  Mac went to sleep (Idle Sleep)
  2026-11-07 00:55:23  displays woke up
  2026-11-07 00:55:23  display 3 disconnected
  2026-11-07 00:55:23  Mac woke up (HID Activity)
  2026-11-07 00:55:33  display 3 reports 41 timings / 22 color formats
  2026-11-07 00:55:33  display 3 connected
  2026-11-07 00:55:34  signal sent: 3840x2160 60hz RGBCalibrated_10bit
  2026-11-07 00:55:34  display identity changed 7BAA-… -> CB72-… (different mode list)
  2026-11-07 00:55:34  signal sent: 3840x2160 119hz YCbCr422_10bit     <- black screen
```

Note the time your screen was black; the last `signal sent` before it is the suspect.

## How it works, and what it costs

- Public CoreGraphics APIs only: `CGDisplayCopyAllDisplayModes` to see what's offered, `CGConfigureDisplayWithDisplayMode` (saved permanently, like System Settings) to switch.
- It wakes up on display reconfiguration events and on Mac/display wake, plus a light timer (`pollSeconds`) as a safety net.
- It never touches a display that doesn't match a rule, and never switches when none of your preferred modes is offered.
- If a switch fails three times in a row, it leaves that display alone for 5 minutes instead of fighting the OS.
- It holds no power assertions: your Mac and displays sleep exactly as before.
- Measured on the test Mac: CPU too small for `ps` to show (0.00 s over 30 s), about 17 MB of memory. Forcing the black mode by hand, the guard had the display back on its preferred mode within 2 seconds.
- Log: `~/Library/Logs/mac-display-guard.log` (only changes and actions). `mac-display-guard run --verbose` in a terminal also prints every display and wake event.

## Limits

- It chooses **modes**; it can't pick the pixel format macOS sends for a mode. If a mode is black, avoid the mode.
- It **enforces** your config: if you change the resolution or refresh rate of a guarded display in System Settings, it switches back. Change the config instead, or `uninstall`.
- It can't make the monitor report modes it isn't reporting. If your best mode is missing, power-cycle the monitor (see above); the guard picks it up within seconds.
- Tested on one setup so far (MacBook Air M5, macOS 27, Odyssey G7 via Dell WD22TB4). Issues and reports from other monitors are welcome.

## Related

- [BetterDisplay](https://github.com/waydabber/BetterDisplay): the full-featured display app; if you already use it, look there first.
- [displayplacer](https://github.com/jakehilborn/displayplacer): command-line display arrangement and modes.
- [refreshing](https://github.com/m4rkw/refreshing): works around a different issue (kernel panics above 120 Hz on Apple Silicon).

## License

MIT
