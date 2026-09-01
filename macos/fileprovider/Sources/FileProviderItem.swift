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
    /// Whether the item has an active Cloudreve share.
    let sharedState: Bool
    /// Whether the current Cloudreve account owns the share.
    let sharedByCurrentUserState: Bool
    /// Unmarked metadata version used when rebuilding the item.
    let baseMetadataVersion: Data

    /// Forces File Provider to notice a policy-only metadata change.
    private static let pinnedVersionMarker = Data("#kd".utf8)
    private static let sharedVersionMarker = Data("#shared".utf8)
    private static let sharedByCurrentUserVersionMarker = Data("#shared-owner".utf8)
    static let keepDownloadedDecoration =
        NSFileProviderItemDecorationIdentifier(
            "cloudreve.desktop.dev.fileprovider.keep-downloaded-v2")
    static let sharedDecoration =
        NSFileProviderItemDecorationIdentifier(
            "cloudreve.desktop.dev.fileprovider.shared-v1")

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
        effectivelyPinned: Bool? = nil,
        sharedState: Bool = false,
        sharedByCurrentUserState: Bool = false
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
        self.sharedState = sharedState
        self.sharedByCurrentUserState = sharedByCurrentUserState
        // macOS 13+ uses contentPolicy for eviction behavior.
        self.capabilities = capabilities
        self.baseMetadataVersion = metadataVersion
        var effectiveMetadataVersion = metadataVersion
        if self.effectivelyPinned {
            effectiveMetadataVersion += Self.pinnedVersionMarker
        }
        if self.sharedState {
            effectiveMetadataVersion += Self.sharedVersionMarker
        }
        if self.sharedByCurrentUserState {
            effectiveMetadataVersion += Self.sharedByCurrentUserVersionMarker
        }
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

    var isShared: Bool { sharedState }

    var isSharedByCurrentUser: Bool { sharedByCurrentUserState }

    /// Activation-rule values for the custom actions.
    var userInfo: [AnyHashable: Any]? {
        [
            "displayKeepDownloaded": NSNumber(value: !pinned),
            "displayRemoveKeepDownloaded": NSNumber(value: pinned),
            "displayShare": NSNumber(value: itemIdentifier != .rootContainer),
        ]
    }

    /// Finder decorations for Keep Downloaded and sharing state.
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        var result: [NSFileProviderItemDecorationIdentifier] = []
        if effectivelyPinned {
            result.append(Self.keepDownloadedDecoration)
        }
        if sharedState {
            result.append(Self.sharedDecoration)
        }
        return result.isEmpty ? nil : result
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
            effectivelyPinned: effectivelyPinned ?? pinned,
            sharedState: sharedState,
            sharedByCurrentUserState: sharedByCurrentUserState
        )
    }
}
