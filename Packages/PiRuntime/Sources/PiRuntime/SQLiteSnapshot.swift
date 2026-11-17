import Foundation
import SQLite3

/// A consistent copy of a live Pi database, for the backup archive. It opens its own read-only connection (Pi's runs on
/// the JS queue) and writes the last committed state with `VACUUM INTO`: in WAL mode that reads one snapshot while the
/// Harness keeps writing, and the copy is a single file with no `-wal` beside it.
public enum SQLiteSnapshot {
    public static func copy(_ source: URL, to destination: URL) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close_v2(db) }
        guard rc == SQLITE_OK, let db else {
            throw SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        sqlite3_busy_timeout(db, 5000)
        try? FileManager.default.removeItem(at: destination)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "VACUUM INTO ?", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, destination.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Whether `url` is a SQLite database that passes `PRAGMA quick_check`: a restore checks the file before it replaces
    /// Pi's.
    public static func isIntact(_ url: URL) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok"
    }
}
