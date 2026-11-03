import Foundation
import Combine
import SwiftData
import UIKit

enum VoiceSurface { case phone, carPlay }
enum VoiceConversationState { case idle, listening, thinking, speaking, failed }

/// One owner for microphone, request, and speech on iPhone, shared with its CarPlay scene.
@MainActor
final class VoiceConversationController: ObservableObject {
    static let shared = VoiceConversationController()
    @Published private(set) var state: VoiceConversationState = .idle
    @Published private(set) var statusMessage: String?
    @Published private(set) var conversationID: UUID?
    @Published private(set) var activeSurface: VoiceSurface?
    @Published private(set) var isCarPlayConnected = false
    @Published private(set) var transcript = ""

    private let input = VoiceInputController()
    private lazy var playback = SpeechPlaybackController.shared
    private var turnID: UUID?
    private var endpointID: UUID?
    private var captureTask: Task<Void, Never>?
    private var requestSession: ChatSession?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundToken: UUID?
    private var observers: Set<AnyCancellable> = []

    private init() {
        input.$transcript.sink { [weak self] text in self?.transcript = text }.store(in: &observers)
        input.$isFinalizing.sink { [weak self] isFinalizing in
            guard let self, isFinalizing, self.turnID != nil, self.state == .listening else { return }
            self.state = .thinking
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: ChatSessionCoordinator.willRemoveConversation)
            .sink { [weak self] notification in
                guard let self, notification.object as? UUID == self.conversationID else { return }
                self.stop()
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: EndpointStore.willChange)
            .sink { [weak self] notification in
                guard let self, self.turnID != nil else { return }
                if notification.object == nil || notification.object as? UUID == self.endpointID {
                    self.stop()
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: SearchSourceStore.didChange)
            .sink { [weak self] _ in self?.stop() }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self, self.activeSurface == .phone, self.state == .listening else { return }
                self.stop(surface: .phone)
            }.store(in: &observers)
    }

    func connectCarPlay() {
        stop(surface: .phone)
        isCarPlayConnected = true
    }

    func disconnectCarPlay() {
        stop(surface: .carPlay)
        isCarPlayConnected = false
    }

    func begin(conversation: Conversation, context: ModelContext, endpoint: EndpointConfig,
               searchEnabled: Bool, surface: VoiceSurface) {
        guard surface == .carPlay ? isCarPlayConnected : !isCarPlayConnected else { return }
        let session = ChatSessionCoordinator.shared.session(for: conversation.id)
        guard !session.isStreaming else { return }
        stop()
        conversationID = conversation.id
        activeSurface = surface
        endpointID = endpoint.id
        guard endpoint.baseURL != nil, !endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("Connection unavailable")
            return
        }
        guard surface != .carPlay || VoiceInputController.permissionsGranted else {
            fail("Voice access required")
            return
        }
        let id = UUID()
        turnID = id
        transcript = ""
        statusMessage = nil
        state = .listening
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.input.start(languageIdentifier: VoicePreferences.shared.resolvedLanguageIdentifier,
                                   requestPermissions: surface == .phone,
                                   onFinal: { [weak self] text in
                guard let self, self.turnID == id else { return }
                self.submit(text, id: id, conversation: conversation, context: context,
                            endpoint: endpoint, searchEnabled: searchEnabled)
            }, onError: { [weak self] message in
                guard let self, self.turnID == id else { return }
                self.fail(surface == .phone ? message : (VoiceInputController.permissionsGranted ? "Voice unavailable" : "Voice access required"))
            })
        }
    }

    func finishListening() {
        guard state == .listening else { return }
        if input.isFinalizing {
            state = .thinking
        } else if input.isListening {
            state = .thinking
            input.finish()
        } else {
            stop()
        }
    }

    func stop(surface: VoiceSurface) {
        guard activeSurface == surface else { return }
        stop()
    }

    func stop() {
        // Invalidate callbacks before canceling. Both request and speech completion can run synchronously.
        let previousID = turnID
        turnID = nil
        captureTask?.cancel()
        captureTask = nil
        input.cancel()
        if let previousID { playback.stop(ownerID: previousID) }
        let session = requestSession
        requestSession = nil
        session?.cancel()
        endBackgroundTask()
        state = .idle
        statusMessage = nil
        conversationID = nil
        endpointID = nil
        activeSurface = nil
        transcript = ""
    }

    func replay(conversation: Conversation, surface: VoiceSurface) {
        guard !ChatSessionCoordinator.shared.session(for: conversation.id).isStreaming,
              let reply = conversation.sortedMessages.last(where: {
                  $0.role == .assistant && !$0.content.isEmpty && ($0.responseMetadata?.phase == .completed || $0.responseMetadata == nil)
              }) else { return }
        speakReply(reply.content, conversationID: conversation.id, surface: surface)
    }

    func speakReply(_ text: String, conversationID: UUID, surface: VoiceSurface) {
        guard surface == .carPlay ? isCarPlayConnected : !isCarPlayConnected else { return }
        guard surface == .carPlay || UIApplication.shared.applicationState == .active else { return }
        stop()
        self.conversationID = conversationID
        activeSurface = surface
        let id = UUID()
        turnID = id
        speak(text, id: id)
    }

    private func submit(_ text: String, id: UUID, conversation: Conversation, context: ModelContext,
                        endpoint: EndpointConfig, searchEnabled: Bool) {
        guard turnID == id, conversation.endpointID == endpoint.id,
              EndpointStore.shared.endpoints.contains(endpoint) else {
            fail("Connection settings changed")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { fail("No speech detected"); return }
        let session = ChatSessionCoordinator.shared.session(for: conversation.id)
        state = .thinking
        beginBackgroundTask()
        let sent = session.send(conversation: conversation, context: context, endpoint: endpoint,
                                apiKey: EndpointStore.shared.apiKey(for: endpoint.id), text: trimmed,
                                searchEnabled: searchEnabled,
                                additionalSystemPrompt: VoiceTextFormatting.applying(toSystemPrompt: "")) { [weak self] text, metadata in
            guard let self, self.turnID == id else { return }
            self.requestSession = nil
            self.endBackgroundTask()
            if metadata.phase == .completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if self.activeSurface == .carPlay || VoicePreferences.shared.automaticallySpeakReplies {
                    self.speak(text, id: id)
                } else {
                    self.turnID = nil
                    self.activeSurface = nil
                    self.state = .idle
                }
            } else if metadata.phase == .cancelled {
                self.stop()
            } else {
                self.fail(self.activeSurface == .phone ? (metadata.errorMessage ?? "Reply unavailable. Try again.") : "Reply unavailable. Try again.", announce: true)
            }
        }
        if sent { requestSession = session }
        else { fail("Conversation is busy") }
    }

    private func speak(_ text: String, id: UUID) {
        guard turnID == id else { return }
        state = .speaking
        playback.speak(text, ownerID: id) { [weak self] in
            guard let self, self.turnID == id else { return }
            if self.playback.lastError != nil {
                self.fail("Audio unavailable")
            } else {
                self.turnID = nil
                self.activeSurface = nil
                self.state = .idle
            }
        }
    }

    private func fail(_ message: String, announce: Bool = false) {
        let surface = activeSurface
        let conversation = conversationID
        stop()
        activeSurface = surface
        conversationID = conversation
        statusMessage = message
        state = .failed
        if announce, surface == .carPlay {
            let id = UUID()
            turnID = id
            playback.speak(message, ownerID: id) { [weak self] in
                guard let self, self.turnID == id else { return }
                self.turnID = nil
            }
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        let token = UUID()
        backgroundToken = token
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Voice reply") { [weak self] in
            Task { @MainActor in
                guard let self, self.backgroundToken == token else { return }
                self.fail("Request interrupted", announce: true)
            }
        }
    }

    private func endBackgroundTask() {
        backgroundToken = nil
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
