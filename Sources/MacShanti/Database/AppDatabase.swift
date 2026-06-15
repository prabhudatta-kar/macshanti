import Foundation
import GRDB

/// Thin wrapper around a GRDB `DatabaseQueue` plus schema migrations.
final class AppDatabase {

    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    /// On-disk database under Application Support.
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
        let dir = support.appendingPathComponent("MacShanti", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("macshanti.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        return try AppDatabase(queue)
    }

    /// Fallback in-memory database (used if the on-disk store can't open).
    static func makeInMemory() -> AppDatabase {
        // Force-unwrap is acceptable here: an in-memory queue cannot fail.
        let queue = try! DatabaseQueue()
        return try! AppDatabase(queue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "memory_snapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("totalBytes", .integer).notNull()
                t.column("usedBytes", .integer).notNull()
                t.column("freeBytes", .integer).notNull()
                t.column("swapUsedBytes", .integer).notNull()
                t.column("swapTotalBytes", .integer).notNull()
                t.column("pressureLevel", .integer).notNull()
            }

            try db.create(table: "process_sample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("snapshotId", .integer)
                    .notNull()
                    .indexed()
                    .references("memory_snapshot", onDelete: .cascade)
                t.column("pid", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("bundleIdentifier", .text)
                t.column("rssBytes", .integer).notNull()
                t.column("cpuTimeSeconds", .double).notNull()
                t.column("isFrontmost", .boolean).notNull()
            }

            try db.create(table: "session_record") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("signature", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("occurrences", .integer).notNull()
                t.column("lastSeen", .datetime).notNull()
                t.column("nudged", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "app_preference") { t in
                t.primaryKey(["appName"])
                t.column("appName", .text).notNull()
                t.column("neverSuggest", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "snooze_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("appName", .text).notNull().indexed()
                t.column("hour", .integer).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("expiresAt", .datetime)
            }
        }

        return migrator
    }

    // MARK: - Retention

    /// Drop snapshots older than `days` to keep the store bounded.
    func pruneSnapshots(olderThan days: Int = 14) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        try? dbQueue.write { db in
            try MemorySnapshotRecord
                .filter(Column("timestamp") < cutoff)
                .deleteAll(db)
        }
    }
}
