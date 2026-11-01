import Foundation

/// Adds only links grounded in returned source metadata. Existing Markdown stays readable.
public enum CitedAnswer {
    public static func markdown(_ text: String, citations: [SourceCitation], restrictLinksToSources: Bool = false) -> String {
        // Provider offsets refer to the unrendered answer. Insert from right to left.
        var output = text
        var inserts: [(Int, String)] = []
        for (index, source) in citations.enumerated() {
            guard let url = source.safeURL else { continue }
            let marker = " [[\(index + 1)]](\(url.absoluteString.replacingOccurrences(of: ")", with: "%29")))"
            if let end = source.endIndex, end >= 0, end <= text.utf16.count,
               let position = String.Index(utf16Offset: end, in: text).samePosition(in: text) {
                inserts.append((text.distance(from: text.startIndex, to: position), marker))
            }
        }
        for (offset, marker) in inserts.sorted(by: { $0.0 > $1.0 }) {
            let index = output.index(output.startIndex, offsetBy: offset)
            output.insert(contentsOf: marker, at: index)
        }
        if restrictLinksToSources { output = verifiedLinks(output, citations: citations) }
        return output
    }
    private static func verifiedLinks(_ text: String, citations: [SourceCitation]) -> String {
        let known = Set(citations.compactMap { $0.safeURL?.absoluteString })
        guard let regex = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\((https?://[^\s\)]+)\)"#) else { return text }
        let nsText = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
            let url = nsText.substring(with: match.range(at: 2)).replacingOccurrences(of: "%29", with: ")")
            if !known.contains(url), let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: nsText.substring(with: match.range(at: 1)))
            }
        }
        return result
    }
}
