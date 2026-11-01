import SwiftUI

struct MarkdownText: View {
    let raw: String
    var enablesSelection: Bool = false

    var body: some View {
        rendered
    }

    @ViewBuilder
    private var rendered: some View {
        if raw.isEmpty {
            Text("...")
        } else {
            selectable(Text(MessageTextFormatting.attributed(raw)))
        }
    }

    @ViewBuilder
    private func selectable(_ text: Text) -> some View {
        if enablesSelection {
            #if os(iOS)
            text.textSelection(.enabled)
            #else
            text
            #endif
        } else {
            text
        }
    }
}
