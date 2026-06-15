import Foundation

/// A single actionable suggestion surfaced in the popover.
struct Recommendation: Identifiable, Equatable {
    enum Kind: Equatable {
        case restart      // possible leak — quit & relaunch
        case quit         // heavy memory user — quit to free RAM
        case closeSession // apps that aren't part of the active session
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String?
    /// App display name (used for the "never suggest" action). nil for advisory rows.
    let appName: String?
    /// Target process for a one-tap Quit button. nil for advisory rows.
    let pid: Int32?
    /// Button label, e.g. "Quit". nil ⇒ advisory row with no button.
    let actionLabel: String?
    /// Approximate memory this would free (MB), for notification phrasing.
    var estimatedFreeMB: Double? = nil
    /// Minutes the app has been idle (unused), for notification phrasing.
    var idleMinutes: Int? = nil
}

/// Builds the ranked recommendation list shown in the popover from the latest
/// snapshot plus leak/session analysis, honoring user suppression preferences.
enum RecommendationEngine {

    /// Only suggest quitting apps using at least this much RAM.
    private static let minQuitMB: Double = 200
    /// Cap the number of "quit" suggestions so the popover stays scannable.
    private static let maxQuitSuggestions = 3

    static func make(snapshot: Snapshot,
                     leaks: [LeakDetector.LeakFlag],
                     session: SessionAnalyzer.SessionInfo?,
                     preferences: PreferenceStore,
                     activity: ActivityTracker,
                     now: Date = Date()) -> [Recommendation] {
        var recs: [Recommendation] = []
        var handled = Set<String>()

        // 1. Leaks first — highest signal.
        for leak in leaks where !preferences.shouldSuppress(leak.name, now: now) {
            let minutes = Int(leak.backgroundCPUSeconds / 60)
            recs.append(Recommendation(
                id: "leak-\(leak.pid)",
                kind: .restart,
                title: "Restart \(leak.name)",
                detail: "Used \(minutes) min of CPU while in the background. Restarting may free memory.",
                appName: leak.name,
                pid: leak.pid,
                actionLabel: "Quit"
            ))
            handled.insert(leak.name)
        }

        // 2. Reclaim memory from apps you're NOT using. Under pressure, rank
        //    quit candidates by idle-time × memory (an LRU-style policy) so we
        //    surface the heavy app you abandoned an hour ago — never the app
        //    you're actively in (the frontmost app is excluded outright).
        if snapshot.pressure != .normal {
            let frontmost = snapshot.processes.first(where: { $0.isFrontmost })?.name

            let scored = snapshot.processes
                .filter { $0.bundleIdentifier != nil }       // real, quittable apps
                .filter { $0.name != frontmost }             // never nag the active app
                .filter { $0.rssMB >= minQuitMB }            // worth the bother
                .filter { !handled.contains($0.name) }
                .filter { !preferences.shouldSuppress($0.name, now: now) }
                .map { proc -> (proc: ProcessSample, idleMin: Int, score: Double) in
                    let idleMin = Int(activity.idleSeconds(for: proc.name, now: now) / 60)
                    // Idle time amplifies the memory weight: a 300 MB app idle
                    // 2h can outrank a 1 GB app you touched 5 min ago.
                    let score = proc.rssMB * (1.0 + Double(idleMin) / 30.0)
                    return (proc, idleMin, score)
                }
                .sorted { $0.score > $1.score }

            for entry in scored.prefix(maxQuitSuggestions) {
                let detail = entry.idleMin >= 5
                    ? "Unused for \(formatDuration(entry.idleMin)) · frees about \(formatMB(entry.proc.rssMB))."
                    : "Not in active use · frees about \(formatMB(entry.proc.rssMB))."
                recs.append(Recommendation(
                    id: "quit-\(entry.proc.pid)",
                    kind: .quit,
                    title: "Quit \(entry.proc.name)",
                    detail: detail,
                    appName: entry.proc.name,
                    pid: entry.proc.pid,
                    actionLabel: "Quit",
                    estimatedFreeMB: entry.proc.rssMB,
                    idleMinutes: entry.idleMin
                ))
                handled.insert(entry.proc.name)
            }
        }

        // 3. Session tidy-up — advisory, no button.
        if let session, !session.extras.isEmpty {
            let names = session.extras.prefix(4).joined(separator: ", ")
            recs.append(Recommendation(
                id: "session-\(session.name)",
                kind: .closeSession,
                title: "Tidy your \(session.name) session",
                detail: "Not part of it: \(names).",
                appName: nil,
                pid: nil,
                actionLabel: nil
            ))
        }

        return recs
    }

    static func formatMB(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    static func formatDuration(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes) min"
    }
}
