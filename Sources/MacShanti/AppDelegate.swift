import AppKit
import Combine

/// Owns the full object graph and wires the four subsystems together:
/// MemoryMonitor (collection) → SessionAnalyzer (learning) / AlertManager
/// (notifications) / MenuBarController (UI).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var database: AppDatabase!
    private var monitor: MemoryMonitor!
    private var sessionAnalyzer: SessionAnalyzer!
    private var leakDetector: LeakDetector!
    private var alertManager: AlertManager!
    private var menuBarController: MenuBarController!
    private var preferences: PreferenceStore!
    private let state = MonitorState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            database = try AppDatabase.makeShared()
        } catch {
            NSLog("MacShanti: failed to open database: \(error)")
            database = AppDatabase.makeInMemory()
        }

        preferences = PreferenceStore(database: database)

        sessionAnalyzer = SessionAnalyzer(database: database)
        leakDetector = LeakDetector()
        alertManager = AlertManager(database: database, preferences: preferences)
        alertManager.requestAuthorization()

        monitor = MemoryMonitor(database: database, interval: 30)

        menuBarController = MenuBarController(
            state: state,
            preferences: preferences,
            onRefresh: { [weak self] in self?.monitor.refresh() }
        )

        monitor.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            // Feed the analysis pipeline.
            self.sessionAnalyzer.record(snapshot: snapshot)
            let newLeaks = self.leakDetector.evaluate(snapshot: snapshot)

            // Build the recommendations shown in the popover.
            let recommendations = RecommendationEngine.make(
                snapshot: snapshot,
                leaks: self.leakDetector.currentLeakFlags(),
                session: self.sessionAnalyzer.currentSessionInfo(for: snapshot),
                preferences: self.preferences
            )
            self.state.update(snapshot: snapshot, recommendations: recommendations)

            // Proactive notifications (use newly-flagged leaks + one-time nudge).
            self.alertManager.evaluate(
                snapshot: snapshot,
                leaks: newLeaks,
                session: self.sessionAnalyzer.currentSessionNudge(for: snapshot)
            )
        }
        monitor.start()

        // Daily 8pm summary scheduler.
        alertManager.scheduleDailySummary(at: DateComponents(hour: 20, minute: 0))
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}
