import SwiftUI

struct MessageBubble: View {
    @Bindable var message: Message
    /// Live streaming buffer that overrides `message.content` while the
    /// parent view is producing deltas. When non-nil and non-empty, the
    /// bubble displays this string instead of the persisted content.
    /// After the stream finishes, the parent clears the buffer (see the
    /// `onComplete` handler in `ChatView.send`) and the bubble falls
    /// back to `message.content`, which holds the final reply or an
    /// error marker.
    ///
    /// Without this override the visible text comes straight from the
    /// SwiftData model. Mutating that property from the streaming
    /// closure can lag SwiftData's per-property observation, leaving
    /// the bubble stuck on the "…" placeholder. Reading the @State
    /// buffer instead guarantees a redraw for every delta.
    let streamingOverride: String?

    private var isUser: Bool { message.role == .user }

    #if os(iOS)
    private var assistantBackground: Color { Color(.secondarySystemBackground) }
    #else
    private var assistantBackground: Color { Color.gray.opacity(0.25) }
    #endif

    /// Text to render, preferring the live buffer when present.
    private var displayContent: String {
        if let streamingOverride, !streamingOverride.isEmpty {
            return streamingOverride
        }
        return message.content
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !displayContent.isEmpty || message.responseMetadata?.phase.isActive != false {
                    MarkdownText(raw: CitedAnswer.markdown(displayContent, citations: message.responseMetadata?.citations ?? [], restrictLinksToSources: message.responseMetadata?.searchSource != nil), enablesSelection: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isUser ? Color.accentColor : assistantBackground)
                        .foregroundStyle(isUser ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let metadata = message.responseMetadata {
                    ResponseDetailsView(metadata: metadata, content: displayContent)
                }
                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
