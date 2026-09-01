import Foundation

enum ItemIdentity {
    static func remoteID(_ fileID: String, fallbackURI: String) -> String {
        fileID.isEmpty ? fallbackURI : "cloudreve-item:/\(fileID)"
    }
}
