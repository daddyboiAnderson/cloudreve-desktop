import Foundation

@main
enum ItemIdentityTests {
    static func main() {
        let original = ItemIdentity.remoteID("folder-1", fallbackURI: "cloudreve://my/untitled folder")
        let renamed = ItemIdentity.remoteID("folder-1", fallbackURI: "cloudreve://my/test af ting")
        let reused = ItemIdentity.remoteID("folder-2", fallbackURI: "cloudreve://my/untitled folder")

        precondition(original == renamed)
        precondition(reused != renamed)
        print("ItemIdentityTests: all tests passed")
    }
}
