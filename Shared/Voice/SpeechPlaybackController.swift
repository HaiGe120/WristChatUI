import Foundation
import Combine
import AVFoundation

/// One playback owner in each process; never observes or reads incoming synced messages.
@MainActor
public final class SpeechPlaybackController: NSObject, ObservableObject {
    public static let shared = SpeechPlaybackController()

    @Published public private(set) var isSpeaking = false
    @Published public private(set) var lastError: String?
    public private(set) var ownerID: UUID?

    // Speech services may be expensive to connect to. Merely opening chat/settings must
    // not initialize the native synthesizer or activate an audio session.
    private var synthesizer: AVSpeechSynthesizer?
    private var currentUtterance: AVSpeechUtterance?
    private var finishCallback: (() -> Void)?
    private var notifications: [NSObjectProtocol] = []
    #if os(iOS) || os(watchOS)
    private var audioSessionActive = false
    #endif

    public override init() {
        super.init()
        #if os(iOS) || os(watchOS)
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            // NotificationCenter delivers this observer on the main queue. Handle it now:
            // an unstructured task could run after a new utterance has already replaced this one.
            MainActor.assumeIsolated { self?.interrupt("Speech interrupted. Tap Replay to listen again.") }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.interrupt("Audio device disconnected. Tap Replay to listen again.") }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interrupt("Audio became unavailable. Tap Replay to try again.", discardSynthesizer: true)
            }
        })
        #endif
    }

    deinit {
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }

    public func speak(_ text: String, ownerID: UUID, onFinish: (() -> Void)? = nil) {
        stop()
        lastError = nil
        let spoken = VoiceTextFormatting.spokenText(text)
        guard !spoken.isEmpty else {
            lastError = "There is no spoken text in this reply."
            onFinish?()
            return
        }
        let preferences = VoicePreferences.shared
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: preferences.resolvedLanguageIdentifier)
        utterance.rate = Float(preferences.speechRate)
        self.ownerID = ownerID
        currentUtterance = utterance
        finishCallback = onFinish
        let synthesizer = nativeSynthesizer()
        do {
            #if os(iOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            #if os(watchOS)
            try session.setCategory(.playback, mode: .default, options: [])
            #else
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            #endif
            try session.setActive(true)
            audioSessionActive = true
            #endif
            isSpeaking = true
            synthesizer.speak(utterance)
        } catch {
            lastError = "Unable to play speech. Check your audio output and try again."
            finish(utterance)
        }
    }

    /// Passing an owner prevents a disappearing screen from stopping another surface's speech.
    /// Explicit cancellation deliberately suppresses the old completion callback.
    public func stop(ownerID: UUID? = nil) {
        if let ownerID, ownerID != self.ownerID { return }
        currentUtterance = nil
        finishCallback = nil
        self.ownerID = nil
        isSpeaking = false
        synthesizer?.stopSpeaking(at: .immediate)
        deactivateAudio()
    }

    private func nativeSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        #if os(iOS) || os(watchOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
        self.synthesizer = synthesizer
        return synthesizer
    }

    private func interrupt(_ message: String, discardSynthesizer: Bool = false) {
        guard currentUtterance != nil else {
            if discardSynthesizer { discardNativeSynthesizer() }
            return
        }
        lastError = message
        // Fence delegate callbacks before stopping the native queue.
        let callback = finishCallback
        stop()
        if discardSynthesizer { discardNativeSynthesizer() }
        lastError = message
        callback?()
    }

    private func discardNativeSynthesizer() {
        synthesizer?.delegate = nil
        synthesizer = nil
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        currentUtterance = nil
        let callback = finishCallback
        finishCallback = nil
        ownerID = nil
        isSpeaking = false
        deactivateAudio()
        callback?()
    }

    private func deactivateAudio() {
        #if os(iOS) || os(watchOS)
        guard audioSessionActive else { return }
        audioSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}

extension SpeechPlaybackController: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }
}
