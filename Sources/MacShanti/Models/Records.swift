import Foundation
import GRDB

// MARK: - Persisted records (GRDB)

/// Aggregate system memory snapshot persisted to SQLite.
struct MemorySnapshotRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var timestamp: Date
    var totalBytes: Int64
    var usedBytes: Int64
    var freeBytes: Int64
    var swapUsedBytes: Int64
    var swapTotalBytes: Int64
    var pressureLevel: Int

    static let databaseTableName = "memory_snapshot"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Per-process sample persisted to SQLite, linked to a snapshot.
struct ProcessSampleRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var snapshotId: Int64
    var pid: Int
    var name: String
    var bundleIdentifier: String?
    var rssBytes: Int64
    var cpuTimeSeconds: Double
    var isFrontmost: Bool

    static let databaseTableName = "process_sample"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A learned co-occurrence pattern of apps that are frequently open together.
struct SessionRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    /// Stable signature: sorted, comma-joined app names.
    var signature: String
    var name: String
    var occurrences: Int
    var lastSeen: Date
    /// Whether the "close non-session apps" nudge has already been shown.
    var nudged: Bool

    static let databaseTableName = "session_record"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Per-app user preference: never suggest quitting this app.
struct AppPreferenceRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var appName: String
    var neverSuggest: Bool

    static let databaseTableName = "app_preference"
}

/// A recorded "snooze" of a suggestion for a given app at a given hour.
/// Two or more at the same hour ⇒ auto-suppress that app at that hour.
struct SnoozeEventRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var appName: String
    var hour: Int          // 0...23, local time
    var timestamp: Date
    /// When set, the snooze is active until this moment (30-min snoozes).
    var expiresAt: Date?

    static let databaseTableName = "snooze_event"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
