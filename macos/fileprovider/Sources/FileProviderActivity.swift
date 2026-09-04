import Foundation
import OSLog

struct FileProviderActivityRecord: Codable {
    let id: String
    let driveID: String
    let operation: String
    let uri: String
    let itemIdentifier: String
    let filename: String
    var status: String
    var totalBytes: Int64
    var processedBytes: Int64
    var speedBytesPerSecond: Int64
    var etaSeconds: Int64?
    var error: String?
    let createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, operation, uri, filename, status, error
        case driveID = "drive_id"
        case itemIdentifier = "item_identifier"
        case totalBytes = "total_bytes"
        case processedBytes = "processed_bytes"
        case speedBytesPerSecond = "speed_bytes_per_sec"
        case etaSeconds = "eta_seconds"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct FileProviderUploadReceipt: Codable {
    let id: String
    let driveID: String
    let uri: String
    let completedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, uri
        case driveID = "drive_id"
        case completedAt = "completed_at"
    }
}

private enum FileProviderUploadReceiptStore {
    static func save(id: String, driveID: String, uri: String, completedAt: Int64) {
        do {
            let directory = directoryURL
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let receipt = FileProviderUploadReceipt(
                id: id, driveID: driveID, uri: uri, completedAt: completedAt)
            let destination = directory.appendingPathComponent("\(id).json")
            try JSONEncoder().encode(receipt).write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            Logger(subsystem: "cloudreve.desktop.dev.fileprovider", category: "activity").error(
                "could not persist upload receipt: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["CLOUDREVE_FP_UPLOAD_RECEIPT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home: URL
        if let pw = getpwuid(getuid()), let directory = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory))
        } else {
            home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        }
        return home.appendingPathComponent(
            ".cloudreve/fileprovider-upload-receipts", isDirectory: true)
    }
}

enum FileProviderActivityStore {
    private static let lock = NSLock()
    private static let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "activity")
    private static let maximumRecords = 100
    private static let completedLifetime: Int64 = 24 * 60 * 60

    static func upsert(_ record: FileProviderActivityRecord) {
        lock.lock()
        defer { lock.unlock() }

        var records = load(driveID: record.driveID)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }

        let cutoff = now() - completedLifetime
        records = records
            .filter { $0.status == "running" || $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
        if records.count > maximumRecords {
            records.removeLast(records.count - maximumRecords)
        }
        write(records, driveID: record.driveID)
    }

    static func markInterruptedActivitiesFailed(driveID: String) {
        lock.lock()
        defer { lock.unlock() }

        var records = load(driveID: driveID)
        var changed = false
        for index in records.indices where records[index].status == "running" {
            records[index].status = "failed"
            records[index].error = "The transfer was interrupted."
            records[index].updatedAt = now()
            changed = true
        }
        if changed { write(records, driveID: driveID) }
    }

    static func records(driveID: String) -> [FileProviderActivityRecord] {
        lock.lock()
        defer { lock.unlock() }
        return load(driveID: driveID)
    }

    private static func load(driveID: String) -> [FileProviderActivityRecord] {
        guard let data = try? Data(contentsOf: fileURL(driveID: driveID)) else { return [] }
        return (try? JSONDecoder().decode([FileProviderActivityRecord].self, from: data)) ?? []
    }

    private static func write(_ records: [FileProviderActivityRecord], driveID: String) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let destination = fileURL(driveID: driveID)
            try JSONEncoder().encode(records).write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            logger.error(
                "could not persist transfer activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func fileURL(driveID: String) -> URL {
        directoryURL.appendingPathComponent("\(driveID).json")
    }

    private static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["CLOUDREVE_FP_ACTIVITY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home: URL
        if let pw = getpwuid(getuid()), let directory = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory))
        } else {
            home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        }
        return home.appendingPathComponent(".cloudreve/fileprovider-activity", isDirectory: true)
    }

    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}

final class FileProviderActivity {
    private let stateLock = NSLock()
    private var record: FileProviderActivityRecord
    private var lastPersistedAt = Date.distantPast
    private var lastMeasuredAt = Date()
    private var lastMeasuredBytes: Int64 = 0

    init(
        driveID: String,
        operation: String,
        uri: String,
        itemIdentifier: String,
        filename: String,
        totalBytes: Int64 = 0
    ) {
        let timestamp = Int64(Date().timeIntervalSince1970)
        record = FileProviderActivityRecord(
            id: "fp-transfer-\(UUID().uuidString)",
            driveID: driveID,
            operation: operation,
            uri: uri,
            itemIdentifier: itemIdentifier,
            filename: filename,
            status: "running",
            totalBytes: totalBytes,
            processedBytes: 0,
            speedBytesPerSecond: 0,
            etaSeconds: nil,
            error: nil,
            createdAt: timestamp,
            updatedAt: timestamp)
        FileProviderActivityStore.upsert(record)
    }

    func update(processedBytes: Int64, totalBytes: Int64) {
        let measurementTime = Date()
        stateLock.lock()
        record.processedBytes = processedBytes
        record.totalBytes = max(totalBytes, 0)
        record.updatedAt = Int64(measurementTime.timeIntervalSince1970)

        let elapsed = measurementTime.timeIntervalSince(lastMeasuredAt)
        if elapsed > 0.1 {
            let delta = max(processedBytes - lastMeasuredBytes, 0)
            record.speedBytesPerSecond = Int64(Double(delta) / elapsed)
            if record.speedBytesPerSecond > 0, record.totalBytes > processedBytes {
                record.etaSeconds =
                    (record.totalBytes - processedBytes) / record.speedBytesPerSecond
            } else {
                record.etaSeconds = nil
            }
            lastMeasuredAt = measurementTime
            lastMeasuredBytes = processedBytes
        }

        let shouldPersist = measurementTime.timeIntervalSince(lastPersistedAt) >= 0.25
            || (record.totalBytes > 0 && processedBytes >= record.totalBytes)
        let snapshot = record
        if shouldPersist { lastPersistedAt = measurementTime }
        stateLock.unlock()

        if shouldPersist { FileProviderActivityStore.upsert(snapshot) }
    }

    func complete() {
        let snapshot = finish(status: "completed", error: nil)
        if snapshot.operation == "upload" {
            FileProviderUploadReceiptStore.save(
                id: snapshot.id,
                driveID: snapshot.driveID,
                uri: snapshot.uri,
                completedAt: snapshot.updatedAt)
        }
    }

    func fail(_ error: Error) {
        let cocoaError = error as? CocoaError
        _ = finish(
            status: cocoaError?.code == .userCancelled ? "cancelled" : "failed",
            error: cocoaError?.code == .userCancelled ? nil : error.localizedDescription)
    }

    private func finish(status: String, error: String?) -> FileProviderActivityRecord {
        stateLock.lock()
        record.status = status
        if status == "completed", record.totalBytes > 0 {
            record.processedBytes = record.totalBytes
        }
        record.speedBytesPerSecond = 0
        record.etaSeconds = nil
        record.error = error
        record.updatedAt = Int64(Date().timeIntervalSince1970)
        let snapshot = record
        stateLock.unlock()
        FileProviderActivityStore.upsert(snapshot)
        return snapshot
    }
}
