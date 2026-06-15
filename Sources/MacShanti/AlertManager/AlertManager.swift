import Foundation
import AppKit
import UserNotifications
import GRDB

/// Owns all user notifications: proactive pressure alerts (with Quit/Snooze/
/// Dismiss actions), leak warnings, session nudges, and the daily 8pm summary.
/// Also acts as the `UNUserNotificationCenterDelegate` to handle button taps.
final class AlertManager: NSObject, UNUserNotificationCenterDelegate {

    // Notification categories.
    private static let pressureCategory = "MACSHANTI_PRESSURE"
    private static let leakCategory = "MACSHANTI_LEAK"
    private static let sessionCategory = "MACSHANTI_SESSION"
    private static let summaryCategory = "MACSHANTI_SUMMARY"

    // Action identifiers.
    private static let quitAction = "QUIT_TOP_APP"
    private static let snoozeAction = "SNOOZE_30"
    private static let dismissAction = "DISMISS"
    private static let restartLeakAction = "RESTART_LEAK"

    /// Swap level counted as a "swap hit" for the daily summary.
    private let swapThresholdBytes: UInt64 = 1_073_741_824 // 1 GB

    private let database: AppDatabase
    private let preferences: PreferenceStore
    private let center = UNUserNotificationCenter.current()

    /// Don't re-fire pressure alerts more than once every 10 minutes.
    private var lastPressureAlert: Date?
    private let pressureCooldown: TimeInterval = 10 * 60

    private var dailyTimer: Timer?

    init(database: AppDatabase, preferences: PreferenceStore) {
        self.database = database
        self.preferences = preferences
        super.init()
        center.delegate = self
    }

    // MARK: - Authorization & categories

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("MacShanti: notification auth error: \(error)") }
            if granted { self.registerCategories(topAppName: nil) }
        }
    }

    /// (Re)register categories. The pressure category's Quit action title is
    /// rebuilt with the current top app's name so the button reads "Quit Safari".
    private func registerCategories(topAppName: String?) {
        let quitTitle = topAppName.map { "Quit \($0)" } ?? "Quit Top App"
        let pressure = UNNotificationCategory(
            identifier: Self.pressureCategory,
            actions: [
                UNNotificationAction(identifier: Self.quitAction, title: quitTitle, options: [.destructive]),
                UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 30 min", options: []),
                UNNotificationAction(identifier: Self.dismissAction, title: "Dismiss", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
        let leak = UNNotificationCategory(
            identifier: Self.leakCategory,
            actions: [
                UNNotificationAction(identifier: Self.restartLeakAction, title: "Quit & restart", options: [.destructive]),
                UNNotificationAction(identifier: Self.dismissAction, title: "Dismiss", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
        let session = UNNotificationCategory(
            identifier: Self.sessionCategory,
            actions: [UNNotificationAction(identifier: Self.dismissAction, title: "Got it", options: [])],
            intentIdentifiers: [],
            options: []
        )
        let summary = UNNotificationCategory(
            identifier: Self.summaryCategory, actions: [], intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([pressure, leak, session, summary])
    }

    // MARK: - Evaluation entry point

    /// Called after each snapshot. Fires whichever alerts are warranted.
    func evaluate(snapshot: Snapshot,
                  recommendations: [Recommendation],
                  leaks: [LeakDetector.LeakFlag],
                  session: SessionAnalyzer.SessionNudge?) {
        evaluatePressure(snapshot, recommendations: recommendations)
        for leak in leaks { notifyLeak(leak) }
        if let session { notifySession(session) }
    }

    private func evaluatePressure(_ snapshot: Snapshot, recommendations: [Recommendation]) {
        // Decide the tier. Critical = already in trouble (kernel-confirmed).
        // Predictive = trend says we're heading there — fire *before* the kernel
        // reacts, which is the whole point of MacShanti.
        let tier: Tier
        if snapshot.pressure == .critical {
            tier = .critical
        } else if snapshot.trend.isEarlyWarning {
            tier = .predictive
        } else {
            return
        }

        if let last = lastPressureAlert, Date().timeIntervalSince(last) < pressureCooldown {
            return
        }

        // Prefer the same idle-aware apps the popover recommends quitting; fall
        // back to raw top consumers only if there are no actionable recs.
        let primaryName: String
        let primaryPID: Int32
        let names: String

        let actionable = recommendations.filter {
            ($0.kind == .quit || $0.kind == .restart) && $0.pid != nil && $0.appName != nil
        }
        if let first = actionable.first {
            primaryName = first.appName!
            primaryPID = first.pid!
            names = actionable.prefix(2).map(Self.describe).joined(separator: " and ")
        } else {
            let candidates = snapshot.topProcesses(5)
                .filter { !preferences.shouldSuppress($0.name) }
            guard let primary = candidates.first else { return }
            primaryName = primary.name
            primaryPID = primary.pid
            names = candidates.prefix(2).map { "\($0.name) (\(Int($0.rssMB)) MB)" }.joined(separator: " and ")
        }

        lastPressureAlert = Date()
        registerCategories(topAppName: primaryName)

        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.pressureCategory
        content.sound = .default
        content.userInfo = [
            "primaryPID": Int(primaryPID),
            "primaryName": primaryName
        ]

        switch tier {
        case .critical:
            content.title = "Memory pressure is high"
            let reason = "RAM \(Int(snapshot.usedRatio * 100))% used, \(String(format: "%.1f", Double(snapshot.freeMB) / 1024)) GB free."
            content.body = "\(reason) Biggest consumers: \(names). Consider quitting one."
        case .predictive:
            content.title = "Memory is filling up"
            let headroom = snapshot.trend.headroomMinutes.map { "about \($0) min of headroom left" }
                ?? "running low soon"
            content.body = "At the current rate you have \(headroom). Quitting \(names) now keeps you ahead."
        }

        post(content, id: "pressure")
    }

    private enum Tier { case predictive, critical }

    /// Idle-aware phrasing for a recommended app, e.g.
    /// "Slack (idle 1h 20m, ~850 MB)" — matches what the popover shows.
    private static func describe(_ rec: Recommendation) -> String {
        let name = rec.appName ?? "an app"
        let mem = rec.estimatedFreeMB.map { RecommendationEngine.formatMB($0) }
        if let idle = rec.idleMinutes, idle >= 5 {
            let memPart = mem.map { ", ~\($0)" } ?? ""
            return "\(name) (idle \(RecommendationEngine.formatDuration(idle))\(memPart))"
        }
        if rec.kind == .restart {
            return "\(name) (possible leak)"
        }
        if let mem {
            return "\(name) (~\(mem))"
        }
        return name
    }

    private func notifyLeak(_ leak: LeakDetector.LeakFlag) {
        guard !preferences.shouldSuppress(leak.name) else { return }
        let minutes = Int(leak.backgroundCPUSeconds / 60)
        let content = UNMutableNotificationContent()
        content.title = "Possible memory leak"
        content.body = "\(leak.name) has used \(minutes) min of CPU in the background. A restart may free memory."
        content.categoryIdentifier = Self.leakCategory
        content.sound = .default
        content.userInfo = ["primaryPID": Int(leak.pid), "primaryName": leak.name]
        post(content, id: "leak-\(leak.pid)")
    }

    private func notifySession(_ nudge: SessionAnalyzer.SessionNudge) {
        let extras = nudge.appsToClose.prefix(3).joined(separator: ", ")
        let content = UNMutableNotificationContent()
        content.title = "\(nudge.sessionName) session detected"
        content.body = "These apps aren't part of your \(nudge.sessionName) session: \(extras). Closing them could free memory."
        content.categoryIdentifier = Self.sessionCategory
        content.sound = .default
        post(content, id: "session-\(nudge.sessionName)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: "\(id)-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        center.add(request) { error in
            if let error { NSLog("MacShanti: failed to post notification: \(error)") }
        }
    }

    // MARK: - Action handling (UNUserNotificationCenterDelegate)

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = info["primaryPID"] as? Int
        let name = info["primaryName"] as? String

        switch response.actionIdentifier {
        case Self.quitAction, Self.restartLeakAction:
            if let pid { quitApp(pid: pid_t(pid)) }
        case Self.snoozeAction:
            if let name { preferences.recordSnooze(appName: name) }
        default:
            break
        }
        completionHandler()
    }

    private func quitApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.terminate() // graceful; falls back to forceTerminate if needed by caller
    }

    // MARK: - Daily summary

    /// Schedule a repeating daily summary at the given time-of-day.
    func scheduleDailySummary(at time: DateComponents) {
        dailyTimer?.invalidate()
        guard let next = Calendar.current.nextDate(after: Date(),
                                                   matching: time,
                                                   matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: next, interval: 86_400, repeats: true) { [weak self] _ in
            self?.sendDailySummary()
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    /// Summarize how many times swap was hit today and which apps were active
    /// during those moments.
    func sendDailySummary() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let result: (hits: Int, apps: [String]) = (try? database.dbQueue.read { db in
            let swapHits = try MemorySnapshotRecord
                .filter(Column("timestamp") >= startOfDay)
                .filter(Column("swapUsedBytes") >= Int64(self.swapThresholdBytes))
                .fetchAll(db)

            guard !swapHits.isEmpty else { return (0, []) }
            let ids = swapHits.compactMap(\.id)

            // Top app names sampled during swap-pressure snapshots.
            let offenders = try ProcessSampleRecord
                .filter(ids.contains(Column("snapshotId")))
                .order(Column("rssBytes").desc)
                .fetchAll(db)

            var counts: [String: Int] = [:]
            for o in offenders { counts[o.name, default: 0] += 1 }
            let topApps = counts.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
            return (swapHits.count, Array(topApps))
        }) ?? (0, [])

        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.summaryCategory
        content.title = "MacShanti daily summary"
        if result.hits == 0 {
            content.body = "No swap pressure today — your memory stayed healthy. 🎉"
        } else {
            let apps = result.apps.isEmpty ? "various apps" : result.apps.joined(separator: ", ")
            content.body = "Swap was hit \(result.hits) time\(result.hits == 1 ? "" : "s") today, most often alongside: \(apps)."
        }
        post(content, id: "summary")
    }
}
