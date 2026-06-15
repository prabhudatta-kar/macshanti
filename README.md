# MacShanti

A native macOS menubar app (Swift, SwiftUI, GRDB) that **proactively manages
memory before the system slows down**. It samples system + per-process memory
every 30 seconds, learns your usage patterns, and nudges you to free memory
*before* you hit swap.

Targets **macOS 13+**.

## What it does

- **Menubar dot** — green / yellow / red based on live memory pressure.
- **Popover** — total RAM used/free, swap used, and the top 5 memory-consuming
  apps with their RAM in MB.
- **Proactive alerts** — when RAM > 75% **or** swap > 1 GB, a notification names
  the top 2 offenders with actions: **Quit [App]**, **Snooze 30 min**, **Dismiss**.
- **Leak detection** — a process that burns > 60 min of CPU while never being
  frontmost gets flagged as a possible leak, with a restart suggestion.
- **Session learning** — app combinations seen 3+ times become named sessions
  ("Coding", "Meetings", …). Under pressure during a known session, a one-time
  nudge lists the non-session apps worth closing.
- **Preferences** — per-app "never suggest" list; snoozing an app at the same
  hour 2+ times auto-suppresses it at that hour.
- **Daily summary** — at 8pm, a notification recaps how many times swap was hit
  and which apps were involved.

## Architecture

Clear separation across four subsystems, wired together in `AppDelegate`:

| Module | Responsibility | Key files |
| --- | --- | --- |
| **MemoryMonitor** | Data collection (`host_statistics64`, `proc_pidinfo`, `vm.swapusage`), 30s timer, SQLite persistence | `MemoryMonitor/SystemMemory.swift`, `MemoryMonitor/MemoryMonitor.swift` |
| **SessionAnalyzer** | Pattern learning (sessions) + leak detection | `SessionAnalyzer/SessionAnalyzer.swift`, `SessionAnalyzer/LeakDetector.swift` |
| **AlertManager** | `UNUserNotification` alerts, action handling, daily summary, preferences gating | `AlertManager/AlertManager.swift`, `AlertManager/PreferenceStore.swift` |
| **MenuBarController** | `NSStatusItem` colored dot + SwiftUI popover | `MenuBarController/*.swift` |

Persistence is **GRDB** over SQLite (`Database/AppDatabase.swift`), with
migrations and 14-day snapshot retention.

## Build & run

```bash
# Resolve deps and build
swift build

# Or assemble a proper .app bundle (recommended for notifications)
./Scripts/make_app.sh release
open build/MacShanti.app
```

On first launch macOS will prompt for **notification permission**. The app runs
as an `LSUIElement` (menubar only — no Dock icon).

## Notes & caveats

- `proc_pidinfo` only returns task info for processes the current user can
  inspect; system/root processes may be skipped. RSS is real resident size.
- Per-process CPU time comes from `proc_taskinfo` (user + system, nanoseconds).
- Reliable `UNUserNotification` delivery (and the Quit-app action) works best
  from a code-signed `.app` bundle; `Scripts/make_app.sh` ad-hoc signs one.
- For App Store / hardened-runtime distribution you'd wrap this SPM package in
  an Xcode app target; the module layout here drops in unchanged.
