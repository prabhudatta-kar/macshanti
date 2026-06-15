import Foundation

/// One per-process sample taken at a point in time.
struct ProcessSample: Identifiable, Equatable, Codable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let bundleIdentifier: String?
    let rssBytes: UInt64
    /// Cumulative CPU time (user + system) since the process launched, in seconds.
    let cpuTimeSeconds: Double
    let isFrontmost: Bool

    var rssMB: Double { Double(rssBytes) / 1_048_576.0 }
}

/// Predictive trend signal derived from recent snapshots — lets us warn
/// *before* the kernel reports pressure.
struct TrendInfo: Equatable {
    /// True when free RAM is projected to hit the danger floor within the
    /// lead-time window, or the system has started actively swapping.
    var isEarlyWarning: Bool = false
    /// Projected seconds until free RAM reaches the danger floor (nil if not declining).
    var secondsToFloor: Double? = nil
    /// Rate of change of free RAM (bytes/sec); negative = filling up.
    var freeSlopeBytesPerSec: Double = 0
    /// True if the system is actively swapping pages out right now.
    var swappingNow: Bool = false

    /// Headroom in whole minutes, for display.
    var headroomMinutes: Int? {
        guard let s = secondsToFloor, s.isFinite else { return nil }
        return max(0, Int(s / 60))
    }
}

/// A full system snapshot: aggregate memory + the per-process breakdown.
/// This is the value type passed through the pipeline (not the DB record).
struct Snapshot: Equatable {
    let timestamp: Date
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let pressure: PressureLevel
    var trend: TrendInfo = TrendInfo()
    let processes: [ProcessSample]

    var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    var usedMB: Double { Double(usedBytes) / 1_048_576.0 }
    var freeMB: Double { Double(freeBytes) / 1_048_576.0 }
    var totalMB: Double { Double(totalBytes) / 1_048_576.0 }
    var swapUsedMB: Double { Double(swapUsedBytes) / 1_048_576.0 }

    /// Top N memory consumers, descending by RSS.
    func topProcesses(_ n: Int) -> [ProcessSample] {
        processes.sorted { $0.rssBytes > $1.rssBytes }.prefix(n).map { $0 }
    }

    /// User-facing (regular) apps currently running, by display name.
    var runningAppNames: [String] {
        Array(Set(processes.filter { $0.bundleIdentifier != nil }.map { $0.name })).sorted()
    }
}
