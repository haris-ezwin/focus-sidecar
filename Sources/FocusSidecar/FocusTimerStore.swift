import Foundation
import SQLite3

enum FocusTimerMode: String, Sendable {
    case work
    case rest

    var title: String { rawValue.capitalized }
}

@MainActor
final class FocusTimerStore: ObservableObject {
    @Published private(set) var activeMode: FocusTimerMode?
    @Published private(set) var isRunning = false
    @Published private(set) var sessionSeconds = 0
    @Published private(set) var totalWorkSeconds = 0
    @Published private(set) var totalRestSeconds = 0
    @Published private(set) var errorMessage: String?

    private var database: FocusTimerDatabase?
    private var activeSessionID: UUID?
    private var activeSegmentSeconds = 0
    private var totalsDateKey = ""

    init() {
        do {
            let database = try FocusTimerDatabase()
            self.database = database
            try database.closeInterruptedSessions()
            try reloadDailyTotals()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ mode: FocusTimerMode) {
        if activeMode == mode, isRunning {
            pause()
            return
        }

        finishActiveSegment()
        activeMode = mode
        sessionSeconds = 0
        startSegment(mode)
    }

    func tick() {
        handleDateChangeIfNeeded()
        guard isRunning, let activeMode, let activeSessionID, let database else { return }

        sessionSeconds += 1
        activeSegmentSeconds += 1
        switch activeMode {
        case .work: totalWorkSeconds += 1
        case .rest: totalRestSeconds += 1
        }

        do {
            try database.updateSession(
                id: activeSessionID,
                durationSeconds: activeSegmentSeconds,
                updatedAt: Date()
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopForTermination() {
        finishActiveSegment()
    }

    private func pause() {
        finishActiveSegment()
        activeMode = nil
        sessionSeconds = 0
    }

    private func startSegment(_ mode: FocusTimerMode) {
        guard let database else {
            errorMessage = errorMessage ?? "The local timer database is unavailable."
            return
        }

        do {
            activeSessionID = try database.startSession(mode: mode, startedAt: Date())
            activeSegmentSeconds = 0
            isRunning = true
            errorMessage = nil
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    private func finishActiveSegment() {
        guard isRunning, let activeSessionID, let database else {
            isRunning = false
            self.activeSessionID = nil
            return
        }

        do {
            try database.finishSession(
                id: activeSessionID,
                durationSeconds: activeSegmentSeconds,
                endedAt: Date()
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isRunning = false
        self.activeSessionID = nil
        activeSegmentSeconds = 0
    }

    private func handleDateChangeIfNeeded() {
        let currentKey = Self.dateKey(for: Date())
        guard currentKey != totalsDateKey else { return }

        let modeToResume = isRunning ? activeMode : nil
        finishActiveSegment()
        sessionSeconds = 0

        do {
            try reloadDailyTotals()
        } catch {
            errorMessage = error.localizedDescription
        }

        if let modeToResume {
            activeMode = modeToResume
            startSegment(modeToResume)
        }
    }

    private func reloadDailyTotals() throws {
        guard let database else { return }
        let interval = Calendar.current.dateInterval(of: .day, for: Date())!
        let totals = try database.totals(from: interval.start, to: interval.end)
        totalWorkSeconds = totals.work
        totalRestSeconds = totals.rest
        totalsDateKey = Self.dateKey(for: Date())
    }

    private static func dateKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private final class FocusTimerDatabase: @unchecked Sendable {
    private var database: OpaquePointer?
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileManager: FileManager = .default) throws {
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = supportDirectory.appendingPathComponent("Focus Sidecar", isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let fileURL = appDirectory.appendingPathComponent("events.sqlite3")

        guard sqlite3_open_v2(
            fileURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open the database."
            sqlite3_close(database)
            database = nil
            throw FocusTimerDatabaseError.operationFailed(message)
        }

        try execute("PRAGMA journal_mode = WAL;")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS timer_sessions (
                id TEXT PRIMARY KEY NOT NULL,
                mode TEXT NOT NULL CHECK(mode IN ('work', 'rest')),
                started_at REAL NOT NULL,
                ended_at REAL,
                duration_seconds INTEGER NOT NULL DEFAULT 0 CHECK(duration_seconds >= 0),
                updated_at REAL NOT NULL
            );
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS timer_sessions_started_at_idx ON timer_sessions(started_at);"
        )
    }

    deinit {
        sqlite3_close(database)
    }

    func closeInterruptedSessions() throws {
        try execute("UPDATE timer_sessions SET ended_at = updated_at WHERE ended_at IS NULL;")
    }

    func startSession(mode: FocusTimerMode, startedAt: Date) throws -> UUID {
        let id = UUID()
        let statement = try prepare(
            "INSERT INTO timer_sessions (id, mode, started_at, updated_at) VALUES (?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }

        try bind(id.uuidString, to: 1, in: statement)
        try bind(mode.rawValue, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, startedAt.timeIntervalSince1970)
        try run(statement)
        return id
    }

    func updateSession(id: UUID, durationSeconds: Int, updatedAt: Date) throws {
        let statement = try prepare(
            "UPDATE timer_sessions SET duration_seconds = ?, updated_at = ? WHERE id = ? AND ended_at IS NULL;"
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sqlite3_int64(durationSeconds))
        sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSince1970)
        try bind(id.uuidString, to: 3, in: statement)
        try run(statement)
        try requireOneChangedRow()
    }

    func finishSession(id: UUID, durationSeconds: Int, endedAt: Date) throws {
        let statement = try prepare(
            "UPDATE timer_sessions SET ended_at = ?, duration_seconds = ?, updated_at = ? WHERE id = ? AND ended_at IS NULL;"
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, endedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(durationSeconds))
        sqlite3_bind_double(statement, 3, endedAt.timeIntervalSince1970)
        try bind(id.uuidString, to: 4, in: statement)
        try run(statement)
        try requireOneChangedRow()
    }

    func totals(from start: Date, to end: Date) throws -> (work: Int, rest: Int) {
        let statement = try prepare(
            """
            SELECT mode, COALESCE(SUM(duration_seconds), 0)
            FROM timer_sessions
            WHERE started_at >= ? AND started_at < ?
            GROUP BY mode;
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)

        var work = 0
        var rest = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let modeBytes = sqlite3_column_text(statement, 0) else { continue }
            let seconds = Int(sqlite3_column_int64(statement, 1))
            switch String(cString: modeBytes) {
            case FocusTimerMode.work.rawValue: work = seconds
            case FocusTimerMode.rest.rawValue: rest = seconds
            default: continue
            }
        }
        return (work, rest)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, transientDestructor)
        }
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func run(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func requireOneChangedRow() throws {
        guard sqlite3_changes(database) == 1 else {
            throw FocusTimerDatabaseError.operationFailed("The timer session could not be updated.")
        }
    }

    private func databaseError() -> FocusTimerDatabaseError {
        guard let database else {
            return .operationFailed("The local timer database is unavailable.")
        }
        return .operationFailed(String(cString: sqlite3_errmsg(database)))
    }
}

private enum FocusTimerDatabaseError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message): "Timer database: \(message)"
        }
    }
}
