import FileProvider
import AppKit
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
                let deleteGeneration = store.remoteDeleteGeneration(for: uri)

                // Ignore replayed creates for known items.
                if store.isKnownIdentity(itemTemplate.itemIdentifier, forURI: uri) {
                    do {
                        let existing = try await store.client.fileInfoWithShareState(uri: uri)
                        completionHandler(
                            store.makeItem(
                                existing, preservingIdentifier: itemTemplate.itemIdentifier),
                            [], false, nil)
                        return
                    } catch CloudreveError.noSuchItem {
                        store.evictCachedItems(
                            withIdentifiers: [itemTemplate.itemIdentifier])
                        logger.notice(
                            "discarded stale mirrored create for remotely absent \(uri, privacy: .public)"
                        )
                        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                        return
                    }
                }

                let file: RemoteFile
                if isFolder {
                    file = try await store.client.createFileOrFolder(uri: uri, isFolder: true)
                } else if let contentURL = url {
                    // Upload files with supplied content.
                    try await store.client.uploadFile(
                        at: uri, from: contentURL, overwrite: false, progress: progress)
                    file = try await store.client.fileInfoWithShareState(uri: uri)
                } else {
                    file = try await store.client.createFileOrFolder(uri: uri, isFolder: false)
                }

                // Do not recreate an item deleted during upload.
                if store.remoteDeleteOccurred(for: uri, after: deleteGeneration) {
                    try? await store.client.deleteFile(uri: uri)
                    let remoteIdentifier = store.identifier(forURI: uri)
                    store.evictCachedItems(withIdentifiers: [
                        itemTemplate.itemIdentifier, remoteIdentifier,
                    ])
                    logger.notice(
                        "discarded local create superseded by remote delete for \(uri, privacy: .public)"
                    )
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                logger.notice("created \(uri, privacy: .public)")
                completionHandler(store.makeItem(file), [], false, nil)

                // Recheck new uploads because immediate deletes may have no events.
                Task {
                    for delay in [2, 6, 22] {
                        try? await Task.sleep(for: .seconds(delay))
                        if Task.isCancelled { return }
                        do {
                            guard try await Self.itemStillInParent(
                                store: store, uri: uri, remoteID: file.id)
                            else { throw CloudreveError.noSuchItem }
                        } catch CloudreveError.noSuchItem {
                            let identifier = store.identifier(forURI: uri)
                            store.queueStabilizationDelete(identifier)
                            logger.notice(
                                "queued stabilization delete for \(uri, privacy: .public)"
                            )
                            await store.signalWorkingSet()
                            return
                        } catch {
                            logger.error(
                                "stabilization check failed for \(uri, privacy: .public): \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                }
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
                let originalURI = uri
                let deleteGeneration = store.remoteDeleteGeneration(for: originalURI)
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

                if store.remoteDeleteOccurred(
                    for: originalURI, after: deleteGeneration)
                {
                    try? await store.client.deleteFile(uri: uri)
                    store.evictCachedItems(withIdentifiers: [item.itemIdentifier])
                    logger.notice(
                        "discarded local modification superseded by remote delete for \(originalURI, privacy: .public)"
                    )
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                // Read back fresh metadata so the system records the new version.
                let fresh = try await store.client.fileInfoWithShareState(uri: uri)
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
                store.evictCachedItems(withIdentifiers: [identifier])
                logger.notice("deleted \(identifier.rawValue, privacy: .public)")
                completionHandler(nil)
            } catch CloudreveError.noSuchItem {
                // Treat an already-removed item as deleted.
                store.evictCachedItems(withIdentifiers: [identifier])
                logger.notice(
                    "delete acknowledged for already absent \(identifier.rawValue, privacy: .public)"
                )
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

    // MARK: - Custom actions

    private static let keepDownloadedAction =
        "cloudreve.desktop.dev.fileprovider.KeepDownloaded"
    private static let removeKeepDownloadedAction =
        "cloudreve.desktop.dev.fileprovider.RemoveKeepDownloaded"
    private static let shareAction =
        "cloudreve.desktop.dev.fileprovider.Share"
    private static let openInBrowserAction =
        "cloudreve.desktop.dev.fileprovider.OpenInBrowser"

    /// Handles Finder actions and forwards Share targets to the main app.
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))

        if actionIdentifier.rawValue == Self.openInBrowserAction {
            guard let store else {
                completionHandler(unavailableError)
                return progress
            }
            guard itemIdentifiers.count == 1 else {
                completionHandler(
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSUserCancelledError,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Select one file or folder to open in the browser."
                        ]))
                return progress
            }

            let identifier = itemIdentifiers[0]
            let task = Task {
                do {
                    let item = try await store.item(
                        for: identifier, displayName: domain.displayName, refreshIfStale: true)
                    guard let url = store.browserURL(for: identifier, item: item) else {
                        throw NSError(
                            domain: NSURLErrorDomain,
                            code: NSURLErrorBadURL,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Could not create the Cloudreve browser URL."
                            ])
                    }
                    guard NSWorkspace.shared.open(url) else {
                        throw NSError(
                            domain: NSCocoaErrorDomain,
                            code: NSFeatureUnsupportedError,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Could not open the default browser."
                            ])
                    }
                    progress.completedUnitCount = 1
                    completionHandler(nil)
                } catch {
                    logger.error(
                        "OpenInBrowser failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    completionHandler(error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }

        if actionIdentifier.rawValue == Self.shareAction {
            guard let store else {
                completionHandler(unavailableError)
                return progress
            }
            guard itemIdentifiers.count == 1 else {
                completionHandler(
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSUserCancelledError,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Select one file or folder to share."
                        ]))
                return progress
            }

            let identifier = itemIdentifiers[0]
            guard identifier != .rootContainer else {
                completionHandler(
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFeatureUnsupportedError,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The drive root cannot be shared."
                        ]))
                return progress
            }

            var components = URLComponents()
            components.scheme = "cloudreve"
            components.host = "share"
            components.queryItems = [
                URLQueryItem(name: "drive_id", value: store.drive.id),
                URLQueryItem(name: "uri", value: store.uri(for: identifier)),
            ]
            guard let url = components.url else {
                completionHandler(
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSURLErrorBadURL,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not create a Share URL."
                        ]))
                return progress
            }

            guard NSWorkspace.shared.open(url) else {
                completionHandler(
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFeatureUnsupportedError,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Cloudreve is not available to open Share."
                        ]))
                return progress
            }

            progress.completedUnitCount = 1
            completionHandler(nil)
            return progress
        }

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
        if pin {
            progress.kind = .file
            progress.fileOperationKind = .downloading
            progress.fileTotalCount = itemIdentifiers.count
            progress.fileCompletedCount = 0
        }
        let itemProgresses: [Progress]
        if itemIdentifiers.count == 1 {
            itemProgresses = [progress]
        } else {
            itemProgresses = itemIdentifiers.map { _ in Progress(totalUnitCount: 1) }
            for itemProgress in itemProgresses {
                progress.addChild(itemProgress, withPendingUnitCount: 1)
            }
        }

        // Update the desired state immediately so a newer opposite action can
        // stop an older download or eviction while it is still running.
        for identifier in itemIdentifiers {
            store.setPinned(pin, for: identifier)
        }

        let task = Task {
            var firstError: Error?
            for (index, identifier) in itemIdentifiers.enumerated() {
                if Task.isCancelled || progress.isCancelled {
                    firstError = CocoaError(.userCancelled)
                    break
                }
                do {
                    let item = try await store.refreshItem(
                        for: identifier, displayName: domain.displayName)
                    await store.withActionLock {
                        await setPinned(
                            pin, for: identifier, item: item, store: store, manager: manager,
                            progress: itemProgresses[index])
                    }
                } catch {
                    logger.error(
                        "\(actionIdentifier.rawValue, privacy: .public) failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    firstError = firstError ?? error
                    if !Task.isCancelled {
                        itemProgresses[index].completedUnitCount =
                            itemProgresses[index].totalUnitCount
                    }
                }
            }
            logger.notice(
                "completed \(actionIdentifier.rawValue, privacy: .public) for \(itemIdentifiers.count) item(s)"
            )
            completionHandler(firstError)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// Refresh working-set metadata and materialize or evict content.
    private func setPinned(
        _ pin: Bool,
        for identifier: NSFileProviderItemIdentifier,
        item: FileProviderItem,
        store: RemoteStore,
        manager: NSFileProviderManager,
        progress: Progress
    ) async {
        let isFolder =
            identifier == .rootContainer || item.contentType.conforms(to: .folder)

        var publishedProgress = false
        if pin && isFolder && identifier != .rootContainer {
            do {
                progress.fileURL = try await manager.getUserVisibleURL(for: identifier)
                progress.publish()
                publishedProgress = true
            } catch {
                logger.notice(
                    "could not publish folder progress for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        defer {
            if publishedProgress {
                progress.unpublish()
            }
        }

        var descendants: [FileProviderItem] = []
        if isFolder {
            descendants = await listSubtree(of: identifier, store: store)
        }

        let descendantFiles = descendants.filter {
            !$0.contentType.conforms(to: .folder)
        }
        if isFolder && pin {
            let expectedBytes = descendantFiles.reduce(Int64(0)) {
                $0 + max($1.documentSize?.int64Value ?? 0, 1)
            }
            progress.totalUnitCount = max(expectedBytes, 1)
            progress.fileTotalCount = max(descendantFiles.count, 1)
            progress.fileCompletedCount = 0
        } else if pin {
            progress.fileTotalCount = 1
            progress.fileCompletedCount = 0
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
                progress.fileCompletedCount = progress.fileTotalCount
            }
        } else if pin && isFolder {
            if identifier != .rootContainer {
                _ = await store.requestDownloadWhenKnown(identifier, manager: manager)
            }
            // File Provider does not recursively materialize folders.
            for start in stride(from: 0, to: descendantFiles.count, by: 8) {
                if Task.isCancelled { return }
                let end = min(start + 8, descendantFiles.count)
                await withTaskGroup(of: Bool.self) { group in
                    for descendant in descendantFiles[start..<end] {
                        group.addTask {
                            guard store.isEffectivelyPinned(
                                descendant.itemIdentifier,
                                uri: store.uri(for: descendant.itemIdentifier)
                            ) else { return true }
                            return await store.requestDownloadWhenKnown(
                                descendant.itemIdentifier, manager: manager)
                        }
                    }
                    await group.waitForAll()
                }
            }
            await trackFolderDownloads(
                below: identifier, manager: manager, progress: progress)
            progress.completedUnitCount = progress.totalUnitCount
            progress.fileCompletedCount = progress.fileTotalCount
        } else if !pin {
            // Evict files not covered by another pin.
            let filesToEvict: [NSFileProviderItemIdentifier]
            if isFolder {
                // Evict folder descendants explicitly.
                filesToEvict = descendants.compactMap { descendant in
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
                filesToEvict = store.isEffectivelyPinned(identifier, uri: selectedURI)
                    ? [] : [identifier]
            }
            progress.totalUnitCount = max(Int64(filesToEvict.count), 1)
            if filesToEvict.isEmpty {
                progress.completedUnitCount = progress.totalUnitCount
            }

            var failedEvictions: [NSFileProviderItemIdentifier] = []
            for start in stride(from: 0, to: filesToEvict.count, by: 8) {
                if Task.isCancelled { return }
                let end = min(start + 8, filesToEvict.count)
                await withTaskGroup(of: (NSFileProviderItemIdentifier, Bool).self) { group in
                    for fileIdentifier in filesToEvict[start..<end] {
                        group.addTask {
                            let success = await store.evictWhenAllowed(
                                fileIdentifier, manager: manager)
                            return (fileIdentifier, success)
                        }
                    }
                    for await (fileIdentifier, success) in group {
                        progress.completedUnitCount += 1
                        if !success {
                            failedEvictions.append(fileIdentifier)
                        }
                    }
                }
            }
            if !failedEvictions.isEmpty {
                let identifiers = failedEvictions.prefix(3).map(\.rawValue).joined(separator: ", ")
                logger.notice(
                    "deferring eviction while downloads settle for \(identifiers, privacy: .public)"
                )
                store.retryEvictionsWhenUnpinned(failedEvictions, manager: manager)
            }
        }
        if descendantFiles.isEmpty || !isFolder {
            progress.completedUnitCount = progress.totalUnitCount
            if pin {
                progress.fileCompletedCount = progress.fileTotalCount
            }
        }
        logger.notice(
            "\(pin ? "pinned" : "unpinned", privacy: .public) \(identifier.rawValue, privacy: .public)"
        )
    }

    /// Mirror File Provider's actual download progress onto a folder.
    private func trackFolderDownloads(
        below identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager,
        progress: Progress
    ) async {
        let systemProgress = manager.globalProgress(for: .downloading)
        let activityDeadline = Date().addingTimeInterval(1.5)
        var sawActivity = false
        var idleSince: Date?

        while !Task.isCancelled && !progress.isCancelled {
            let total = systemProgress.totalUnitCount
            let completed = systemProgress.completedUnitCount
            let isActive = total > 0 && completed < total

            if isActive {
                if !sawActivity {
                    logger.notice(
                        "tracking folder downloads below \(identifier.rawValue, privacy: .public)"
                    )
                }
                sawActivity = true
                idleSince = nil
                progress.totalUnitCount = max(total, 1)
                progress.completedUnitCount = min(completed, total)
                if let totalFiles = systemProgress.fileTotalCount {
                    progress.fileTotalCount = totalFiles
                }
                if let completedFiles = systemProgress.fileCompletedCount {
                    progress.fileCompletedCount = completedFiles
                }
            } else if sawActivity {
                if let idleSince {
                    if Date().timeIntervalSince(idleSince) >= 0.3 { break }
                } else {
                    idleSince = Date()
                }
            } else if Date() >= activityDeadline {
                break
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        logger.notice(
            "folder downloads settled below \(identifier.rawValue, privacy: .public)"
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

    private static func itemStillInParent(
        store: RemoteStore, uri: String, remoteID: String
    ) async throws -> Bool {
        let parent = parentURI(of: uri)
        var page: String?
        repeat {
            let result = try await store.client.listDirectory(uri: parent, page: page)
            if result.files.contains(where: { $0.id == remoteID }) { return true }
            page = result.nextPage
        } while page != nil
        return false
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
