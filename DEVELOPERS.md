# MacShanti — Developer Notes

Technical reference for building on top of MacShanti. For end-user docs see
[README.md](README.md).

MacShanti is a menubar-only (`LSUIElement`) macOS app written in Swift +
SwiftUI, persisting to SQLite via [GRDB](https://github.com/groue/GRDB.swift).
It is structured as a Swift Package (no `.xcodeproj`), targeting **macOS 13+**.

---

## Build, run, package

```bash
swift build                     # compile (Debug)
swift run                       # build + launch from the CLI
./Scripts/make_app.sh release   # build + assemble a signed MacShanti.app under build/
open build/MacShanti.app        # launch the bundled app
```

`make_app.sh` produces a proper `.app` bundle (with `Info.plist`) and ad-hoc
code-signs it. A real bundle is required for reliable `UNUserNotification`
delivery and for the `SMAppService` login item; running the bare SPM binary
works for quick iteration but notifications are flaky.

Dependencies are pinned in `Package.resolved` (GRDB 6.x). The `Info.plist` is
**not** an SPM resource — it's embedded in the binary via a linker
`-sectcreate` flag (see `Package.swift`) and copied into the bundle by
`make_app.sh`.

---

## Architecture

Four subsystems, wired together in `AppDelegate`, communicating through plain
value types. The collection thread never touches UIKit/SwiftUI; results are
marshalled to the main queue before publishing.

```
                 ┌────────────────────────────────────────────┐
                 │              MemoryMonitor                   │
   every 30s ───▶│  SystemMemory.aggregate()  (Mach/sysctl)    │
                 │  SystemMemory.processSamples() (libproc)     │
                 │  → Snapshot (value type) → SQLite            │
                 └───────────────────┬──────────────────────────┘
                                     │ onSnapshot (main queue)
        ┌────────────────────────────┼────────────────────────────┐
        ▼                            ▼                            ▼
┌───────────────┐          ┌──────────────────┐         ┌──────────────────┐
│ SessionAnalyzer│         │  AlertManager     │         │ MonitorState     │
│ ActivityTracker│         │  (UNUserNotif.)   │         │ (ObservableObject)│
│ LeakDetector   │         │  daily summary    │         │   ▲              │
└───────┬────────┘         └──────────────────┘         └───┼──────────────┘
        │ feeds                                              │ @Published
        ▼                                                    ▼
   RecommendationEngine.make() ──────────────────▶  MenuBarController + PopoverView
```

### Module map

| Path | Responsibility |
| --- | --- |
| `MemoryMonitor/SystemMemory.swift` | All low-level syscalls (see below). Pure, stateless. |
| `MemoryMonitor/MemoryMonitor.swift` | 30s `DispatchSourceTimer`, builds `Snapshot`, persists, fires `onSnapshot`. `refresh()` forces an off-schedule sample. |
| `MemoryMonitor/TrendAnalyzer.swift` | Rolling-window free-RAM slope + reclaim-rate → predictive early-warning. In-memory. |
| `SessionAnalyzer/SessionAnalyzer.swift` | Learns app co-occurrence → named "sessions". |
| `SessionAnalyzer/ActivityTracker.swift` | Per-app recency for the LRU policy via `NSWorkspace` activation events, with the 30s snapshot as backstop. In-memory. |
| `SessionAnalyzer/LeakDetector.swift` | Accumulates background CPU per pid; flags > 60 min. In-memory. |
| `AlertManager/AlertManager.swift` | All notifications + actions + daily 8pm summary. `UNUserNotificationCenterDelegate`. |
| `AlertManager/PreferenceStore.swift` | "Never suggest" list + snooze / time-based suppression. |
| `MenuBarController/MenuBarController.swift` | `NSStatusItem` dot + `NSPopover`; owns popover actions (quit app, never-suggest). |
| `MenuBarController/PopoverView.swift` | SwiftUI popover UI. |
| `MenuBarController/MonitorState.swift` | `ObservableObject` bridging monitor → SwiftUI. |
| `Services/LoginItemManager.swift` | `SMAppService` login-item registration. |
| `Models/*` | Value types (`Snapshot`, `ProcessSample`, `PressureLevel`, `Recommendation`) + GRDB records. |

---

## System APIs used

All in `SystemMemory.swift`:

- **`host_statistics64(HOST_VM_INFO64)`** → `vm_statistics64`. Used = (active +
  wired + compressed) × page size; free = (free + inactive) × page size.
- **`sysctlbyname("vm.swapusage")`** → `xsw_usage` for swap used/total.
- **`sysctlbyname("kern.memorystatus_vm_pressure_level")`** → the kernel's live
  pressure verdict (`1` normal / `2` warning / `4` critical) — the same signal
  behind Activity Monitor's memory-pressure graph, and the **primary** input to
  the dot color.
- **`proc_listpids(PROC_ALL_PIDS)`** + **`proc_pidinfo(PROC_PIDTASKINFO)`** →
  per-process `pti_resident_size` (RSS) and `pti_total_user + pti_total_system`
  (cumulative CPU, nanoseconds).
- **`NSWorkspace.runningApplications` / `frontmostApplication`** → friendly app
  names, bundle ids, and which pid is frontmost.

> Constants `PROC_ALL_PIDS` (1) and `PROC_PIDTASKINFO` (4) are referenced as
> literals because they're C macros not always imported into Swift.

---

## Pressure classification

The final dot color is `max(reactiveBaseline, predictiveEscalation)`.

**Reactive baseline** —
`PressureLevel.classify(kernelPressureRaw:usedRatio:freeRatio:swapUsedBytes:)`:

1. Start from the **kernel pressure level** (the authoritative "are we in
   trouble now" signal).
2. **Escalate only when free RAM is scarce** (`freeRatio < 0.10`): high swap or
   high RAM fill are ignored while RAM is plentiful, because macOS retains
   swapped-out pages indefinitely — absolute swap size is *not* a live-pressure
   signal. This is why 4 GB of swap with 6 GB free reads green.

**Predictive escalation** (`TrendAnalyzer`, `MemoryMonitor/TrendAnalyzer.swift`)
— this is what makes MacShanti *preventive* rather than reactive, since the
kernel signal is lagging by definition. Over a rolling ~6-min window it:

1. Fits the **least-squares slope of free RAM** and projects the time until free
   RAM reaches the danger floor (10% of total). If that ETA is within the lead
   window (5 min) *and* free RAM is already in the "watch zone" (< 30%) *and* the
   decline is sustained (≥ 4 samples, not rising on the latest step) → **early
   warning** → dot goes yellow.
2. Corroborates with the **rate of swap-outs + compressions** (`vm_statistics64`
   cumulative counters): active swapping while free RAM < 20% also raises the
   flag.
3. **De-escalates immediately** when free RAM ticks back up (e.g. you closed a
   tab) — calm on the way up, responsive on the way down.

Tunables (window, lead time, watch-zone ceiling, floor, sustain count, swap-rate
threshold) are constants at the top of `TrendAnalyzer`; current values are the
"Balanced" profile. The verdict is carried on `Snapshot.trend` (`TrendInfo`).

`AlertManager` fires on two tiers (shared 10-min cooldown): **critical** when
`snapshot.pressure == .critical`, or **predictive** when
`snapshot.trend.isEarlyWarning` — the predictive notification quotes the
projected headroom in minutes.

---

## Recommendation ranking (the "don't always say quit Chrome" logic)

`RecommendationEngine.make(...)` produces an ordered `[Recommendation]`:

1. **Leaks** (highest priority) — from `LeakDetector.currentLeakFlags()`.
2. **Quit candidates** — only under pressure. Candidates are filtered to real
   apps (bundle id present), **excluding the frontmost app**, ≥ 200 MB, and not
   suppressed. Ranked by an LRU-weighted score:

   ```
   score = rssMB × (1 + idleMinutes / 30)
   ```

   where `idleMinutes` comes from `ActivityTracker` (time since the app was last
   frontmost). A long-idle medium app can outrank a large app you just used.
3. **Session tidy-up** — advisory row listing running apps not part of the
   recognized session.

Suppression (`PreferenceStore.shouldSuppress`) gates everything: never-suggest
list, active 30-min snoozes, and learned per-hour auto-suppression.

---

## Persistence (GRDB / SQLite)

DB lives at `~/Library/Application Support/MacShanti/macshanti.sqlite`. Schema +
migrations in `Database/AppDatabase.swift`; records in `Models/Records.swift`.

| Table | Purpose |
| --- | --- |
| `memory_snapshot` | One row per 30s sample (aggregate memory + pressure). |
| `process_sample` | Top 40 processes per snapshot (FK → `memory_snapshot`, cascade delete). |
| `session_record` | Learned app combinations, occurrence counts, nudge flag. |
| `app_preference` | Per-app "never suggest". |
| `snooze_event` | Snoozes with hour-of-day + expiry, for time-based suppression. |

Snapshots older than 14 days are pruned (`pruneSnapshots`, ~hourly).

`ActivityTracker` and `LeakDetector` state are **in-memory only** and reset on
relaunch — a deliberate simplification (a freshly launched app shouldn't look
"idle"). Persisting them is a natural enhancement.

---

## Extension points / ideas

- **Persist idle & leak state** across restarts (currently in-memory).
- **Fuzzy session matching** — `SessionAnalyzer` requires an *exact* app-set
  match; Jaccard similarity would generalize better.
- **Per-app growth attribution** — name the app whose RSS is climbing fastest in
  the predictive warning (`TrendAnalyzer` could track per-app slopes too).
- **Per-app leak baselines** instead of one global 60-min threshold.
- **Expose the sensitivity profile** (Balanced/Early/Conservative) as a user
  setting instead of compile-time constants in `TrendAnalyzer`.
- **Preferences window** — manage the never-suggest list, thresholds, and
  cadence from a real settings UI (today it's popover context-menus + a DB).
- **Charts** — the snapshot history in SQLite is ready to graph.

---

## Caveats

- `proc_pidinfo` only returns task info for processes the current user can
  inspect; some system/root processes are skipped.
- "Last used" is tracked from real app-activation events (`NSWorkspace`) plus
  the 30s snapshot as a backstop. A background media player you actively listen
  to will still look idle — handle via "Never suggest".
- Reliable notifications + the login item need a code-signed `.app` bundle
  (`make_app.sh` ad-hoc signs one). For distribution outside your own machine,
  wrap this package in an Xcode target with a Developer ID + hardened runtime;
  the module layout drops in unchanged.
