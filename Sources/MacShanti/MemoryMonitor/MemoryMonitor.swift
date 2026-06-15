import Foundation
import GRDB

/// Collects a full system snapshot every `interval` seconds on a background
/// queue, persists it to SQLite, and hands the value type to `onSnapshot`.
final class MemoryMonitor {

    /// Called on the main queue after each successful sample.
    var onSnapshot: ((Snapshot) -> Void)?

    private let database: AppDatabase
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.macshanti.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private let trendAnalyzer = TrendAnalyzer()

    init(database: AppDatabase, interval: TimeInterval = 30) {
        self.database = database
        self.interval = interval
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Trigger an immediate off-schedule sample (e.g. right after the user
    /// quits an app from the popover, so the UI updates within ~1s).
    func refresh() {
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        let snapshot = collect()
        persist(snapshot)

        tickCount += 1
        // Prune retention roughly hourly (every 120 ticks at 30s cadence).
        if tickCount % 120 == 0 {
            database.pruneSnapshots()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }

    /// Build a `Snapshot` value type from the current system state.
    func collect() -> Snapshot {
        let now = Date()
        let agg = SystemMemory.aggregate()
        let processes = SystemMemory.processSamples()
        let usedRatio = agg.totalBytes > 0 ? Double(agg.usedBytes) / Double(agg.totalBytes) : 0
        let freeRatio = agg.totalBytes > 0 ? Double(agg.freeBytes) / Double(agg.totalBytes) : 0

        // Reactive baseline (kernel + low-RAM safety net)…
        let baseline = PressureLevel.classify(kernelPressureRaw: agg.kernelPressureRaw,
                                              usedRatio: usedRatio,
                                              freeRatio: freeRatio,
                                              swapUsedBytes: agg.swapUsedBytes)
        // …escalated by the *predictive* trend so we go yellow before trouble.
        let trend = trendAnalyzer.update(freeBytes: agg.freeBytes,
                                         totalBytes: agg.totalBytes,
                                         reclaimCumulative: agg.reclaimEventsCumulative,
                                         now: now)
        let pressure = max(baseline, trend.isEarlyWarning ? .warning : .normal)

        return Snapshot(
            timestamp: now,
            totalBytes: agg.totalBytes,
            usedBytes: agg.usedBytes,
            freeBytes: agg.freeBytes,
            swapUsedBytes: agg.swapUsedBytes,
            swapTotalBytes: agg.swapTotalBytes,
            pressure: pressure,
            trend: trend,
            // Keep only the top 40 consumers in the DB to bound row growth.
            processes: processes.sorted { $0.rssBytes > $1.rssBytes }
        )
    }

    private func persist(_ snapshot: Snapshot) {
        do {
            try database.dbQueue.write { db in
                var record = MemorySnapshotRecord(
                    id: nil,
                    timestamp: snapshot.timestamp,
                    totalBytes: Int64(snapshot.totalBytes),
                    usedBytes: Int64(snapshot.usedBytes),
                    freeBytes: Int64(snapshot.freeBytes),
                    swapUsedBytes: Int64(snapshot.swapUsedBytes),
                    swapTotalBytes: Int64(snapshot.swapTotalBytes),
                    pressureLevel: snapshot.pressure.rawValue
                )
                try record.insert(db)
                guard let snapshotId = record.id else { return }

                for proc in snapshot.processes.prefix(40) {
                    var p = ProcessSampleRecord(
                        id: nil,
                        snapshotId: snapshotId,
                        pid: Int(proc.pid),
                        name: proc.name,
                        bundleIdentifier: proc.bundleIdentifier,
                        rssBytes: Int64(proc.rssBytes),
                        cpuTimeSeconds: proc.cpuTimeSeconds,
                        isFrontmost: proc.isFrontmost
                    )
                    try p.insert(db)
                }
            }
        } catch {
            NSLog("MacShanti: failed to persist snapshot: \(error)")
        }
    }
}
