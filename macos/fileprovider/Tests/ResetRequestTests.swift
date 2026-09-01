import Foundation

@main
enum ResetRequestTests {
    static func main() {
        let first = Data("reset-1".utf8)
        let second = Data("reset-2".utf8)

        precondition(!ResetRequest.shouldApply(request: nil, acknowledged: nil))
        precondition(ResetRequest.shouldApply(request: first, acknowledged: nil))
        precondition(!ResetRequest.shouldApply(request: first, acknowledged: first))
        precondition(ResetRequest.shouldApply(request: second, acknowledged: first))
        print("ResetRequestTests: all tests passed")
    }
}
