import Foundation
import GRDB

/// Manages user preferences that gate suggestions:
///  - a per-app "never suggest" list, and
///  - time-based suppression learned from snoozes (snooze an app at a given
///    hour 2+ times ⇒ auto-suppress that app at that hour).
final class PreferenceStore {

    private let database: AppDatabase
    /// Auto-suppress an app at an hour after this many snoozes at that hour.
    private let autoSuppressAfterSnoozes = 2

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Never-suggest list

    func isNeverSuggested(_ appName: String) -> Bool {
        (try? database.dbQueue.read { db in
            try AppPreferenceRecord
                .filter(Column("appName") == appName)
                .filter(Column("neverSuggest") == true)
                .fetchCount(db) > 0
        }) ?? false
    }

    func setNeverSuggest(_ appName: String, _ value: Bool) {
        try? database.dbQueue.write { db in
            var record = AppPreferenceRecord(appName: appName, neverSuggest: value)
            try record.save(db)
        }
    }

    func neverSuggestedApps() -> [String] {
        (try? database.dbQueue.read { db in
            try AppPreferenceRecord
                .filter(Column("neverSuggest") == true)
                .fetchAll(db)
                .map(\.appName)
        }) ?? []
    }

    // MARK: - Snooze & time-based suppression

    /// Record a 30-minute snooze for an app and remember the hour-of-day.
    func recordSnooze(appName: String, at date: Date = Date()) {
        let hour = Calendar.current.component(.hour, from: date)
        try? database.dbQueue.write { db in
            var event = SnoozeEventRecord(
                id: nil,
                appName: appName,
                hour: hour,
                timestamp: date,
                expiresAt: date.addingTimeInterval(30 * 60)
            )
            try event.insert(db)
        }
    }

    /// True if the app is currently within an active 30-minute snooze window.
    func isSnoozed(_ appName: String, now: Date = Date()) -> Bool {
        (try? database.dbQueue.read { db in
            try SnoozeEventRecord
                .filter(Column("appName") == appName)
                .filter(Column("expiresAt") != nil && Column("expiresAt") > now)
                .fetchCount(db) > 0
        }) ?? false
    }

    /// True if the user has snoozed this app at this hour-of-day enough times
    /// that we now auto-suppress it at that hour.
    func isAutoSuppressed(_ appName: String, now: Date = Date()) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        let count = (try? database.dbQueue.read { db in
            try SnoozeEventRecord
                .filter(Column("appName") == appName)
                .filter(Column("hour") == hour)
                .fetchCount(db)
        }) ?? 0
        return count >= autoSuppressAfterSnoozes
    }

    /// Combined gate: should we suppress suggesting this app right now?
    func shouldSuppress(_ appName: String, now: Date = Date()) -> Bool {
        if isNeverSuggested(appName) { return true }
        if isSnoozed(appName, now: now) { return true }
        if isAutoSuppressed(appName, now: now) { return true }
        return false
    }
}
