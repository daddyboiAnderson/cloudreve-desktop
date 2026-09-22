import Foundation
import SQLite3

/// Connections are short-lived and never shared across threads. A SQLite
/// transaction, rather than a process-local NSLock, protects compound changes.
final class FileProviderStateDatabase {
    private var db: OpaquePointer?
    private let root: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultRoot: URL {
        if let value = ProcessInfo.processInfo.environment["CLOUDREVE_FP_STATE_ROOT"] {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) }
            ?? "/Users/\(NSUserName())"
        return URL(fileURLWithPath: home).appendingPathComponent(".cloudreve", isDirectory: true)
    }

    init(root: URL = FileProviderStateDatabase.defaultRoot) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("fileprovider.db").path
        // Create with restrictive permissions before SQLite creates WAL sidecars.
        let fd = Darwin.open(path, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        close(fd)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = error(); sqlite3_close(db); db = nil; throw failure
        }
        do {
            sqlite3_busy_timeout(db, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                // Initialize only an empty database. Recreating a missing
                // journal table would turn damaged state into false success.
                if try rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty {
                    try executeScript(Self.schema)
                }
                guard try rows("SELECT version FROM fp_state_schema").first?.first == "1" else {
                    throw NSError(domain: "CloudreveStateSchema", code: 1)
                }
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }

    private func error() -> NSError {
        NSError(domain: "CloudreveStateDatabase", code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    private func executeScript(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw error() }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }

    func execute(_ sql: String, _ values: [String] = []) throws { _ = try rows(sql, values) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func importRecords(_ namespace: String) throws {
        try transaction {
            if !(try rows("SELECT namespace FROM fp_imports WHERE namespace=?", [namespace])).isEmpty { return }
            let directory = root.appendingPathComponent(namespace, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                for url in try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    let value = try String(contentsOf: url, encoding: .utf8)
                    try execute("INSERT OR IGNORE INTO fp_records(namespace,key,payload) VALUES(?,?,?)", [namespace, url.lastPathComponent, value])
                }
            }
            try execute("INSERT INTO fp_imports(namespace) VALUES(?)", [namespace])
        }
    }

    func get(_ namespace: String, _ key: String) throws -> Data? {
        try importRecords(namespace)
        return try rows("SELECT payload FROM fp_records WHERE namespace=? AND key=?", [namespace, key])
            .first?.first.map { Data($0.utf8) }
    }

    func put(_ namespace: String, _ key: String, _ data: Data) throws {
        try importRecords(namespace)
        guard let value = String(data: data, encoding: .utf8) else { throw NSError(domain: "CloudreveStateEncoding", code: 1) }
        try execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", [namespace, key, value])
    }

    func remove(_ namespace: String, _ key: String) throws {
        try importRecords(namespace)
        try execute("DELETE FROM fp_records WHERE namespace=? AND key=?", [namespace, key])
    }

    /// Read head and records in one snapshot. Errors propagate so Finder cannot
    /// acknowledge unread changes as an empty successful enumeration.
    func eventSnapshot(drive: String, since: Int64?) throws -> (latest: Int64, floor: Int64, events: [Data]) {
        try execute("BEGIN")
        do {
            let head = try rows("SELECT latest,floor FROM fp_event_heads WHERE drive=? AND imported=1", [drive]).first
            guard let head, let latest = Int64(head[0]), let floor = Int64(head[1]) else {
                throw NSError(domain: "CloudreveStateNotReady", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Waiting for Cloudreve to initialize the event journal."])
            }
            let events: [Data]
            if let since {
                events = try rows("SELECT payload FROM fp_events WHERE drive=? AND sequence>? ORDER BY sequence", [drive, String(since)]).map { Data($0[0].utf8) }
            } else { events = [] }
            try execute("COMMIT")
            return (latest, floor, events)
        } catch { try? execute("ROLLBACK"); throw error }
    }

    // Kept identical to macos/fileprovider/state-schema.sql; parity is tested.
    private static let schema = """
    CREATE TABLE IF NOT EXISTS fp_state_schema (version INTEGER NOT NULL);
    INSERT INTO fp_state_schema SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM fp_state_schema);
    CREATE TABLE IF NOT EXISTS fp_event_heads (drive TEXT PRIMARY KEY NOT NULL, latest INTEGER NOT NULL DEFAULT 0, floor INTEGER NOT NULL DEFAULT 0, imported INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS fp_events (drive TEXT NOT NULL, sequence INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (drive, sequence));
    CREATE TABLE IF NOT EXISTS fp_records (namespace TEXT NOT NULL, key TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (namespace, key));
    CREATE TABLE IF NOT EXISTS fp_imports (namespace TEXT PRIMARY KEY NOT NULL);
    CREATE TABLE IF NOT EXISTS fp_deliveries (id TEXT PRIMARY KEY NOT NULL);
    """
}
