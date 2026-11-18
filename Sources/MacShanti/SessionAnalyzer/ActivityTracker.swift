import AppKit
import Foundation

/// Tracks per-app recency of use ("last time this app was the frontmost app")
/// so recommendations can prefer apps the user hasn't touched in a while — an
/// LRU-style policy — instead of always naming the biggest RAM user (which is
/// usually whatever you're actively working in).
///
/// Two signal sources:
/// 1. **Event-driven** `NSWorkspace.didActivateApplicationNotification`: every
///    app switch is stamped the moment it happens (exact, even if the app is
///    only frontmost between two 30s samples).
/// 2. **30s snapshot backstop** (`update(snapshot:)`): keeps refreshing the app
///    that stays frontmost, seeds `firstSeen`, and prunes apps that quit.
///
/// State is in-memory and resets on relaunch; that's fine — a freshly launched
/// app shouldn't be flagged as "idle" anyway, and `firstSeen` guards against it.
///
/// Only used on the main queue (wired in `AppDelegate`), and the activation
/// observer is delivered on the main queue, so no locking is needed.
final class ActivityTracker {

    private var lastActive: [String: Date] = [:]
    private var firstSeen: [String: Date] = [:]
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName else { return }
            let now = Date()
            if self.firstSeen[name] == nil { self.firstSeen[name] = now }
            self.lastActive[name] = now
        }
    }

    deinit {
        if let token = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// Backstop: stamp the currently-frontmost app as "active now", seed
    /// `firstSeen`, and forget apps that quit.
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
