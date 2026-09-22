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
            let receipt = FileProviderUploadReceipt(
                id: id, driveID: driveID, uri: uri, completedAt: completedAt)
            try FileProviderStateDatabase().put("fileprovider-upload-receipts", "\(id).json", JSONEncoder().encode(receipt))
        } catch {
            Logger(subsystem: "cloudreve.desktop.dev.fileprovider", category: "activity").error(
                "could not persist upload receipt: \(error.localizedDescription, privacy: .public)")
        }
    }

}

enum FileProviderActivityStore {
    private static let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "activity")
    private static let namespace = "fileprovider-activity"

    /// Preserve other transfers when multiple extension processes update a drive.
    private static func update(driveID: String, _ body: (inout [FileProviderActivityRecord]) -> Void) {
        do {
            let database = try FileProviderStateDatabase()
            try database.importRecords(namespace)
            try database.transaction {
                let payload = try database.rows("SELECT payload FROM fp_records WHERE namespace=? AND key=?", [namespace, "\(driveID).json"]).first?.first
                var records = try payload.map { try JSONDecoder().decode([FileProviderActivityRecord].self, from: Data($0.utf8)) } ?? []
                body(&records)
                let value = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
                try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", [namespace, "\(driveID).json", value])
            }
        } catch {
            logger.error("could not persist activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func upsert(_ record: FileProviderActivityRecord) {
        update(driveID: record.driveID) { records in
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else { records.append(record) }
            let cutoff = Int64(Date().timeIntervalSince1970) - 24 * 60 * 60
            let running = records.filter { $0.status == "running" }
            let completed = records.filter { $0.status != "running" && $0.updatedAt >= cutoff }
                .sorted { $0.updatedAt > $1.updatedAt }.prefix(100)
            records = running + completed
        }
    }

    static func markInterruptedActivitiesFailed(driveID: String) {
        update(driveID: driveID) { records in
            for index in records.indices where records[index].status == "running" {
                records[index].status = "failed"
                records[index].error = "The transfer was interrupted."
                records[index].updatedAt = Int64(Date().timeIntervalSince1970)
            }
        }
    }

    static func records(driveID: String) -> [FileProviderActivityRecord] {
        do {
            guard let data = try FileProviderStateDatabase().get(namespace, "\(driveID).json") else { return [] }
            return try JSONDecoder().decode([FileProviderActivityRecord].self, from: data)
        } catch {
            logger.error("could not read activity: \(error.localizedDescription, privacy: .public)")
            return []
        }
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
        guard record.status == "running" else {
            stateLock.unlock()
            return
        }
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
        if snapshot.operation == "upload" && snapshot.status == "completed" {
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
        guard record.status == "running" else {
            let snapshot = record
            stateLock.unlock()
            return snapshot
        }
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
