import SwiftUI

struct ResponseDetailsView: View {
    let metadata: ResponseMetadata
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = metadata.statusText {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle([.failed, .partial].contains(metadata.phase) ? Color.orange : Color.secondary)
            }
            if !metadata.citations.isEmpty {
                #if os(watchOS)
                NavigationLink("Sources (\(metadata.citations.count))") {
                    List { sourceRows }.navigationTitle("Sources")
                }
                .font(.caption2)
                #else
                DisclosureGroup("Sources (\(metadata.citations.count))") { sourceRows }
                    .font(.caption2)
                #endif
            }
        }
    }
    private var sourceRows: some View {
        ForEach(Array(metadata.citations.enumerated()), id: \.element.id) { index, source in
            if let url = source.safeURL {
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.title.isEmpty ? url.host ?? "Source" : source.title).font(.headline)
                            Text(source.url).font(.caption2).foregroundStyle(.secondary)
                            if let excerpt = source.excerpt { Text(excerpt).font(.caption) }
                            Link("Open source", destination: url)
                        }
                        .padding()
                    }
                    .navigationTitle("Source")
                } label: {
                    Text("[\(index + 1)] \(source.title.isEmpty ? url.host ?? "Source" : source.title)")
                        .font(.caption).lineLimit(3)
                }
            }
        }
    }
}
