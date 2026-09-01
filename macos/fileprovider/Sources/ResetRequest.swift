import Foundation

enum ResetRequest {
    static func shouldApply(request: Data?, acknowledged: Data?) -> Bool {
        guard let request else { return false }
        return request != acknowledged
    }
}
