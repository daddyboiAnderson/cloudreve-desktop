import FileProvider
import OSLog

/// Replicated File Provider backed by the Cloudreve API.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
    NSFileProviderThumbnailing, NSFileProviderCustomAction
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
            // Resume downloads for persisted pins.
            if let store = self.store {
                Task { await store.requestDownloadsForPinnedItems() }
            }
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
            // Fetch thumbnails in small concurrent batches.
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
        let task = Task {
            do {
                // Refresh metadata before serving content.
                let item = try await store.item(
                    for: itemIdentifier, displayName: domain.displayName)
                if request.isSystemRequest,
                    !store.isEffectivelyPinned(
                        itemIdentifier, uri: store.uri(for: itemIdentifier))
                {
                    logger.notice(
                        "cancelled stale system download for \(itemIdentifier.rawValue, privacy: .public)"
                    )
                    completionHandler(nil, nil, CocoaError(.userCancelled))
                    return
                }
                let downloadURL = try await store.client.downloadURL(
                    for: store.uri(for: itemIdentifier))
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cloudreve-fp-\(UUID().uuidString)")
                let size = item.documentSize?.int64Value ?? 0
                try await store.client.download(
                    downloadURL, to: tmp, itemSize: size, progress: progress)
                if request.isSystemRequest,
                    !store.isEffectivelyPinned(
                        itemIdentifier, uri: store.uri(for: itemIdentifier))
                {
                    try? FileManager.default.removeItem(at: tmp)
                    logger.notice(
                        "discarded stale system download for \(itemIdentifier.rawValue, privacy: .public)"
                    )
                    completionHandler(nil, nil, CocoaError(.userCancelled))
                    return
                }
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
        progress.cancellationHandler = { task.cancel() }
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

        // Finder metadata stays local-only.
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
                contentModificationDate: nil,
                pinned: false
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
                    // Upload files with supplied content.
                    try await store.client.uploadFile(
                        at: uri, from: contentURL, overwrite: false, progress: progress)
                    file = try await store.client.fileInfo(uri: uri)
                } else {
                    file = try await store.client.createFileOrFolder(uri: uri, isFolder: false)
                }
                logger.notice("created \(uri, privacy: .public)")
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

        // Finder metadata stays local-only.
        guard !RemoteStore.isIgnored(filename: item.filename) else {
            completionHandler(item, [], false, nil)
            return progress
        }

        Task {
            do {
                var uri = store.uri(for: item.itemIdentifier)
                var pending = changedFields

                // Apply supported content, name, and parent changes.
                if changedFields.contains(.contents), let newContents {
                    try await store.client.uploadFile(
                        at: uri, from: newContents, overwrite: true, progress: progress)
                    pending.remove(.contents)
                }

                if changedFields.contains(.filename) {
                    _ = try await store.client.renameFile(uri: uri, to: item.filename)
                    uri = Self.parentURI(of: uri) + "/" + item.filename
                    pending.remove(.filename)
                }

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
        // Finder metadata is local-only.
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

    // MARK: - Custom actions ("Keep Downloaded")

    private static let keepDownloadedAction =
        "cloudreve.desktop.dev.fileprovider.KeepDownloaded"
    private static let removeKeepDownloadedAction =
        "cloudreve.desktop.dev.fileprovider.RemoveKeepDownloaded"

    /// Handles the Keep Downloaded custom actions.
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let pin: Bool
        switch actionIdentifier.rawValue {
        case Self.keepDownloadedAction: pin = true
        case Self.removeKeepDownloadedAction: pin = false
        default:
            completionHandler(
                NSError(
                    domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unknown action \(actionIdentifier.rawValue)"
                    ]))
            return progress
        }
        guard let store, let manager = NSFileProviderManager(for: domain) else {
            completionHandler(unavailableError)
            return progress
        }

        let task = Task {
            var firstError: Error?
            for identifier in itemIdentifiers {
                if Task.isCancelled || progress.isCancelled {
                    completionHandler(CocoaError(.userCancelled))
                    return
                }
                do {
                    try await setPinned(
                        pin, for: identifier, store: store, manager: manager)
                } catch {
                    logger.error(
                        "\(actionIdentifier.rawValue, privacy: .public) failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    firstError = firstError ?? error
                }
                progress.completedUnitCount += 1
            }
            completionHandler(firstError)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// Persist the pin, refresh working-set metadata, and materialize or evict content.
    private func setPinned(
        _ pin: Bool,
        for identifier: NSFileProviderItemIdentifier,
        store: RemoteStore,
        manager: NSFileProviderManager
    ) async throws {
        let item = try await store.item(
            for: identifier, displayName: domain.displayName)
        store.setPinned(pin, for: identifier)
        let isFolder =
            identifier == .rootContainer || item.contentType.conforms(to: .folder)

        var descendants: [FileProviderItem] = []
        if isFolder {
            descendants = await listSubtree(of: identifier, store: store)
        }

        // Queue the selected item and folder descendants for re-enumeration.
        var updates = descendants.map { store.uri(for: $0.itemIdentifier) }
        if identifier != .rootContainer {
            updates.append(store.uri(for: identifier))
        }
        store.recordPendingItemUpdates(uris: updates)
        do {
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            logger.error(
                "signalEnumerator failed: \(error.localizedDescription, privacy: .public)")
        }

        if pin && !isFolder {
            // Use the same path as Finder's Download Now action.
            if store.isEffectivelyPinned(identifier, uri: store.uri(for: identifier)) {
                _ = await store.requestDownloadWhenKnown(identifier, manager: manager)
            }
        } else if pin && isFolder {
            // File Provider does not recursively materialize directories.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let files = descendants.filter {
                !$0.contentType.conforms(to: .folder)
            }
            for start in stride(from: 0, to: files.count, by: 8) {
                if Task.isCancelled { return }
                let end = min(start + 8, files.count)
                await withTaskGroup(of: Void.self) { group in
                    for descendant in files[start..<end] {
                        group.addTask {
                            guard store.isEffectivelyPinned(
                                descendant.itemIdentifier,
                                uri: store.uri(for: descendant.itemIdentifier)
                            ) else { return }
                            _ = await store.requestDownloadWhenKnown(
                                descendant.itemIdentifier, manager: manager)
                        }
                    }
                }
            }
        } else if !pin {
            // Inherited policy permits eviction but does not remove existing content.
            try? await Task.sleep(nanoseconds: 500_000_000)

            let files: [NSFileProviderItemIdentifier]
            if isFolder {
                // File Provider does not reliably evict provider folders recursively.
                files = descendants.compactMap { descendant in
                    guard !descendant.contentType.conforms(to: .folder) else {
                        return nil
                    }
                    let descendantURI = store.uri(for: descendant.itemIdentifier)
                    return store.isEffectivelyPinned(
                        descendant.itemIdentifier, uri: descendantURI)
                        ? nil : descendant.itemIdentifier
                }
            } else {
                let selectedURI = store.uri(for: identifier)
                files = store.isEffectivelyPinned(identifier, uri: selectedURI)
                    ? [] : [identifier]
            }

            var failedEvictions: [NSFileProviderItemIdentifier] = []
            for start in stride(from: 0, to: files.count, by: 8) {
                if Task.isCancelled { return }
                let end = min(start + 8, files.count)
                await withTaskGroup(of: (NSFileProviderItemIdentifier, Bool).self) { group in
                    for fileIdentifier in files[start..<end] {
                        group.addTask {
                            let success = await store.evictWhenAllowed(
                                fileIdentifier, manager: manager)
                            return (fileIdentifier, success)
                        }
                    }
                    for await (fileIdentifier, success) in group {
                        if !success {
                            failedEvictions.append(fileIdentifier)
                        }
                    }
                }
            }
            if !failedEvictions.isEmpty {
                let identifiers = failedEvictions.prefix(3).map(\.rawValue).joined(separator: ", ")
                throw NSError(
                    domain: "CloudreveFileProvider",
                    code: NSFileWriteUnknownError,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not remove downloaded content for: \(identifiers.isEmpty ? identifier.rawValue : identifiers)"
                    ])
            }
        }
        logger.notice(
            "\(pin ? "pinned" : "unpinned", privacy: .public) \(identifier.rawValue, privacy: .public)"
        )
    }

    /// List every remote descendant of an item.
    private func listSubtree(
        of identifier: NSFileProviderItemIdentifier,
        store: RemoteStore
    ) async -> [FileProviderItem] {
        var result: [FileProviderItem] = []
        var queue = [identifier]
        while !queue.isEmpty {
            if Task.isCancelled { return result }
            let current = queue.removeFirst()
            var page: String? = nil
            repeat {
                do {
                    let (items, nextPage) = try await store.children(
                        of: current, page: page)
                    page = nextPage
                    for child in items {
                        result.append(child)
                        if child.contentType.conforms(to: .folder) {
                            queue.append(child.itemIdentifier)
                        }
                    }
                } catch {
                    logger.error(
                        "listSubtree listing of \(current.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    page = nil
                }
            } while page != nil
        }
        return result
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
        // Route trash operations to the server.
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
