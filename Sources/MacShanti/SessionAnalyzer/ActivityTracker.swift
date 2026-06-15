import Foundation

/// Tracks per-app recency of use ("last time this app was the frontmost app")
/// so recommendations can prefer apps the user hasn't touched in a while — an
/// LRU-style policy — instead of always naming the biggest RAM user (which is
/// usually whatever you're actively working in).
///
/// State is in-memory and resets on relaunch; that's fine — a freshly launched
/// app shouldn't be flagged as "idle" anyway, and `firstSeen` guards against it.
final class ActivityTracker {

    private var lastActive: [String: Date] = [:]
    private var firstSeen: [String: Date] = [:]

    /// Record activity from a snapshot: stamp the frontmost app as "active now".
    func update(snapshot: Snapshot) {
        let now = snapshot.timestamp
        for proc in snapshot.processes {
            if firstSeen[proc.name] == nil { firstSeen[proc.name] = now }
            if proc.isFrontmost { lastActive[proc.name] = now }
        }
        // Forget apps that are no longer running.
        let live = Set(snapshot.processes.map(\.name))
        lastActive = lastActive.filter { live.contains($0.key) }
        firstSeen = firstSeen.filter { live.contains($0.key) }
    }

    /// Seconds since the app was last frontmost. If it has never been frontmost,
    /// measure from when we first saw it (so newly-opened background apps aren't
    /// instantly considered stale).
    func idleSeconds(for name: String, now: Date = Date()) -> TimeInterval {
        if let last = lastActive[name] { return now.timeIntervalSince(last) }
        if let first = firstSeen[name] { return now.timeIntervalSince(first) }
        return 0
    }
}
