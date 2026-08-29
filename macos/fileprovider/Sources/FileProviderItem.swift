import FileProvider
import UniformTypeIdentifiers

/// File Provider item backed by Cloudreve metadata.
final class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let childItemCount: NSNumber?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let creationDate: Date?
    let contentModificationDate: Date?
    /// Explicit "Keep Downloaded" state.
    let pinned: Bool
    /// Effective state, including inheritance from a pinned folder.
    let effectivelyPinned: Bool
    /// Unmarked metadata version used when rebuilding the item.
    let baseMetadataVersion: Data

    /// Forces File Provider to notice a policy-only metadata change.
    private static let pinnedVersionMarker = Data("#kd".utf8)
    static let keepDownloadedDecoration =
        NSFileProviderItemDecorationIdentifier(
            "cloudreve.desktop.dev.fileprovider.keep-downloaded-v2")

    init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        documentSize: Int?,
        childItemCount: Int?,
        capabilities: NSFileProviderItemCapabilities,
        contentVersion: Data,
        metadataVersion: Data,
        creationDate: Date?,
        contentModificationDate: Date?,
        pinned: Bool,
        effectivelyPinned: Bool? = nil
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.childItemCount = childItemCount.map { NSNumber(value: $0) }
        self.pinned = pinned
        let resolvedEffectivelyPinned = effectivelyPinned ?? pinned
        self.effectivelyPinned = resolvedEffectivelyPinned
        // Eviction requires the capability; pinned items must not advertise it.
        if identifier == .rootContainer {
            self.capabilities = capabilities
        } else if resolvedEffectivelyPinned {
            self.capabilities = capabilities.subtracting(.allowsEvicting)
        } else {
            self.capabilities = capabilities.union(.allowsEvicting)
        }
        self.baseMetadataVersion = metadataVersion
        let effectiveMetadataVersion =
            self.effectivelyPinned
            ? metadataVersion + Self.pinnedVersionMarker
            : metadataVersion
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: contentVersion,
            metadataVersion: effectiveMetadataVersion)
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        super.init()
    }

    /// Download and eviction policy shown to File Provider.
    var contentPolicy: NSFileProviderContentPolicy {
        effectivelyPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
    }

    /// Activation-rule values for the custom actions.
    var userInfo: [AnyHashable: Any]? {
        [
            "displayKeepDownloaded": NSNumber(value: !pinned),
            "displayRemoveKeepDownloaded": NSNumber(value: pinned),
        ]
    }

    /// Finder badge for effective Keep Downloaded state.
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        effectivelyPinned ? [Self.keepDownloadedDecoration] : nil
    }

    /// Copy with updated explicit and effective pin state.
    func withPinned(_ pinned: Bool, effectivelyPinned: Bool? = nil) -> FileProviderItem {
        FileProviderItem(
            identifier: itemIdentifier,
            parentIdentifier: parentItemIdentifier,
            filename: filename,
            contentType: contentType,
            documentSize: documentSize?.intValue,
            childItemCount: childItemCount?.intValue,
            capabilities: capabilities,
            contentVersion: itemVersion.contentVersion,
            metadataVersion: baseMetadataVersion,
            creationDate: creationDate,
            contentModificationDate: contentModificationDate,
            pinned: pinned,
            effectivelyPinned: effectivelyPinned ?? pinned
        )
    }
}
