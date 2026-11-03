import SwiftUI

struct ResponseDetailsView: View {
    let metadata: ResponseMetadata
    let content: String

    var body: some View {
        let sources = groupedSources
        return VStack(alignment: .leading, spacing: 4) {
            if let status = metadata.statusText {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle([.failed, .partial].contains(metadata.phase) ? Color.orange : Color.secondary)
            }
            if !sources.isEmpty {
                NavigationLink {
                    SourceListView(sources: sources, title: incompleteAnswer ? "References" : "Sources")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(referenceLabel(count: sources.count))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(incompleteAnswer ? "References returned" : "Sources"), \(sources.count) unique links")
                .accessibilityHint("Opens a separate list of sources")
                if incompleteAnswer {
                    Text("References were returned, but the answer did not finish.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var incompleteAnswer: Bool { metadata.phase == .partial || metadata.phase == .failed }

    private func referenceLabel(count: Int) -> String {
        "\(incompleteAnswer ? "References returned" : "Sources") (\(count))"
    }

    /// Group only the presentation. The stored citations and their offsets remain untouched,
    /// and each group retains every original number used by links inside the answer.
    private var groupedSources: [SourceGroup] {
        var groups: [SourceGroup] = []
        var positions: [String: Int] = [:]
        for (index, citation) in metadata.citations.enumerated() {
            guard let url = citation.safeURL else { continue }
            let key = url.absoluteString
            let title = citation.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = citation.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let position = positions[key] {
                groups[position].referenceNumbers.append(index + 1)
                if groups[position].title.isEmpty { groups[position].title = title }
                if groups[position].excerpt?.isEmpty != false { groups[position].excerpt = excerpt }
            } else {
                positions[key] = groups.count
                groups.append(SourceGroup(url: url, title: title, excerpt: excerpt, referenceNumbers: [index + 1]))
            }
        }
        return groups
    }
}

private struct SourceGroup: Identifiable {
    let url: URL
    var title: String
    var excerpt: String?
    var referenceNumbers: [Int]

    var id: String { url.absoluteString }
    var domain: String { url.host ?? "Source" }
    var displayTitle: String {
        // Some providers put the URL in their title field. Keep full URLs in the
        // detail screen even for those results, so the list stays easy to scan.
        let lowercased = title.lowercased()
        return title.isEmpty || lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://") ? domain : title
    }
    var allReferences: String { referenceNumbers.map { "[\($0)]" }.joined(separator: ", ") }
    var referenceSummary: String {
        let firstNumbers = referenceNumbers.prefix(3).map { "[\($0)]" }.joined(separator: ", ")
        return referenceNumbers.count > 3 ? firstNumbers + " + \(referenceNumbers.count - 3) more" : firstNumbers
    }
}

private struct SourceListView: View {
    let sources: [SourceGroup]
    let title: String

    var body: some View {
        List(sources) { source in
            NavigationLink {
                SourceDetailView(source: source)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    Text(source.domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(source.referenceSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(source.displayTitle). \(source.domain). References \(source.allReferences)")
            .accessibilityHint("Shows source details and a link to open the page")
        }
        .listStyle(.plain)
        .navigationTitle(title)
    }
}

private struct SourceDetailView: View {
    let source: SourceGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(source.displayTitle)
                    .font(.headline)
                Text("References \(source.allReferences)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(source.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let excerpt = source.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.body)
                }
                Link("Open source", destination: source.url)
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Source")
    }
}
