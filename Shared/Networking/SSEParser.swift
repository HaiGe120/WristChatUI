import Foundation

public struct SSEEvent: Sendable {
    public let event: String?
    public let data: String
    public let id: String?
}

public struct SSEParser {
    private var currentEvent: String?
    private var currentData: String = ""
    private var currentID: String?
    private var hasData: Bool = false

    public init() {}

    public mutating func feed(line rawLine: String) -> SSEEvent? {
        let line = rawLine
        // Empty line: standard SSE event terminator. Flush.
        if line.isEmpty {
            return flush()
        }
        // Comment line: skip.
        if line.hasPrefix(":") {
            return nil
        }
        if let colon = line.firstIndex(of: ":") {
            let field = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.first == " " { value.removeFirst() }
            switch field {
            case "event":
                // Some servers (e.g. the MiniMax Anthropic-compatible
                // endpoint seen in production) omit the empty-line
                // separator between events. When a new "event:" arrives
                // while we have accumulated data from the previous
                // event, flush the previous one first.
                if hasData {
                    let previous = SSEEvent(event: currentEvent, data: currentData, id: currentID)
                    currentEvent = value
                    currentData = ""
                    currentID = nil
                    hasData = false
                    return previous
                }
                currentEvent = value
            case "data":
                if hasData { currentData += "\n" }
                currentData += value
                hasData = true
            case "id":
                currentID = value
            default:
                break
            }
        }
        return nil
    }

    /// Flush the current accumulated event. Returns nil if nothing
    /// has been accumulated.
    public mutating func flush() -> SSEEvent? {
        defer {
            currentEvent = nil
            currentData = ""
            currentID = nil
            hasData = false
        }
        if !hasData && currentEvent == nil {
            return nil
        }
        return SSEEvent(event: currentEvent, data: currentData, id: currentID)
    }
}
