import Foundation

/// SwiftUI Text does not lay out Markdown block presentation intents. Parse inline styling
/// while retaining the model's actual line/paragraph boundaries, and handle fenced code
/// separately so Markdown cannot rewrite its whitespace or literal punctuation.
public enum MessageTextFormatting {
    public static func attributed(_ raw: String) -> AttributedString {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result = AttributedString()
        var text = ""
        var code = ""
        var fence: Fence?

        func styled(_ value: String) -> AttributedString {
            (try? AttributedString(markdown: value, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            ))) ?? AttributedString(value)
        }
        func literalCode(_ value: String) -> AttributedString {
            var attributed = AttributedString(value)
            attributed.inlinePresentationIntent = .code
            return attributed
        }

        for (index, line) in lines.enumerated() {
            let terminated = index < lines.count - 1
            let value = line + (terminated ? "\n" : "")
            if let current = fence {
                if current.closes(line) {
                    result.append(literalCode(code))
                    if code.isEmpty, terminated { result.append(AttributedString("\n")) }
                    code = ""
                    fence = nil
                } else { code += value }
            } else if let opening = Fence.opening(line) {
                result.append(styled(text))
                text = ""
                fence = opening
            } else { text += value }
        }
        if fence != nil { result.append(literalCode(code)) }
        result.append(styled(text))
        return result
    }

    private struct Fence {
        let marker: Character
        let count: Int

        static func opening(_ line: String) -> Fence? {
            guard let value = unindented(line), let marker = value.first,
                  marker == "`" || marker == "~" else { return nil }
            let count = value.prefix(while: { $0 == marker }).count
            guard count >= 3 else { return nil }
            // A backtick in the info string means this is ordinary text, not a fence.
            if marker == "`", value.dropFirst(count).contains("`") { return nil }
            return Fence(marker: marker, count: count)
        }
        func closes(_ line: String) -> Bool {
            guard let value = Self.unindented(line) else { return false }
            let length = value.prefix(while: { $0 == marker }).count
            return length >= count && value.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty
        }
        static func unindented(_ line: String) -> Substring? {
            let spaces = line.prefix(while: { $0 == " " }).count
            guard spaces <= 3 else { return nil }
            return line.dropFirst(spaces)
        }
    }
}

/// Applied only to outgoing Watch requests, after resolving the conversation's own prompt.
/// This is display guidance, not a limit on answer length or a change to saved preferences.
public enum WatchResponseFormatting {
    public static let guidance = """
    When no specific output format is required, format replies for a small Apple Watch display: use short paragraphs separated by a blank line, and put each bullet or numbered item on its own line. Prefer a short list over a wide table. Preserve necessary detail, exact code, source links, and the user's requested language and format.
    """

    public static func applying(toSystemPrompt prompt: String) -> String {
        guard !prompt.contains(guidance) else { return prompt }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? guidance : prompt + "\n\n" + guidance
    }
}
