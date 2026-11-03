import CarPlay
import Combine
import SwiftData
import UIKit

/// CarPlay deliberately exposes voice state and controls only. Neither model output,
/// recognition text nor prompt-derived conversation titles belong on the car display.
@available(iOS 26.4, *)
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private let voice = VoiceConversationController.shared
    private let endpoints = EndpointStore.shared
    private var subscriptions = Set<AnyCancellable>()
    private weak var interfaceController: CPInterfaceController?
    private var voiceTemplate: CPVoiceControlTemplate?
    private var conversationID: UUID?
    private var templateIsVisible = false
    private var sceneIsActive = false
    private var renderRetryTask: Task<Void, Never>?
    private var renderRevision = UUID()

    private var context: ModelContext { DataStore.shared.mainContext }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        sceneIsActive = true
        voice.connectCarPlay()
        let template = makeVoiceTemplate()
        voiceTemplate = template
        subscribeToVoice()

        // Use a completion handler so unsupported entitlements/presentation failures
        // do not fall through to CarPlay's exception-throwing no-handler path.
        interfaceController.setRootTemplate(template, animated: false) { [weak self, weak interfaceController] success, _ in
            Task { @MainActor in
                guard let self, let interfaceController,
                      self.interfaceController === interfaceController else { return }
                self.templateIsVisible = success
                if success {
                    self.render()
                } else {
                    self.voice.stop(surface: .carPlay)
                }
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        disconnect()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        sceneIsActive = true
        render()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        sceneIsActive = false
        voice.stop(surface: .carPlay)
        render()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        sceneIsActive = false
        voice.stop(surface: .carPlay)
        render()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        disconnect()
    }

    private func disconnect() {
        guard interfaceController != nil || voiceTemplate != nil else { return }
        sceneIsActive = false
        templateIsVisible = false
        renderRetryTask?.cancel()
        renderRetryTask = nil
        renderRevision = UUID()
        subscriptions.removeAll()
        voice.disconnectCarPlay()
        voiceTemplate = nil
        interfaceController = nil
    }

    private func subscribeToVoice() {
        subscriptions.removeAll()
        voice.$state
            .combineLatest(voice.$conversationID, voice.$statusMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.render() }
            .store(in: &subscriptions)
        endpoints.$endpoints
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
    }

    private func makeVoiceTemplate() -> CPVoiceControlTemplate {
        let ready = state("ready", titles: ["Ready to talk", "Ready"], symbol: "mic.fill")
        let listening = state("listening", titles: ["Listening…"], symbol: "waveform")
        let thinking = state("thinking", titles: ["Thinking…"], symbol: "ellipsis.bubble.fill")
        let speaking = state("speaking", titles: ["Speaking…"], symbol: "speaker.wave.2.fill")
        let failed = state("error", titles: ["Voice unavailable"], symbol: "exclamationmark.circle")
        let template = CPVoiceControlTemplate(voiceControlStates: [ready, listening, thinking, speaking, failed])

        ready.actionButtons = [button("Speak", symbol: "mic.fill") { [weak self] in self?.beginTurn() },
                               button("Replay", symbol: "arrow.counterclockwise") { [weak self] in self?.replay() }]
        listening.actionButtons = [button("Send", symbol: "arrow.up") { [weak self] in self?.voice.finishListening() },
                                   button("Cancel", symbol: "xmark") { [weak self] in self?.voice.stop(surface: .carPlay) }]
        thinking.actionButtons = [button("Stop", symbol: "stop.fill") { [weak self] in self?.voice.stop(surface: .carPlay) }]
        speaking.actionButtons = [button("Stop", symbol: "stop.fill") { [weak self] in self?.voice.stop(surface: .carPlay) }]
        failed.actionButtons = [button("Try again", symbol: "mic.fill") { [weak self] in self?.beginTurn() },
                                button("Replay", symbol: "arrow.counterclockwise") { [weak self] in self?.replay() }]
        template.trailingNavigationBarButtons = [CPBarButton(title: "New chat") { [weak self] _ in
            self?.newConversation()
        }]
        return template
    }

    private func state(_ identifier: String, titles: [String], symbol: String) -> CPVoiceControlState {
        CPVoiceControlState(identifier: identifier, titleVariants: titles,
                            image: UIImage(systemName: symbol), repeats: false)
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> CPButton {
        let button = CPButton(image: UIImage(systemName: symbol) ?? UIImage()) { _ in action() }
        button.title = title
        return button
    }

    private func render() {
        renderRetryTask?.cancel()
        renderRetryTask = nil
        renderRevision = UUID()
        guard templateIsVisible, let template = voiceTemplate else { return }
        updateControls(in: template)
        let identifier = desiredStateIdentifier()
        if template.activeStateIdentifier != identifier {
            template.activateVoiceControlState(withIdentifier: identifier)
        }
        guard sceneIsActive, template.activeStateIdentifier != identifier else { return }

        // CarPlay can ignore a rapid transition. Retry only the latest desired state;
        // coalesce newer events and stop after a bounded four-second window.
        let revision = renderRevision
        renderRetryTask = Task { [weak self, weak template] in
            for _ in 0..<8 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, let template, self.renderRevision == revision,
                      self.templateIsVisible, self.sceneIsActive,
                      self.voiceTemplate === template else { return }
                self.updateControls(in: template)
                let latestIdentifier = self.desiredStateIdentifier()
                if template.activeStateIdentifier == latestIdentifier {
                    self.renderRetryTask = nil
                    return
                }
                template.activateVoiceControlState(withIdentifier: latestIdentifier)
            }
            guard let self, self.renderRevision == revision else { return }
            self.renderRetryTask = nil
        }
    }

    private func desiredStateIdentifier() -> String {
        // A phone-owned turn must never turn car controls into controls for that turn.
        guard voice.activeSurface == .carPlay else { return "ready" }
        switch voice.state {
        case .idle: return "ready"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .failed: return "error"
        }
    }

    private func updateControls(in template: CPVoiceControlTemplate) {
        for state in template.voiceControlStates {
            for button in state.actionButtons {
                button.isEnabled = sceneIsActive
                if button.title == "Replay" {
                    button.isEnabled = sceneIsActive && replayableConversation() != nil
                }
            }
        }
        template.trailingNavigationBarButtons.forEach { $0.isEnabled = sceneIsActive }
    }

    private func beginTurn() {
        guard sceneIsActive else { return }
        // No permission prompts or instructions to manipulate iPhone on the car display.
        guard VoiceInputController.permissionsGranted else {
            showCondition(title: "Voice access required", message: "Microphone and speech recognition permissions have not been granted.")
            return
        }
        let conversation = currentConversation()
        guard let endpoint = conversation.flatMap({ current in
            endpoints.endpoints.first { $0.id == current.endpointID }
        }) ?? (conversation == nil ? endpoints.activeEndpoint : nil),
              endpoint.baseURL != nil,
              !endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showCondition(title: "Connection unavailable", message: "A configured AI connection is required.")
            return
        }
        let target: Conversation
        if let conversation {
            target = conversation
        } else {
            target = Conversation(endpointID: endpoint.id, endpointName: endpoint.name,
                                  model: endpoint.model, systemPrompt: endpoint.systemPrompt)
            context.insert(target)
            do { try context.save() } catch {
                context.delete(target)
                showCondition(title: "Conversation unavailable", message: "The conversation could not be saved.")
                return
            }
            conversationID = target.id
        }
        voice.begin(conversation: target, context: context, endpoint: endpoint,
                    searchEnabled: endpoint.searchMode == .auto, surface: .carPlay)
    }

    private func replay() {
        guard sceneIsActive, let conversation = replayableConversation() else { return }
        voice.replay(conversation: conversation, surface: .carPlay)
    }

    private func newConversation() {
        guard sceneIsActive else { return }
        voice.stop(surface: .carPlay)
        // Starting a new conversation is lazy: connecting or tapping New chat never
        // fills history with empty rows. The next successful Speak action creates it.
        conversationID = nil
        render()
    }

    private func currentConversation() -> Conversation? {
        guard let id = conversationID else { return nil }
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conversation = try? context.fetch(descriptor).first else {
            conversationID = nil
            return nil
        }
        return conversation
    }

    private func replayableConversation() -> Conversation? {
        guard let conversation = currentConversation(),
              conversation.sortedMessages.contains(where: {
                  $0.role == .assistant && !$0.content.isEmpty &&
                  ($0.responseMetadata?.phase == .completed || $0.responseMetadata == nil)
              }) else { return nil }
        return conversation
    }

    private func showCondition(title: String, message: String) {
        guard let interfaceController else { return }
        let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: { _, _ in })
        }
        let alert = CPAlertTemplate(titleVariants: [message, title], actions: [dismiss])
        interfaceController.presentTemplate(alert, animated: true, completion: { _, _ in })
    }

    deinit {
        renderRetryTask?.cancel()
    }
}
