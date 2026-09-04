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
    private static let lock = NSLock()
    private static let presentationInterval: Int64 = 30_000
    private static let refreshLifetime: TimeInterval = 24 * 60 * 60

    static var directoryURL: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir))
        } else {
            home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        }
        return home.appendingPathComponent(".cloudreve/upload-conflicts", isDirectory: true)
    }

    static func identifier(driveID: String, uri: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(driveID)\0\(RemoteStore.canonicalURI(uri))".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func load(id: String) -> UploadConflictRecord? {
        withLock { loadUnlocked(id: id) }
    }

    static func load(driveID: String, uri: String) -> UploadConflictRecord? {
        load(id: identifier(driveID: driveID, uri: uri))
    }

    static func saveConflict(
        drive: DriveConfig,
        uri: String,
        itemIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        kind: UploadConflictKind,
        application: String?,
        ownerID: String?,
        previousVersion: String?
    ) throws -> UploadConflictRecord {
        try withLock {
            let id = identifier(driveID: drive.id, uri: uri)
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            var record = UploadConflictRecord(
                id: id,
                driveID: drive.id,
                driveName: drive.name,
                uri: RemoteStore.canonicalURI(uri),
                itemIdentifier: itemIdentifier.rawValue,
                filename: filename,
                kind: kind,
                application: application,
                ownerID: ownerID,
                previousVersion: previousVersion,
                action: nil,
                presentedAt: loadUnlocked(id: id)?.presentedAt ?? 0,
                updatedAt: now)
            if let existing = loadUnlocked(id: id), existing.action != nil {
                record.action = existing.action
            }
            try writeUnlocked(record)
            return record
        }
    }

    static func consumeAction(id: String) throws -> UploadConflictAction? {
        try withLock {
            guard var record = loadUnlocked(id: id),
                let rawAction = record.action,
                let action = UploadConflictAction(rawValue: rawAction)
            else { return nil }
            record.action = nil
            record.updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
            try writeUnlocked(record)
            return action
        }
    }

    static func claimPresentation(id: String, force: Bool = false) -> UploadConflictRecord? {
        try? withLock {
            guard var record = loadUnlocked(id: id) else { return nil }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            guard force || now - record.presentedAt >= presentationInterval else { return nil }
            record.presentedAt = now
            record.updatedAt = now
            try writeUnlocked(record)
            return record
        }
    }

    static func remove(id: String) {
        withLock {
            try? FileManager.default.removeItem(at: fileURL(id: id))
        }
    }

    static func requestContentRefresh(driveID: String, uri: String) throws {
        try withLock {
            try prepareDirectory()
            let id = identifier(driveID: driveID, uri: uri)
            let data = Data(String(Date().timeIntervalSince1970).utf8)
            try data.write(to: refreshURL(id: id), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: refreshURL(id: id).path)
        }
    }

    static func needsContentRefresh(driveID: String, uri: String) -> Bool {
        withLock {
            let id = identifier(driveID: driveID, uri: uri)
            let url = refreshURL(id: id)
            guard let data = try? Data(contentsOf: url),
                let value = String(data: data, encoding: .utf8),
                let timestamp = TimeInterval(value),
                Date().timeIntervalSince1970 - timestamp <= refreshLifetime
            else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return true
        }
    }

    static func finishContentRefresh(driveID: String, uri: String) {
        withLock {
            let id = identifier(driveID: driveID, uri: uri)
            try? FileManager.default.removeItem(at: refreshURL(id: id))
        }
    }

    private static func loadUnlocked(id: String) -> UploadConflictRecord? {
        guard id.count == 16, id.allSatisfy(\.isHexDigit),
            let data = try? Data(contentsOf: fileURL(id: id))
        else { return nil }
        return try? JSONDecoder().decode(UploadConflictRecord.self, from: data)
    }

    private static func writeUnlocked(_ record: UploadConflictRecord) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(id: record.id), options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL(id: record.id).path)
    }

    private static func fileURL(id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).json")
    }

    private static func refreshURL(id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).refresh")
    }

    private static func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
