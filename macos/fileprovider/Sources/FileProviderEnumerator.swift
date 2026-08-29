import FileProvider
import OSLog

/// Enumerates Cloudreve containers and replays remote changes.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.dev.fileprovider", category: "enumerator")

    private let containerIdentifier: NSFileProviderItemIdentifier
    private let store: RemoteStore

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
                // Force a full working-set refresh after a policy change.
                if containerIdentifier == .workingSet,
                    store.consumePolicyRescanIfNeeded()
                {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                let (changes, newAnchor) = try store.changes(
                    since: anchor.rawValue, for: containerIdentifier)
                for change in changes {
                    try await apply(change: change, to: observer)
                }
                // Deliver queued Keep Downloaded policy changes.
                if containerIdentifier == .workingSet {
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
                                let file = try await store.client.fileInfo(uri: uri)
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

    private func apply(
        change: RemoteStore.FpEvent, to observer: NSFileProviderChangeObserver
    ) async throws {
        let fromURI = store.uri(forEventPath: change.from)
        switch change.type {
        case "create", "modify":
            // Refresh metadata; a disappeared item becomes a delete.
            do {
                let file = try await store.client.fileInfo(uri: fromURI)
                observer.didUpdate([store.makeItem(file)])
            } catch CloudreveError.noSuchItem {
                observer.didDeleteItems(withIdentifiers: [
                    NSFileProviderItemIdentifier(fromURI)
                ])
            }
        case "delete":
            observer.didDeleteItems(withIdentifiers: [
                store.identifier(forURI: fromURI)
            ])
        case "rename":
            let identifier = store.identifier(forURI: fromURI)
            if let to = change.to {
                let toURI = store.uri(forEventPath: to)
                do {
                    let file = try await store.client.fileInfo(uri: toURI)
                    observer.didUpdate([
                        store.makeItem(file, preservingIdentifier: identifier)
                    ])
                } catch CloudreveError.noSuchItem {
                    observer.didDeleteItems(withIdentifiers: [identifier])
                }
            }
        default:
            break
        }
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
        default:
            return error
        }
    }
}
