import Foundation

extension String {
    func leftPadding(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
