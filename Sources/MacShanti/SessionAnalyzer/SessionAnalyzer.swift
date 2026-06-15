import Foundation
import GRDB

/// Learns which apps are habitually open together. When the same set of
/// user-facing apps appears 3+ times it's promoted to a named "session"
/// (e.g. "Coding", "Meetings"). When a heavy session is active, produces a
/// one-time nudge listing non-session apps worth closing.
final class SessionAnalyzer {

    struct SessionNudge: Equatable {
        let sessionName: String
        /// Apps that are running but not part of the recognized session.
        let appsToClose: [String]
    }

    /// Non-consuming view of the active session (for the popover). Unlike
    /// `currentSessionNudge`, this does not mark the session as nudged.
    struct SessionInfo: Equatable {
        let name: String
        let extras: [String]
    }

    /// A session is recognized after this many occurrences.
    private let promotionThreshold = 3

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// Record the current app combination and update occurrence counts.
    func record(snapshot: Snapshot) {
        let apps = Self.significantApps(snapshot)
        guard apps.count >= 2 else { return }
        let signature = Self.signature(for: apps)
        let name = Self.classify(apps)

        try? database.dbQueue.write { db in
            if var existing = try SessionRecord
                .filter(Column("signature") == signature)
                .fetchOne(db) {
                existing.occurrences += 1
                existing.lastSeen = snapshot.timestamp
                try existing.update(db)
            } else {
                var record = SessionRecord(
                    id: nil,
                    signature: signature,
                    name: name,
                    occurrences: 1,
                    lastSeen: snapshot.timestamp,
                    nudged: false
                )
                try record.insert(db)
            }
        }
    }

    /// If the current combination matches a recognized, heavy session that has
    /// not yet been nudged, return a one-time nudge and mark it as shown.
    func currentSessionNudge(for snapshot: Snapshot) -> SessionNudge? {
        // Only nudge under real memory pressure.
        guard snapshot.pressure != .normal else { return nil }

        let runningApps = Set(snapshot.runningAppNames)
        guard runningApps.count >= 2 else { return nil }

        return try? database.dbQueue.write { db -> SessionNudge? in
            // Find the best-matching recognized session whose apps are a subset
            // of what's currently running.
            let candidates = try SessionRecord
                .filter(Column("occurrences") >= promotionThreshold)
                .filter(Column("nudged") == false)
                .fetchAll(db)

            for var session in candidates.sorted(by: { $0.occurrences > $1.occurrences }) {
                let sessionApps = Set(session.signature.split(separator: ",").map(String.init))
                guard sessionApps.isSubset(of: runningApps) else { continue }

                let extras = runningApps.subtracting(sessionApps).sorted()
                guard !extras.isEmpty else { continue }

                session.nudged = true
                try session.update(db)
                return SessionNudge(sessionName: session.name, appsToClose: extras)
            }
            return nil
        }
    }

    /// Read-only: which recognized session is active and which running apps
    /// aren't part of it. Safe to call on every snapshot for the UI.
    func currentSessionInfo(for snapshot: Snapshot) -> SessionInfo? {
        guard snapshot.pressure != .normal else { return nil }
        let runningApps = Set(snapshot.runningAppNames)
        guard runningApps.count >= 2 else { return nil }

        return try? database.dbQueue.read { db -> SessionInfo? in
            let candidates = try SessionRecord
                .filter(Column("occurrences") >= promotionThreshold)
                .order(Column("occurrences").desc)
                .fetchAll(db)

            for session in candidates {
                let sessionApps = Set(session.signature.split(separator: ",").map(String.init))
                guard sessionApps.isSubset(of: runningApps) else { continue }
                let extras = runningApps.subtracting(sessionApps).sorted()
                guard !extras.isEmpty else { continue }
                return SessionInfo(name: session.name, extras: extras)
            }
            return nil
        }
    }

    // MARK: - Helpers

    /// User-facing apps with a meaningful memory footprint (≥ 50 MB).
    private static func significantApps(_ snapshot: Snapshot) -> [String] {
        let names = snapshot.processes
            .filter { $0.bundleIdentifier != nil && $0.rssBytes >= 50 * 1_048_576 }
            .map { $0.name }
        return Array(Set(names)).sorted()
    }

    private static func signature(for apps: [String]) -> String {
        apps.sorted().joined(separator: ",")
    }

    /// Heuristic naming based on well-known app keywords.
    private static func classify(_ apps: [String]) -> String {
        let lower = apps.map { $0.lowercased() }
        func contains(_ keywords: [String]) -> Bool {
            lower.contains { name in keywords.contains { name.contains($0) } }
        }

        if contains(["xcode", "code", "terminal", "iterm", "intellij", "pycharm", "sublime", "vim"]) {
            return "Coding"
        }
        if contains(["zoom", "teams", "meet", "webex", "slack", "facetime"]) {
            return "Meetings"
        }
        if contains(["photoshop", "illustrator", "figma", "sketch", "final cut", "premiere"]) {
            return "Design"
        }
        if contains(["safari", "chrome", "firefox", "arc"]) && apps.count <= 3 {
            return "Browsing"
        }
        return "Session of \(apps.count) apps"
    }
}
