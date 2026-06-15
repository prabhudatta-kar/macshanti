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
                detail: "\(minutes) min of background CPU — possible leak. Restarting may free memory.",
                appName: leak.name,
                pid: leak.pid,
                actionLabel: "Quit"
            ))
            handled.insert(leak.name)
        }

        // 2. Memory hogs — only worth surfacing under actual pressure, and only
        //    for real apps (bundle id present) we can safely quit.
        if snapshot.pressure != .normal {
            var quitCount = 0
            for proc in snapshot.topProcesses(6) {
                guard proc.bundleIdentifier != nil else { continue }
                guard !handled.contains(proc.name) else { continue }
                guard proc.rssMB >= minQuitMB else { continue }
                guard !preferences.shouldSuppress(proc.name, now: now) else { continue }

                recs.append(Recommendation(
                    id: "quit-\(proc.pid)",
                    kind: .quit,
                    title: "Quit \(proc.name)",
                    detail: "Frees about \(formatMB(proc.rssMB)).",
                    appName: proc.name,
                    pid: proc.pid,
                    actionLabel: "Quit"
                ))
                handled.insert(proc.name)
                quitCount += 1
                if quitCount >= maxQuitSuggestions { break }
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
}
