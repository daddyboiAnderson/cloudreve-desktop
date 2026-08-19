import FileProvider
import UniformTypeIdentifiers

/// NSFileProviderItem backed by remote Cloudreve metadata.
final class FileProviderItem: NSObject, NSFileProviderItem {
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
        contentModificationDate: Date?
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.childItemCount = childItemCount.map { NSNumber(value: $0) }
        self.capabilities = capabilities
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: contentVersion,
            metadataVersion: metadataVersion)
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        super.init()
    }
}
