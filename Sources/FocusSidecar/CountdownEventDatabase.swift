import Foundation
import SQLite3

final class CountdownEventDatabase: @unchecked Sendable {
    let fileURL: URL

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

        fileURL = appDirectory.appendingPathComponent("events.sqlite3")

        guard sqlite3_open_v2(
            fileURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open the database."
            sqlite3_close(database)
            database = nil
            throw CountdownDatabaseError.operationFailed(message)
        }

        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 120),
                event_at REAL NOT NULL,
                created_at REAL NOT NULL DEFAULT (unixepoch()),
                updated_at REAL NOT NULL DEFAULT (unixepoch())
            );
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS events_event_at_idx ON events(event_at);")
    }

    deinit {
        sqlite3_close(database)
    }

    func fetchEvents() throws -> [CountdownEvent] {
        let statement = try prepare("SELECT id, name, event_at FROM events ORDER BY event_at ASC;")
        defer { sqlite3_finalize(statement) }

        var events: [CountdownEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idBytes = sqlite3_column_text(statement, 0),
                let nameBytes = sqlite3_column_text(statement, 1),
                let id = UUID(uuidString: String(cString: idBytes))
            else { continue }

            events.append(CountdownEvent(
                id: id,
                name: String(cString: nameBytes),
                eventAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }

        try ensureCompleted(statement)
        return events
    }

    func insert(name: String, eventAt: Date) throws -> CountdownEvent {
        let event = CountdownEvent(id: UUID(), name: name, eventAt: eventAt)
        let statement = try prepare("INSERT INTO events (id, name, event_at) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(statement) }

        try bind(event.id.uuidString, to: 1, in: statement)
        try bind(event.name, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, event.eventAt.timeIntervalSince1970)
        try run(statement)
        return event
    }

    func update(_ event: CountdownEvent) throws {
        let statement = try prepare(
            "UPDATE events SET name = ?, event_at = ?, updated_at = unixepoch() WHERE id = ?;"
        )
        defer { sqlite3_finalize(statement) }

        try bind(event.name, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, event.eventAt.timeIntervalSince1970)
        try bind(event.id.uuidString, to: 3, in: statement)
        try run(statement)

        guard sqlite3_changes(database) == 1 else {
            throw CountdownDatabaseError.operationFailed("The event could not be found.")
        }
    }

    func delete(id: UUID) throws {
        let statement = try prepare("DELETE FROM events WHERE id = ?;")
        defer { sqlite3_finalize(statement) }

        try bind(id.uuidString, to: 1, in: statement)
        try run(statement)

        guard sqlite3_changes(database) == 1 else {
            throw CountdownDatabaseError.operationFailed("The event could not be found.")
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError()
        }
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

    private func ensureCompleted(_ statement: OpaquePointer) throws {
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE else { throw databaseError() }
    }

    private func databaseError() -> CountdownDatabaseError {
        guard let database else {
            return .operationFailed("The local events database is unavailable.")
        }
        return .operationFailed(String(cString: sqlite3_errmsg(database)))
    }
}

enum CountdownDatabaseError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            "Events database: \(message)"
        }
    }
}
