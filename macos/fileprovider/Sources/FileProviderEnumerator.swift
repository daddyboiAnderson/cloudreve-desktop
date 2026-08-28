import FileProvider
import OSLog

/// Enumerates a container (root or a folder) from the Cloudreve API.
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
        // The working set is what the system re-enumerates when we signal
        // after remote changes. Returning the root's live children plus every
        // item we've served this session lets the system diff against its
        // mirror and discover new/changed files.
        if containerIdentifier == .workingSet {
            Task {
                do {
                    let (rootItems, _) = try await store.children(of: .rootContainer, page: nil)
                    observer.didEnumerate(rootItems + store.cachedItems())
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

        // The trash container is system-managed and has no remote counterpart.
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
                let (changes, newAnchor) = try store.changes(
                    since: anchor.rawValue, for: containerIdentifier)
                for change in changes {
                    try await apply(change: change, to: observer)
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
            // Fetch fresh metadata; if the item vanished in the meantime
            // (rapid create+delete), report a deletion instead.
            do {
                let file = try await store.client.fileInfo(uri: fromURI)
                let item = store.makeItem(file)
                observer.didUpdate([item])
                // Items below a "Keep Downloaded" folder are materialized
                // explicitly: the system only auto-downloads eager-policy
                // items it already tracks, and this change may be the first
                // time it hears about the item (e.g. synthetic pin events or
                // uploads from the web UI/other devices).
                if item.effectivelyPinned && !item.contentType.conforms(to: .folder) {
                    store.requestDownloadWhenKnown(item.itemIdentifier)
                }
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
                    // A rename changes the filename/path, never the item's
                    // identity. Updating the same identifier lets Finder move
                    // the existing placeholder instead of creating a duplicate.
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
