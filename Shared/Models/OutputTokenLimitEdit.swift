import Foundation

/// Empty means the connection's existing default behavior. Invalid text must never
/// silently become a default or a truncated number when an endpoint is saved.
public struct OutputTokenLimitEdit: Equatable, Sendable {
    public let value: Int?
    public let isValid: Bool

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            value = nil
            isValid = true
        } else if trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(trimmed), number > 0 {
            value = number
            isValid = true
        } else {
            value = nil
            isValid = false
        }
    }
}
