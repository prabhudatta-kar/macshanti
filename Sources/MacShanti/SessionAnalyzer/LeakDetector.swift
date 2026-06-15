import Foundation

/// Flags a process as a potential leak when it accumulates more than
/// `threshold` of CPU time *while never being the frontmost app*.
///
/// We track the delta of cumulative CPU time between samples and only add it to
/// a process's "background CPU budget" when the process was not frontmost during
/// that interval. Per-pid state resets implicitly when a pid is reused (a new
/// launch starts from a lower cumulative CPU time).
final class LeakDetector {

    struct LeakFlag: Equatable {
        let pid: Int32
        let name: String
        let backgroundCPUSeconds: Double
    }

    /// 60 minutes of background CPU time.
    private let threshold: TimeInterval = 60 * 60

    private struct Tracked {
        var lastCPU: Double
        var backgroundCPU: Double
        var lastName: String
    }

    private var tracked: [Int32: Tracked] = [:]
    /// Pids we've already flagged, so we don't re-alert every 30s.
    private var alreadyFlagged: Set<Int32> = []

    /// All processes currently over the background-CPU threshold (for the UI),
    /// regardless of whether they've already been alerted.
    func currentLeakFlags() -> [LeakFlag] {
        tracked.compactMap { pid, t in
            t.backgroundCPU >= threshold
                ? LeakFlag(pid: pid, name: t.lastName, backgroundCPUSeconds: t.backgroundCPU)
                : nil
        }
    }

    /// Update tracking from a snapshot and return any *newly* flagged leaks.
    func evaluate(snapshot: Snapshot) -> [LeakFlag] {
        var newFlags: [LeakFlag] = []
        let livePIDs = Set(snapshot.processes.map { $0.pid })

        for proc in snapshot.processes {
            if var t = tracked[proc.pid] {
                let delta = proc.cpuTimeSeconds - t.lastCPU
                if delta < 0 {
                    // pid reused for a different process — reset.
                    t = Tracked(lastCPU: proc.cpuTimeSeconds, backgroundCPU: 0, lastName: proc.name)
                    alreadyFlagged.remove(proc.pid)
                } else {
                    if !proc.isFrontmost {
                        t.backgroundCPU += delta
                    }
                    t.lastCPU = proc.cpuTimeSeconds
                    t.lastName = proc.name
                }
                tracked[proc.pid] = t

                if t.backgroundCPU >= threshold && !alreadyFlagged.contains(proc.pid) {
                    alreadyFlagged.insert(proc.pid)
                    newFlags.append(LeakFlag(pid: proc.pid,
                                             name: proc.name,
                                             backgroundCPUSeconds: t.backgroundCPU))
                }
            } else {
                tracked[proc.pid] = Tracked(lastCPU: proc.cpuTimeSeconds,
                                            backgroundCPU: 0,
                                            lastName: proc.name)
            }
        }

        // Drop state for processes that have exited.
        tracked = tracked.filter { livePIDs.contains($0.key) }
        alreadyFlagged = alreadyFlagged.intersection(livePIDs)

        return newFlags
    }
}
