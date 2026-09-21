import Foundation
import SQLite3

struct UsageHistorySeries: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case quota, balance, remaining, count }
    let id: String
    let providerID: String
    let meterID: String
    let label: String
    let kind: Kind
    let unit: String
    let firstAt: Date
    let lastAt: Date

    var isFable: Bool { meterID == "weekly_fable" || label.localizedCaseInsensitiveContains("fable") }
}

struct UsageHistoryPoint: Identifiable, Equatable, Sendable {
    var id: Date { date }
    let date: Date
    let value: Double
    let resetsAt: Date?
}

struct UsageHistoryRecord: Sendable {
    let series: UsageHistorySeries
    let point: UsageHistoryPoint

    static func readings(from snapshot: ProviderSnapshot, at date: Date) -> [Self] {
        guard snapshot.status == .ok,
              UsageWidgetSnapshot.catalogue.contains(where: { $0.id == snapshot.id }) else { return [] }
        return snapshot.windows.compactMap { window in
            let kind: UsageHistorySeries.Kind
            let unit: String
            let value: Double
            if let money = window.money {
                kind = .balance; unit = money.currency; value = money.remaining
            } else if let fraction = window.usedFraction {
                kind = .quota; unit = "%"; value = fraction * 100
            } else if let remaining = window.remaining {
                kind = .remaining; unit = snapshot.id == "google-flow" ? "credits" : "count"
                value = Double(remaining)
            } else if let used = window.used, window.usedText == nil {
                kind = .count; unit = "count"; value = Double(used)
            } else { return nil }
            guard value.isFinite, value >= 0 else { return nil }
            // Scoped quotas can change model without changing their vendor ID.
            // Preserve that distinction and never combine currencies or units.
            let components = [snapshot.id, window.id, window.label, kind.rawValue, unit]
            let id = components.map { "\($0.utf8.count):\($0)" }.joined()
            return Self(series: UsageHistorySeries(id: id, providerID: snapshot.id,
                meterID: window.id, label: window.label, kind: kind, unit: unit,
                firstAt: date, lastAt: date),
                point: UsageHistoryPoint(date: date, value: value, resetsAt: window.resetsAt))
        }
    }
}

/// The actor owns its SQLite connection. Writes never run on the UI thread;
/// one transaction persists the complete provider reading before publishing it.
actor UsageHistoryDatabase {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codenotch/History/usage.sqlite")
    }

    private let url: URL
    private var db: OpaquePointer?
    private enum Binding { case text(String), number(Double), null }
    private struct DatabaseError: Error { let message: String }

    init(url: URL) { self.url = url }
    deinit { sqlite3_close(db) }

    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw DatabaseError(message: "Unable to open usage history")
        }
        db = connection
        do {
            sqlite3_busy_timeout(db, 3000)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("PRAGMA journal_mode=WAL")
            try execute("""
                CREATE TABLE IF NOT EXISTS series (
                    id TEXT PRIMARY KEY, provider TEXT NOT NULL, meter TEXT NOT NULL,
                    label TEXT NOT NULL, kind TEXT NOT NULL, unit TEXT NOT NULL,
                    first_at REAL NOT NULL, last_at REAL NOT NULL)
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    series TEXT NOT NULL, at REAL NOT NULL, value REAL NOT NULL, reset_at REAL,
                    PRIMARY KEY(series, at)) WITHOUT ROWID
                """)
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }

    private func statement(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(message: "Unable to prepare history query")
        }
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .number(let value): result = sqlite3_bind_double(statement, position, value)
            case .null: result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw DatabaseError(message: "Unable to bind history query")
            }
        }
        return statement
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        let query = try statement(sql, bindings)
        defer { sqlite3_finalize(query) }
        var result = sqlite3_step(query)
        while result == SQLITE_ROW { result = sqlite3_step(query) }
        guard result == SQLITE_DONE else { throw DatabaseError(message: "Unable to save usage history") }
    }

    func append(_ records: [UsageHistoryRecord]) throws {
        guard !records.isEmpty else { return }
        try open()
        try execute("BEGIN IMMEDIATE")
        do {
            for record in records where record.point.value.isFinite && record.point.value >= 0 {
                let series = record.series
                let point = record.point
                try execute("""
                    INSERT INTO series VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        first_at = MIN(first_at, excluded.first_at), last_at = MAX(last_at, excluded.last_at)
                    """, [.text(series.id), .text(series.providerID), .text(series.meterID),
                          .text(series.label), .text(series.kind.rawValue), .text(series.unit),
                          .number(point.date.timeIntervalSince1970), .number(point.date.timeIntervalSince1970)])
                try execute("INSERT OR IGNORE INTO samples VALUES (?, ?, ?, ?)",
                    [.text(series.id), .number(point.date.timeIntervalSince1970), .number(point.value),
                     point.resetsAt.map { .number($0.timeIntervalSince1970) } ?? .null])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func catalogue() throws -> [UsageHistorySeries] {
        try open()
        let query = try statement("SELECT * FROM series ORDER BY provider, first_at, meter", [])
        defer { sqlite3_finalize(query) }
        func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(query, column)) }
        var series: [UsageHistorySeries] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            if let kind = UsageHistorySeries.Kind(rawValue: text(4)) {
                series.append(UsageHistorySeries(id: text(0), providerID: text(1), meterID: text(2),
                    label: text(3), kind: kind, unit: text(5),
                    firstAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 6)),
                    lastAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 7))))
            }
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw DatabaseError(message: "Unable to read history catalogue") }
        return series
    }

    func points(for seriesID: String, from start: Date, through end: Date) throws -> [UsageHistoryPoint] {
        try open()
        let query = try statement("SELECT at, value, reset_at FROM samples WHERE series = ? AND at >= ? AND at <= ? ORDER BY at",
            [.text(seriesID), .number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970)])
        defer { sqlite3_finalize(query) }
        var points: [UsageHistoryPoint] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            let reset = sqlite3_column_type(query, 2) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(query, 2))
            points.append(UsageHistoryPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(query, 0)),
                value: sqlite3_column_double(query, 1), resetsAt: reset))
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw DatabaseError(message: "Unable to read usage history") }
        return points
    }
}

struct UsageHistoryDay: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    var readings = 0
    var peak: Double?
    var consumed: Double?
}

struct UsageHistoryChartPoint: Identifiable {
    var id: Date { point.date }
    let point: UsageHistoryPoint
    let segment: Int
}

enum UsageHistoryAnalysis {
    static let maximumGap: TimeInterval = 15 * 60

    static func sameWindow(_ a: UsageHistoryPoint, _ b: UsageHistoryPoint) -> Bool {
        switch (a.resetsAt, b.resetsAt) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return abs(lhs.timeIntervalSince(rhs)) < 60
        default: return false
        }
    }

    static func daily(_ points: [UsageHistoryPoint], kind: UsageHistorySeries.Kind,
                      from start: Date, through end: Date, calendar: Calendar = .current) -> [UsageHistoryDay] {
        var days: [UsageHistoryDay] = []
        var date = calendar.startOfDay(for: start)
        while date <= end {
            days.append(UsageHistoryDay(date: date))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        let indices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.date, $0.offset) })
        var previous: UsageHistoryPoint?
        var baseline: Double?
        for point in points.sorted(by: { $0.date < $1.date }) where point.date >= start && point.date <= end {
            guard let index = indices[calendar.startOfDay(for: point.date)] else { continue }
            days[index].readings += 1
            days[index].peak = max(days[index].peak ?? point.value, point.value)
            defer { previous = point }
            guard let prior = previous, let reference = baseline,
                  point.date.timeIntervalSince(prior.date) > 0,
                  point.date.timeIntervalSince(prior.date) <= maximumGap,
                  sameWindow(prior, point), calendar.isDate(prior.date, inSameDayAs: point.date) else {
                baseline = point.value
                continue
            }
            // Lower-bound observed consumption, not a billing total. Do not
            // count the initial reading, overnight gaps, resets or refills.
            let delta: Double
            if kind == .balance || kind == .remaining {
                delta = max(0, reference - point.value)
                baseline = point.value // An increase establishes a new funded balance.
            } else {
                delta = max(0, point.value - reference)
                baseline = max(reference, point.value) // Corrections must not be counted twice.
            }
            days[index].consumed = (days[index].consumed ?? 0) + delta
        }
        return days
    }

    static func chartPoints(_ points: [UsageHistoryPoint], limit: Int = 600) -> [UsageHistoryChartPoint] {
        var segment = 0
        var previous: UsageHistoryPoint?
        let segmented = points.map { point -> UsageHistoryChartPoint in
            if let prior = previous,
               point.date.timeIntervalSince(prior.date) > maximumGap || !sameWindow(prior, point) { segment += 1 }
            previous = point
            return UsageHistoryChartPoint(point: point, segment: segment)
        }
        guard segmented.count > limit else { return segmented }
        // Keep extrema and endpoints, so a brief peak survives downsampling.
        let size = max(1, Int(ceil(Double(segmented.count) / Double(max(1, limit / 4)))))
        return stride(from: 0, to: segmented.count, by: size).flatMap { start in
            let bucket = Array(segmented[start..<min(start + size, segmented.count)])
            let candidates = [bucket.first!, bucket.min { $0.point.value < $1.point.value }!,
                              bucket.max { $0.point.value < $1.point.value }!, bucket.last!]
            return Dictionary(grouping: candidates, by: \.id).compactMap { $0.value.first }.sorted { $0.id < $1.id }
        }
    }
}
