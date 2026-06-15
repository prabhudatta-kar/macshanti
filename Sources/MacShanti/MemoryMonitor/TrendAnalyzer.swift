import Foundation

/// Turns the stream of snapshots into a *predictive* signal so MacShanti can
/// warn before the kernel reports pressure. It fits the slope of free RAM over a
/// rolling window and projects when free RAM will hit a danger floor; it also
/// watches the rate of swap/compression activity as a corroborating early sign.
///
/// Tuned for the "Balanced" sensitivity: it only predicts once you're in the
/// lower part of your RAM (the "watch zone"), requires a sustained decline
/// (several samples, not one blip), and de-escalates immediately when free RAM
/// ticks back up.
final class TrendAnalyzer {

    // MARK: Tunables (Balanced)

    /// Rolling window length (~6 min at a 30s cadence).
    private let maxPoints = 12
    /// Minimum samples before we'll make any prediction (~2 min — "sustained").
    private let minSamples = 4
    /// Don't predict while free RAM is above this fraction — plenty of headroom.
    private let watchCeilingFraction = 0.30
    /// The "danger floor" we project toward.
    private let dangerFloorFraction = 0.10
    /// Warn if free RAM is projected to reach the floor within this lead time.
    private let leadWindow: TimeInterval = 300 // 5 min
    /// Corroborating swap trigger: active swapping while free RAM is this low.
    private let swapTriggerFreeFraction = 0.20
    /// Pages/min of swap-out+compression that counts as "actively swapping".
    private let reclaimRateThresholdPerMin: Double = 2_000

    private struct Point {
        let t: Date
        let free: Double
        let total: Double
        let reclaim: Double
    }
    private var buffer: [Point] = []

    /// Feed one sample; returns the current predictive verdict.
    func update(freeBytes: UInt64,
                totalBytes: UInt64,
                reclaimCumulative: UInt64,
                now: Date) -> TrendInfo {
        buffer.append(Point(t: now,
                            free: Double(freeBytes),
                            total: Double(totalBytes),
                            reclaim: Double(reclaimCumulative)))
        if buffer.count > maxPoints {
            buffer.removeFirst(buffer.count - maxPoints)
        }

        guard buffer.count >= minSamples, let last = buffer.last, let first = buffer.first else {
            return TrendInfo()
        }

        let total = last.total
        let currentFree = last.free
        let floor = total * dangerFloorFraction

        // Slope of free RAM vs. time (bytes/sec) by least squares.
        let t0 = first.t
        let xs = buffer.map { $0.t.timeIntervalSince(t0) }
        let ys = buffer.map { $0.free }
        let slope = Self.linearSlope(xs: xs, ys: ys)

        // De-escalate fast: if free RAM rose on the most recent step, no warning.
        let rising = buffer.count >= 2 && last.free > buffer[buffer.count - 2].free

        // Projected time to reach the danger floor.
        var eta: Double? = nil
        if slope < 0 {
            eta = max(0, (currentFree - floor) / (-slope))
        }

        // Reclaim (swap/compression) rate over the window, in pages/min.
        let windowSeconds = last.t.timeIntervalSince(first.t)
        let reclaimDelta = max(0, last.reclaim - first.reclaim)
        let reclaimPerMin = windowSeconds > 0 ? reclaimDelta / windowSeconds * 60 : 0
        let swappingNow = reclaimPerMin >= reclaimRateThresholdPerMin

        let inWatchZone = currentFree < total * watchCeilingFraction

        // Primary: sustained decline projected to hit the floor within lead time,
        // while we're in the watch zone and not already at the floor.
        let projectionWarning = !rising
            && slope < 0
            && inWatchZone
            && currentFree > floor
            && (eta ?? .infinity) <= leadWindow

        // Corroborating: actively swapping while free RAM is getting low.
        let swapWarning = !rising
            && swappingNow
            && currentFree < total * swapTriggerFreeFraction

        return TrendInfo(
            isEarlyWarning: projectionWarning || swapWarning,
            secondsToFloor: eta,
            freeSlopeBytesPerSec: slope,
            swappingNow: swappingNow
        )
    }

    /// Least-squares slope (dy/dx). Returns 0 if x has no variance.
    private static func linearSlope(xs: [Double], ys: [Double]) -> Double {
        let n = Double(xs.count)
        guard n > 1 else { return 0 }
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return 0 }
        return (n * sumXY - sumX * sumY) / denom
    }
}
