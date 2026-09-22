import Foundation
import FileProvider

enum UploadConflictKind: String, Codable {
    case locked
    case stale
    case unverified
}

enum UploadConflictAction: String {
    case saveCopy = "save_copy"
    case retry
    case discard
}

struct UploadConflictRecord: Codable {
    let id: String
    let driveID: String
    let driveName: String
    let uri: String
    let itemIdentifier: String
    let filename: String
    let kind: UploadConflictKind
    let application: String?
    let ownerID: String?
    let previousVersion: String?
    var action: String?
    var presentedAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, uri, filename, kind, application, action
        case driveID = "drive_id"
        case driveName = "drive_name"
        case itemIdentifier = "item_identifier"
        case ownerID = "owner_id"
        case previousVersion = "previous_version"
        case presentedAt = "presented_at"
        case updatedAt = "updated_at"
    }
}

enum UploadConflictStore {
    private static let namespace = "upload-conflicts"
    private static let presentationInterval: Int64 = 30_000
    private static let refreshLifetime: TimeInterval = 24 * 60 * 60

    static func identifier(driveID: String, uri: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(driveID)\0\(RemoteStore.canonicalURI(uri))".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func withDatabase<T>(_ work: (FileProviderStateDatabase) throws -> T) throws -> T {
        let database = try FileProviderStateDatabase()
        try database.importRecords(namespace)
        return try database.transaction { try work(database) }
    }

    private static func read(_ database: FileProviderStateDatabase, _ id: String) throws -> UploadConflictRecord? {
        guard id.count == 16, id.allSatisfy(\.isHexDigit) else { return nil }
        guard let payload = try database.rows("SELECT payload FROM fp_records WHERE namespace=? AND key=?", [namespace, "\(id).json"]).first?.first else { return nil }
        return try JSONDecoder().decode(UploadConflictRecord.self, from: Data(payload.utf8))
    }

    private static func write(_ database: FileProviderStateDatabase, _ record: UploadConflictRecord) throws {
        let payload = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", [namespace, "\(record.id).json", payload])
    }

    static func load(id: String) -> UploadConflictRecord? {
        try? withDatabase { try read($0, id) }
    }

    static func load(driveID: String, uri: String) -> UploadConflictRecord? {
        load(id: identifier(driveID: driveID, uri: uri))
    }

    static func saveConflict(
        drive: DriveConfig, uri: String, itemIdentifier: NSFileProviderItemIdentifier,
        filename: String, kind: UploadConflictKind, application: String?,
        ownerID: String?, previousVersion: String?
    ) throws -> UploadConflictRecord {
        try withDatabase { database in
            let id = identifier(driveID: drive.id, uri: uri)
            let existing = try read(database, id)
            let record = UploadConflictRecord(
                id: id, driveID: drive.id, driveName: drive.name,
                uri: RemoteStore.canonicalURI(uri), itemIdentifier: itemIdentifier.rawValue,
                filename: filename, kind: kind, application: application, ownerID: ownerID,
                previousVersion: previousVersion, action: existing?.action,
                presentedAt: existing?.presentedAt ?? 0,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1_000))
            try write(database, record)
            return record
        }
    }

    static func consumeAction(id: String) throws -> UploadConflictAction? {
        try withDatabase { database in
            guard var record = try read(database, id),
                let raw = record.action, let action = UploadConflictAction(rawValue: raw) else { return nil }
            record.action = nil
            record.updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
            try write(database, record)
            return action
        }
    }

    static func claimPresentation(id: String, force: Bool = false) -> UploadConflictRecord? {
        try? withDatabase { database in
            guard var record = try read(database, id) else { return nil }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            guard force || now - record.presentedAt >= presentationInterval else { return nil }
            record.presentedAt = now
            record.updatedAt = now
            try write(database, record)
            return record
        }
    }

    static func remove(id: String) {
        try? FileProviderStateDatabase().remove(namespace, "\(id).json")
    }

    static func requestContentRefresh(driveID: String, uri: String) throws {
        try FileProviderStateDatabase().put(namespace,
            "\(identifier(driveID: driveID, uri: uri)).refresh",
            Data(String(Date().timeIntervalSince1970).utf8))
    }

    static func needsContentRefresh(driveID: String, uri: String) -> Bool {
        let key = "\(identifier(driveID: driveID, uri: uri)).refresh"
        guard let database = try? FileProviderStateDatabase(),
            let data = try? database.get(namespace, key),
            let value = String(data: data, encoding: .utf8), let timestamp = TimeInterval(value) else { return false }
        return Date().timeIntervalSince1970 - timestamp <= refreshLifetime
    }

    static func finishContentRefresh(driveID: String, uri: String) {
        try? FileProviderStateDatabase().remove(namespace, "\(identifier(driveID: driveID, uri: uri)).refresh")
    }
}
