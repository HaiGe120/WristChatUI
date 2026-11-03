import Foundation

public enum VoiceTextFormatting {
    public static let guidance = """
    This reply will be read aloud. Unless the user requests a particular format, answer in concise, natural spoken sentences in the user's language. Avoid long lists, tables, raw URLs and code unless necessary to answer the question. Keep source references in the written answer when relevant. Preserve the user's instructions and necessary detail.
    """
    public static let maximumSpokenCharacters = 6_000

    /// The original Markdown remains in history. This is only the speech presentation.
    public static func spokenText(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var fence: (marker: Character, count: Int)?
        var omittedCode = false
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let candidate = line.drop(while: { $0 == " " || $0 == "\t" })
            if let marker = candidate.first, marker == "`" || marker == "~" {
                let count = candidate.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if let current = fence {
                        if marker == current.marker, count >= current.count,
                           candidate.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                            fence = nil
                        }
                    } else {
                        fence = (marker, count)
                        omittedCode = true
                    }
                    continue
                }
            }
            if fence == nil { lines.append(line) }
        }
        var value = lines.joined(separator: "\n")
        // Drop reference definitions and image descriptions, retain visible link labels.
        value = replacing(value, #"(?m)^\s*\[[^\]\n]+\]:\s*\S+.*$"#, with: "")
        value = replacing(value, #"!\[[^\]]*\]\([^\n]*?\)"#, with: "")
        value = replacing(value, #"\[\[\d+\]\]\([^\n]*?\)"#, with: "")
        value = replacing(value, #"\[([^\]\n]+)\]\((?:[^()\n]|\([^()\n]*\))*\)"#, with: "$1")
        value = replacing(value, #"\[\[\d+\]\]|\[\d+\]|【[^】]*】"#, with: "")
        value = replacing(value, #"(?i)<?(?:https?://|www\.)[^\s<>]+>?"#, with: "")
        value = replacing(value, #"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "")
        value = replacing(value, #"(?m)^\s*(?:[-_*]\s*){3,}$"#, with: "")
        value = replacing(value, #"(?m)^\s*\|?\s*:?-{3,}.*$"#, with: "")
        value = value.replacingOccurrences(of: "|", with: ", ")
        value = replacing(value, #"[*_`~]"#, with: "")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        value = replacing(value, #"[ \t]+"#, with: " ")
        value = replacing(value, #"\n\s*\n+"#, with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if omittedCode {
            value += (value.isEmpty ? "" : "\n") + "Code is available in the written reply."
        }
        if value.count > maximumSpokenCharacters {
            let bounded = String(value.prefix(maximumSpokenCharacters))
            let ending = bounded.lastIndex(where: { ".!?。！？\n".contains($0) })
            let spoken = ending.flatMap { bounded.distance(from: bounded.startIndex, to: $0) >= maximumSpokenCharacters / 2 ? String(bounded[...$0]) : nil }
                ?? bounded
            value = spoken + "\nThe rest of the reply is available in the conversation."
        }
        return value
    }

    public static func applying(toSystemPrompt prompt: String) -> String {
        guard !prompt.contains(guidance) else { return prompt }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? guidance : prompt + "\n\n" + guidance
    }

    private static func replacing(_ value: String, _ pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }
}
