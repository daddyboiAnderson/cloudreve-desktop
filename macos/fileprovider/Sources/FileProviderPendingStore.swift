import FileProvider
import Foundation
import OSLog
import UniformTypeIdentifiers

enum FileProviderDownloadRetryStore {
    private static let lifetime: Int64 = 120_000

    static func isRequested(driveID: String, itemIdentifier: String) -> Bool {
        let marker = markerURL(driveID: driveID, itemIdentifier: itemIdentifier)
        guard
            let data = try? Data(contentsOf: marker),
            let value = String(data: data, encoding: .utf8),
            let timestamp = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return false
        }

        let age = Int64(Date().timeIntervalSince1970 * 1_000) - timestamp
        guard age >= -10_000, age <= lifetime else {
            try? FileManager.default.removeItem(at: marker)
            return false
        }
        return true
    }

    static func finish(driveID: String, itemIdentifier: String) {
        try? FileManager.default.removeItem(
            at: markerURL(driveID: driveID, itemIdentifier: itemIdentifier))
    }

    private static func markerURL(driveID: String, itemIdentifier: String) -> URL {
        directoryURL.appendingPathComponent(identifier(driveID, itemIdentifier))
    }

    private static func identifier(_ driveID: String, _ itemIdentifier: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (driveID + "\0" + itemIdentifier).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static var directoryURL: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let directory = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory))
        } else {
            home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        }
        return home.appendingPathComponent(
            ".cloudreve/fileprovider-download-retries", isDirectory: true)
    }
}

enum FileProviderDownloadSuppressionStore {
    private static let lock = NSLock()
    private static var rootsByDrive: [String: [String: Int]] = [:]

    static func begin(driveID: String, uri: String) {
        lock.lock()
        defer { lock.unlock() }
        let root = RemoteStore.canonicalURI(uri)
        rootsByDrive[driveID, default: [:]][root, default: 0] += 1
    }

    static func end(driveID: String, uri: String) {
        lock.lock()
        defer { lock.unlock() }
        let root = RemoteStore.canonicalURI(uri)
        guard var roots = rootsByDrive[driveID], let count = roots[root] else { return }
        if count > 1 {
            roots[root] = count - 1
        } else {
            roots.removeValue(forKey: root)
        }
        rootsByDrive[driveID] = roots.isEmpty ? nil : roots
    }

    static func contains(driveID: String, uri: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let target = RemoteStore.canonicalURI(uri)
        return rootsByDrive[driveID]?.keys.contains { root in
            target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        } ?? false
    }
}

struct FileProviderPendingRecord: Codable {
    let itemIdentifier: String
    let filename: String
    let isFolder: Bool
    let operation: String
    let errorDomain: String
    let errorCode: Int
    let message: String

    enum CodingKeys: String, CodingKey {
        case filename, operation, message
        case itemIdentifier = "item_identifier"
        case isFolder = "is_folder"
        case errorDomain = "error_domain"
        case errorCode = "error_code"
    }
}

private struct FileProviderPendingSnapshot: Codable {
    let driveID: String
    let driveName: String
    let updatedAt: Int64
    let items: [FileProviderPendingRecord]

    enum CodingKeys: String, CodingKey {
        case items
        case driveID = "drive_id"
        case driveName = "drive_name"
        case updatedAt = "updated_at"
    }
}

final class FileProviderPendingMonitor {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "pending")
    private let drive: DriveConfig
    private let domain: NSFileProviderDomain
    private let queue = DispatchQueue(label: "cloudreve.fileprovider.pending")
    private var observer: PendingItemsObserver?
    private var refreshing = false
    private var refreshAgain = false
    private var currentCompletions: [() -> Void] = []
    private var queuedCompletions: [() -> Void] = []

    init(drive: DriveConfig, domain: NSFileProviderDomain) {
        self.drive = drive
        self.domain = domain
    }

    func refresh(completion: @escaping () -> Void = {}) {
        queue.async {
            if self.refreshing {
                self.refreshAgain = true
                self.queuedCompletions.append(completion)
                return
            }
            self.currentCompletions = [completion]
            self.startRefresh()
        }
    }

    private func startRefresh() {
        guard let manager = NSFileProviderManager(for: domain) else {
            finishRefresh()
            return
        }

        refreshing = true
        let enumerator = manager.enumeratorForPendingItems()
        let observer = PendingItemsObserver(enumerator: enumerator) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.observer = nil
                switch result {
                case .success(let items):
                    do {
                        try self.write(items: items)
                    } catch {
                        self.logger.error(
                            "could not persist pending items: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                case .failure(let error):
                    self.logger.error(
                        "could not enumerate pending items: \(error.localizedDescription, privacy: .public)"
                    )
                }
                self.finishRefresh()
            }
        }
        self.observer = observer
        enumerator.enumerateItems(
            for: observer, startingAt: NSFileProviderPage(rawValue: Data()))
    }

    private func finishRefresh() {
        refreshing = false
        let callbacks = currentCompletions
        currentCompletions.removeAll()
        callbacks.forEach { $0() }
        if refreshAgain {
            refreshAgain = false
            currentCompletions = queuedCompletions
            queuedCompletions.removeAll()
            startRefresh()
        }
    }

    private func write(items: [NSFileProviderItem]) throws {
        let failures = items.compactMap { item -> FileProviderPendingRecord? in
            let operation: String
            let error: NSError
            if let uploadError = item.uploadingError ?? nil {
                operation = "upload"
                error = uploadError as NSError
            } else if let downloadError = item.downloadingError ?? nil {
                operation = "download"
                error = downloadError as NSError
            } else {
                return nil
            }

            return FileProviderPendingRecord(
                itemIdentifier: item.itemIdentifier.rawValue,
                filename: item.filename,
                isFolder: (item.contentType ?? nil)?.conforms(to: .folder) ?? false,
                operation: operation,
                errorDomain: error.domain,
                errorCode: error.code,
                message: error.localizedDescription)
        }

        let snapshot = FileProviderPendingSnapshot(
            driveID: drive.id,
            driveName: drive.name,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            items: failures)
        let directory = Self.directoryURL
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("\(drive.id).json")
        try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        logger.notice("recorded \(failures.count) failed pending item(s)")
    }

    private static var directoryURL: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let directory = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory))
        } else {
            home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        }
        return home.appendingPathComponent(".cloudreve/fileprovider-pending", isDirectory: true)
    }
}

private final class PendingItemsObserver: NSObject, NSFileProviderEnumerationObserver {
    private let enumerator: NSFileProviderEnumerator
    private let completion: (Result<[NSFileProviderItem], Error>) -> Void
    private var items: [NSFileProviderItem] = []
    private var finished = false

    init(
        enumerator: NSFileProviderEnumerator,
        completion: @escaping (Result<[NSFileProviderItem], Error>) -> Void
    ) {
        self.enumerator = enumerator
        self.completion = completion
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        items.append(contentsOf: updatedItems)
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        guard !finished else { return }
        if let nextPage {
            enumerator.enumerateItems(for: self, startingAt: nextPage)
        } else {
            finished = true
            completion(.success(items))
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        guard !finished else { return }
        finished = true
        completion(.failure(error))
    }
}
