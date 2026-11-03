#if DEBUG
import SwiftData
import Foundation

/// Local sample content for repeatable screenshots. No provider calls or sync.
@MainActor
enum ScreenshotPreview {
    static var screen: String? { ProcessInfo.processInfo.environment["WA_SCREENSHOT_SCREEN"] }
    static let conversationID = UUID(uuidString: "7A583116-2CA6-4C70-B088-950685821061")!

    static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: DataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try! ModelContainer(for: DataStore.schema, configurations: configuration)
        guard let endpoint = EndpointStore.shared.activeEndpoint else { return container }
        let context = container.mainContext
        let samples: [(UUID, String, String, String)] = [
            (conversationID, "A calmer morning", "Help me plan a focused morning with time for a break.", """
            Here’s a simple plan.

            **Focus:** Start with your most important task.

            **Reset:** Take a ten-minute walk.

            **Finish:** Wrap up smaller tasks and plan tomorrow.
            """),
            (UUID(), "Ideas for the weekend", "Suggest a few relaxing things to do this weekend.", "Try a walk somewhere new, cook a favorite meal, or make time for a book you’ve been meaning to read."),
            (UUID(), "Learning something new", "How can I build a daily learning habit?", "Start with fifteen minutes and one clear topic. Write down one thing you learned, then return to it tomorrow.")
        ]
        for (index, sample) in samples.enumerated() {
            let date = Date.now.addingTimeInterval(Double(-index * 3600))
            let conversation = Conversation(id: sample.0, title: sample.1, endpointID: endpoint.id,
                                            endpointName: endpoint.name, model: endpoint.model,
                                            createdAt: date, updatedAt: date)
            context.insert(conversation)
            context.insert(Message(role: .user, content: sample.2, createdAt: date, orderIndex: 0, conversation: conversation))
            context.insert(Message(role: .assistant, content: sample.3, createdAt: date, orderIndex: 1, conversation: conversation))
        }
        try! context.save()
        if ProcessInfo.processInfo.environment["WA_SCREENSHOT_DRAFT"] == "1" {
            let session = ChatSessionCoordinator.shared.session(for: conversationID)
            session.draft = "Keep this draft while I fold."
            session.searchEnabled = true
        }
        return container
    }
}
#endif
