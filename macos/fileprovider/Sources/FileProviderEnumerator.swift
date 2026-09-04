import FileProvider
import OSLog

/// Enumerates Cloudreve containers and replays remote changes.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "enumerator")

    private let containerIdentifier: NSFileProviderItemIdentifier
    private let store: RemoteStore
    private let refreshLock = NSLock()
    private var needsPresentedContainerRefresh = true

    init(containerIdentifier: NSFileProviderItemIdentifier, store: RemoteStore) {
        self.containerIdentifier = containerIdentifier
        self.store = store
        super.init()
        logger.debug("enumerator init for \(containerIdentifier.rawValue, privacy: .public)")
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        // Working-set enumeration includes cached items and pinned subtrees.
        if containerIdentifier == .workingSet {
            Task {
                do {
                    let items = try await store.workingSetItems()
                    observer.didEnumerate(items)
                    observer.finishEnumerating(upTo: nil)
                } catch {
                    logger.error(
                        "working set enumeration failed: \(error.localizedDescription, privacy: .public)"
                    )
                    observer.finishEnumeratingWithError(Self.mapError(error))
                }
            }
            return
        }

        // Trash is handled by the remote provider.
        guard containerIdentifier != .trashContainer else {
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }

        store.recordPresentedContainer(containerIdentifier)

        let pageToken: String?
        if page.rawValue == NSFileProviderPage.initialPageSortedByName as Data
            || page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data
        {
            pageToken = nil
        } else {
            pageToken = String(data: page.rawValue, encoding: .utf8)
        }

        Task {
            do {
                _ = consumePresentedContainerRefresh()
                let (items, nextPage) = try await store.children(
                    of: containerIdentifier, page: pageToken)
                observer.didEnumerate(items)
                if let nextPage,
                    let data = nextPage.data(using: .utf8)
                {
                    observer.finishEnumerating(upTo: NSFileProviderPage(rawValue: data))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                logger.error(
                    "enumerateItems failed for \(self.containerIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(Self.mapError(error))
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        logger.info(
            "enumerateChanges for \(self.containerIdentifier.rawValue, privacy: .public) from \(String(data: anchor.rawValue, encoding: .utf8) ?? "?", privacy: .public)"
        )
        Task {
            do {
                if containerIdentifier != .workingSet,
                    containerIdentifier != .trashContainer,
                    consumePresentedContainerRefresh()
                {
                    let items = try await store.currentChildren(of: containerIdentifier)
                    if !items.isEmpty {
                        logger.notice(
                            "refreshing \(items.count) presented item(s) in \(self.containerIdentifier.rawValue, privacy: .public)"
                        )
                        observer.didUpdate(items)
                    }
                }
                // Force a full working-set refresh after a policy change.
                if containerIdentifier == .workingSet,
                    store.consumePolicyRescanIfNeeded()
                {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                let changes: [RemoteStore.FpEvent]
                let newAnchor: NSFileProviderSyncAnchor
                do {
                    (changes, newAnchor) = try store.changes(
                        since: anchor.rawValue, for: containerIdentifier)
                } catch let error as NSFileProviderError
                    where error.code == .syncAnchorExpired
                        && containerIdentifier == .workingSet
                {
                    // Reconcile after an expired anchor.
                    logger.notice("anchor expired; reconciling working set with the server")
                    // Keep events received during reconciliation for the next pass.
                    let reconciliationAnchor = store.currentSyncAnchor()
                    logger.notice(
                        "reconciliation captured anchor \(String(data: reconciliationAnchor.rawValue, encoding: .utf8) ?? "?", privacy: .public)"
                    )
                    let (updated, deleted) = try await store.reconcileWorkingSet()
                    if !updated.isEmpty {
                        logger.notice(
                            "reconciliation updating \(updated.count) item(s)")
                        observer.didUpdate(updated)
                    }
                    if !deleted.isEmpty {
                        logger.notice(
                            "reconciliation deleting \(deleted.count) item(s)")
                        observer.didDeleteItems(withIdentifiers: deleted)
                    }
                    observer.finishEnumeratingChanges(
                        upTo: reconciliationAnchor, moreComing: false)
                    return
                }
                var downloadedContentUpdates: [NSFileProviderItemIdentifier] = []
                for change in changes {
                    if let identifier = try await apply(change: change, to: observer) {
                        if change.localEcho != true {
                            downloadedContentUpdates.append(identifier)
                        }
                    }
                }
                // Deliver queued Keep Downloaded policy changes.
                if containerIdentifier == .workingSet {
                    let stabilizationDeletes = store.takeStabilizationDeletes()
                    if !stabilizationDeletes.isEmpty {
                        logger.notice(
                            "delivering \(stabilizationDeletes.count) stabilization delete(s)"
                        )
                        observer.didDeleteItems(withIdentifiers: stabilizationDeletes)
                    }
                    let pending = store.takePendingItemUpdates()
                    if !pending.isEmpty {
                        var items: [NSFileProviderItem] = []
                        var retry: [String] = []
                        for (index, uri) in pending.enumerated() {
                            if Task.isCancelled {
                                retry.append(contentsOf: pending[index...])
                                break
                            }
                            do {
                                let file = try await store.client.fileInfoWithShareState(uri: uri)
                                items.append(store.makeItem(file))
                            } catch CloudreveError.noSuchItem {
                                // The remote delete superseded this update.
                            } catch {
                                retry.append(uri)
                                logger.error(
                                    "policy update item \(uri, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)"
                                )
                            }
                        }
                        if Task.isCancelled {
                            // Retain every dequeued item on cancellation.
                            retry = pending
                        } else if !items.isEmpty {
                            logger.notice(
                                "delivering \(items.count) policy update item(s) to the working set")
                            observer.didUpdate(items)
                        }
                        if !retry.isEmpty {
                            store.recordPendingItemUpdates(uris: retry)
                        }
                    }
                }
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
                if !downloadedContentUpdates.isEmpty {
                    await store.refreshDownloadedContent(downloadedContentUpdates)
                }
            } catch let error as NSFileProviderError where error.code == .syncAnchorExpired {
                logger.info(
                    "anchor expired for \(self.containerIdentifier.rawValue, privacy: .public); system will re-enumerate"
                )
                observer.finishEnumeratingWithError(error)
            } catch {
                logger.error(
                    "enumerateChanges failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    private func consumePresentedContainerRefresh() -> Bool {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        guard needsPresentedContainerRefresh else { return false }
        needsPresentedContainerRefresh = false
        return true
    }

    private func apply(
        change: RemoteStore.FpEvent, to observer: NSFileProviderChangeObserver
    ) async throws -> NSFileProviderItemIdentifier? {
        if change.type == "metadata_rescan" {
            let items = await store.refreshPresentedShareMetadata()
            if !items.isEmpty {
                logger.notice("refreshing share metadata for \(items.count) presented item(s)")
                observer.didUpdate(items)
            }
            return nil
        }
        if change.type == "metadata_name" {
            let items = await store.refreshShareMetadata(named: change.from)
            if !items.isEmpty { observer.didUpdate(items) }
            return nil
        }
        let fromURI = store.uri(forEventPath: change.from)
        logger.notice(
            "applying \(change.type, privacy: .public) for \(fromURI, privacy: .public)"
        )
        switch change.type {
        case "create", "modify", "metadata":
            // Refresh metadata; a disappeared item becomes a delete.
            do {
                let file = try await store.client.fileInfoWithShareState(uri: fromURI)
                let item = store.makeItem(file)
                var refreshContent = false
                if containerIdentifier == .workingSet && change.type == "modify"
                    && !file.isFolder
                {
                    refreshContent = await store.prepareDownloadedContentForRemoteUpdate(
                        item.itemIdentifier)
                }
                logger.notice(
                    "refreshed \(fromURI, privacy: .public), shared: \(file.shared == true, privacy: .public)"
                )
                observer.didUpdate([item])
                return refreshContent ? item.itemIdentifier : nil
            } catch CloudreveError.noSuchItem {
                let identifier = store.identifier(forURI: fromURI)
                store.evictCachedItems(withIdentifiers: [identifier])
                observer.didDeleteItems(withIdentifiers: [identifier])
            }
        case "delete":
            let identifier = store.identifier(forURI: fromURI)
            logger.notice(
                "delivering remote delete for \(fromURI, privacy: .public) as \(identifier.rawValue, privacy: .public)"
            )
            store.recordRemoteDelete(for: fromURI)
            store.evictCachedItems(withIdentifiers: [identifier])
            observer.didDeleteItems(withIdentifiers: [identifier])
        case "rename":
            let identifier = store.identifier(forURI: fromURI)
            if let to = change.to {
                let toURI = store.uri(forEventPath: to)
                do {
                    let file = try await store.client.fileInfoWithShareState(uri: toURI)
                    observer.didUpdate([
                        store.makeItem(file, preservingIdentifier: identifier)
                    ])
                } catch CloudreveError.noSuchItem {
                    store.evictCachedItems(withIdentifiers: [identifier])
                    observer.didDeleteItems(withIdentifiers: [identifier])
                }
            }
        default:
            break
        }
        return nil
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        completionHandler(store.currentSyncAnchor())
    }

    static func mapError(_ error: Error) -> Error {
        switch error {
        case CloudreveError.noSuchItem:
            return NSFileProviderError(.noSuchItem)
        case CloudreveError.notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case CloudreveError.nameCollision:
            return NSFileProviderError(.filenameCollision)
        case CloudreveError.lockConflict(_, _, _):
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.Code.cannotSynchronize.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Someone has this file open online."
                ])
        case CloudreveError.staleVersion:
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.Code.cannotSynchronize.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The file changed on the server before this update was saved."
                ])
        default:
            // File Provider only accepts Cocoa and File Provider error
            // domains. Keep implementation errors inside the extension.
            return NSFileProviderError(.serverUnreachable)
        }
    }
}
