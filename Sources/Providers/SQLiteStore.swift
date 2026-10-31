import Foundation
import SQLite3

/// Read-only access to another app's SQLite store.
///
/// Both Cursor and Codex keep their state this way, and both run it in WAL mode,
/// which makes opening it more delicate than it looks:
///
/// - `immutable=1` tells SQLite to ignore the write-ahead log entirely, so a
///   running app's most recent writes are invisible. That is how a live agent
///   looks idle and a rotated token looks current.
/// - `mode=ro` sees the log, but may need to create the `-wal` and `-shm`
///   sidecars after the owning app has quit. Without write access to that
///   directory, opening can succeed and the first actual read fails instead.
///
/// Validate an actual page read before returning a connection. Only use the
/// immutable fallback when there is no journal to ignore; an inaccessible live
/// WAL must never silently become an older credential from the main file.
enum SQLiteStore {
    static func open(_ url: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        func hasJournal() -> Bool {
            ["-wal", "-journal"].contains {
                FileManager.default.fileExists(atPath: url.path + $0)
            }
        }
        for query in ["mode=ro", "immutable=1"] {
            let immutable = query == "immutable=1"
            if immutable && hasJournal() { return nil }
            var db: OpaquePointer?
            let opened = sqlite3_open_v2("file:\(url.path)?\(query)", &db,
                                        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            // SELECT 1 is insufficient: it never reads the database pages.
            let readable = opened == SQLITE_OK
                ? sqlite3_exec(db, "PRAGMA schema_version", nil, nil, nil)
                : opened
            if readable == SQLITE_OK, let db {
                // The owning app may have restarted while we opened the file.
                if immutable && hasJournal() {
                    sqlite3_close(db)
                    return nil
                }
                return db
            }
            sqlite3_close(db)
            let errorCode = readable & 0xff
            guard errorCode == SQLITE_CANTOPEN || errorCode == SQLITE_READONLY else { return nil }
        }
        return nil
    }

    /// Every column of every row, as text. Needed where one row carries more
    /// than one fact — a thread's title *and* when it was last touched — and
    /// two queries would be two chances for them to disagree.
    static func rows(in db: OpaquePointer?, sql: String, columns: Int) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for index in 0..<Int32(columns) {
                row.append(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
            }
            out.append(row)
        }
        return out
    }

    /// First column of every row, as text.
    static func rows(in db: OpaquePointer?, sql: String, bind: String? = nil) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        if let bind {
            sqlite3_bind_text(statement, 1, bind, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { out.append(String(cString: raw)) }
        }
        return out
    }
}
