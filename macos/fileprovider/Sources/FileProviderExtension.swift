import FileProvider
import OSLog

/// Replicated file provider backed by the Cloudreve API.
///
/// The system launches this extension on demand and talks to it over XPC.
/// Domains are registered per drive by the main app; the domain identifier
/// embeds the drive id ("cloudreve.drive.<uuid>").
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
    NSFileProviderThumbnailing
{
    private let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "extension")

    private static let domainPrefix = "cloudreve.drive."

    private let domain: NSFileProviderDomain
    private let store: RemoteStore?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let driveID = domain.identifier.rawValue.hasPrefix(Self.domainPrefix)
            ? String(domain.identifier.rawValue.dropFirst(Self.domainPrefix.count))
            : domain.identifier.rawValue
        if let drive = DriveStore.loadDrive(driveID: driveID) {
            self.store = RemoteStore(drive: drive, domain: domain)
            logger.notice(
                "FileProviderExtension started for domain \(domain.displayName, privacy: .public), drive \(drive.name, privacy: .public) @ \(drive.instance_url, privacy: .public)"
            )
        } else {
            self.store = nil
            logger.error(
                "no drive config found for domain \(domain.identifier.rawValue, privacy: .public)")
        }
        super.init()
    }

    func invalidate() {
        logger.notice("FileProviderExtension invalidated")
    }

    private var unavailableError: Error {
        NSFileProviderError(.notAuthenticated)
    }

    // MARK: - Metadata

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard let store else {
            completionHandler(nil, unavailableError)
            return Progress()
        }
        Task {
            do {
                let item = try await store.item(
                    for: identifier, displayName: domain.displayName)
                completionHandler(item, nil)
            } catch {
                logger.error(
                    "item(for: \(identifier.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, FileProviderEnumerator.mapError(error))
            }
        }
        return Progress()
    }

    // MARK: - Content

    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (
            NSFileProviderItemIdentifier, Data?, Error?
        ) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        logger.notice(
            "Finder requested \(itemIdentifiers.count) thumbnail(s) at \(Int(size.width))x\(Int(size.height))"
        )
        guard let store else {
            completionHandler(unavailableError)
            return progress
        }

        let task = Task {
            // File Provider allows only a few tens of seconds for a whole
            // batch. Fetch concurrently in small chunks so a large Finder
            // window does not serialize two network round-trips per item.
            for batchStart in stride(from: 0, to: itemIdentifiers.count, by: 4) {
                if Task.isCancelled || progress.isCancelled {
                    completionHandler(CocoaError(.userCancelled))
                    return
                }
                let batchEnd = min(batchStart + 4, itemIdentifiers.count)
                await withTaskGroup(of: Void.self) { group in
                    for identifier in itemIdentifiers[batchStart..<batchEnd] {
                        group.addTask {
                            do {
                                let item = try await store.item(
                                    for: identifier, displayName: self.domain.displayName)
                                if item.contentType.conforms(to: .folder) {
                                    perThumbnailCompletionHandler(identifier, nil, nil)
                                } else {
                                    let data = try await store.client.thumbnail(
                                        uri: store.uri(for: identifier))
                                    perThumbnailCompletionHandler(identifier, data, nil)
                                }
                            } catch {
                                // A missing/unsupported thumbnail is an
                                // item-level failure; it must not prevent Finder
                                // from displaying the rest of the batch.
                                self.logger.notice(
                                    "thumbnail unavailable for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                                )
                                perThumbnailCompletionHandler(
                                    identifier, nil, FileProviderEnumerator.mapError(error))
                            }
                            progress.completedUnitCount += 1
                        }
                    }
                }
            }
            completionHandler(nil)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        guard let store else {
            completionHandler(nil, nil, unavailableError)
            return progress
        }
        Task {
            do {
                // Refresh the item so the system records the served version.
                let item = try await store.item(
                    for: itemIdentifier, displayName: domain.displayName)
                let downloadURL = try await store.client.downloadURL(
                    for: store.uri(for: itemIdentifier))
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cloudreve-fp-\(UUID().uuidString)")
                let size = item.documentSize?.int64Value ?? 0
                try await store.client.download(
                    downloadURL, to: tmp, itemSize: size, progress: progress)
                logger.notice(
                    "served contents of \(item.filename, privacy: .public) (\(size) bytes)")
                completionHandler(tmp, item, nil)
            } catch {
                logger.error(
                    "fetchContents failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, nil, FileProviderEnumerator.mapError(error))
            }
        }
        return progress
    }

    // MARK: - Mutations

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        guard let store else {
            completionHandler(nil, [], false, unavailableError)
            return progress
        }

        // Ignored files (Finder metadata): keep them local-only by reporting
        // success without uploading.
        guard !RemoteStore.isIgnored(filename: itemTemplate.filename) else {
            let item = FileProviderItem(
                identifier: NSFileProviderItemIdentifier(
                    store.uri(for: itemTemplate.parentItemIdentifier) + "/"
                        + itemTemplate.filename),
                parentIdentifier: itemTemplate.parentItemIdentifier,
                filename: itemTemplate.filename,
                contentType: itemTemplate.contentType ?? .data,
                documentSize: url
                    .flatMap {
                        try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]
                            as? NSNumber
                    }
                    .map { Int($0.int64Value) },
                childItemCount: nil,
                capabilities: [.allowsReading, .allowsWriting, .allowsDeleting],
                contentVersion: Data("local".utf8),
                metadataVersion: Data("local".utf8),
                creationDate: nil,
                contentModificationDate: nil
            )
            completionHandler(item, [], false, nil)
            return progress
        }

        Task {
            do {
                let parentURI = store.uri(for: itemTemplate.parentItemIdentifier)
                let uri = parentURI + "/" + itemTemplate.filename
                let isFolder = itemTemplate.contentType?.conforms(to: .folder) ?? false

                let file: RemoteFile
                if isFolder {
                    file = try await store.client.createFileOrFolder(uri: uri, isFolder: true)
                } else if let contentURL = url {
                    // New file with content: upload, then read back the created entry.
                    try await store.client.uploadFile(
                        at: uri, from: contentURL, overwrite: false, progress: progress)
                    file = try await store.client.fileInfo(uri: uri)
                } else {
                    file = try await store.client.createFileOrFolder(uri: uri, isFolder: false)
                }
                logger.notice("created \(uri, privacy: .public)")
                // Filename and parent are set server-side by construction.
                completionHandler(store.makeItem(file), [], false, nil)
            } catch {
                logger.error(
                    "createItem \(itemTemplate.filename, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, [], false, FileProviderEnumerator.mapError(error))
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) ->
            Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        guard let store else {
            completionHandler(nil, [], false, unavailableError)
            return progress
        }

        // Ignored files (Finder metadata): report success without uploading.
        guard !RemoteStore.isIgnored(filename: item.filename) else {
            completionHandler(item, [], false, nil)
            return progress
        }

        Task {
            do {
                var uri = store.uri(for: item.itemIdentifier)
                var pending = changedFields

                // 1. New content: upload as a new version of the file.
                if changedFields.contains(.contents), let newContents {
                    try await store.client.uploadFile(
                        at: uri, from: newContents, overwrite: true, progress: progress)
                    pending.remove(.contents)
                }

                // 2. Rename.
                if changedFields.contains(.filename) {
                    _ = try await store.client.renameFile(uri: uri, to: item.filename)
                    uri = Self.parentURI(of: uri) + "/" + item.filename
                    pending.remove(.filename)
                }

                // 3. Move to a new parent.
                if changedFields.contains(.parentItemIdentifier) {
                    let dst = store.uri(for: item.parentItemIdentifier)
                    try await store.client.moveFile(uri: uri, toDirectory: dst)
                    uri = dst + "/" + item.filename
                    pending.remove(.parentItemIdentifier)
                }

                // Read back fresh metadata so the system records the new version.
                let fresh = try await store.client.fileInfo(uri: uri)
                logger.notice("modified \(uri, privacy: .public) (fields: \(changedFields.rawValue))")
                completionHandler(
                    store.makeItem(fresh, preservingIdentifier: item.itemIdentifier),
                    pending, false, nil)
            } catch {
                logger.error(
                    "modifyItem \(item.filename, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, [], false, FileProviderEnumerator.mapError(error))
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard let store else {
            completionHandler(unavailableError)
            return Progress()
        }
        // Ignored files are local-only; deleting them is a no-op remotely.
        let filename = identifier.rawValue.components(separatedBy: "/").last ?? ""
        guard !RemoteStore.isIgnored(filename: filename) else {
            completionHandler(nil)
            return Progress()
        }
        Task {
            do {
                try await store.client.deleteFile(uri: store.uri(for: identifier))
                logger.notice("deleted \(identifier.rawValue, privacy: .public)")
                completionHandler(nil)
            } catch {
                logger.error(
                    "deleteItem \(identifier.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(FileProviderEnumerator.mapError(error))
            }
        }
        return Progress()
    }

    private static func parentURI(of uri: String) -> String {
        var u = uri
        if u.hasSuffix("/") { u.removeLast() }
        guard let idx = u.lastIndex(of: "/") else { return u }
        return String(u[..<idx])
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard let store else {
            throw NSFileProviderError(.notAuthenticated)
        }
        // No local trash: declaring it unsupported makes the system call
        // deleteItem immediately when the user "moves to trash", and our
        // deleteItem soft-deletes into the *server* trash.
        if containerItemIdentifier == .trashContainer {
            throw NSError(
                domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Trash is managed by the Cloudreve server."
                ])
        }
        return FileProviderEnumerator(
            containerIdentifier: containerItemIdentifier, store: store)
    }
}
