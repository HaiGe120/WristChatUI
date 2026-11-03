import AVFoundation
import Combine
import Foundation
import Speech

/// Captures one bounded voice turn. Audio is streamed to Apple's recognizer and is never saved.
/// Every permission, recognition and timer callback belongs to a single capture identifier.
@MainActor
final class VoiceInputController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var hasPendingCapture = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastError: String?

    nonisolated static var permissionsGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized &&
            AVAudioApplication.shared.recordPermission == .granted
    }

    private var captureID: UUID?
    private var audioEngine: AVAudioEngine?
    private var tappedInput: AVAudioInputNode?
    private var tapInstalled = false
    private var ownsAudioSession = false
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var endedRecognitionAudio = false
    private var captureMonitor: Task<Void, Never>?
    private var finalizationDeadline: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var beganAt = Date.distantPast
    private var lastTranscriptChange = Date.distantPast
    private var finalHandler: ((String) -> Void)?
    private var errorHandler: ((String) -> Void)?

    /// Used during setup on iPhone. CarPlay always starts with `requestPermissions: false`.
    func requestPermissions() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard await Self.authorizeSpeech(), !Task.isCancelled else { return false }
        let microphoneAllowed = await Self.authorizeMicrophone()
        return microphoneAllowed && !Task.isCancelled
    }

    func start(languageIdentifier: String, requestPermissions: Bool = true,
               onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) async {
        guard !Task.isCancelled else { return }
        cancel()
        let id = UUID()
        captureID = id
        hasPendingCapture = true
        finalHandler = onFinal
        errorHandler = onError

        if requestPermissions {
            let speechAllowed = await Self.authorizeSpeech()
            guard captureID == id else { return }
            guard !Task.isCancelled else { cancel(); return }
            guard speechAllowed else {
                fail("Allow Speech Recognition in iPhone Settings to use voice.", id: id)
                return
            }
            let microphoneAllowed = await Self.authorizeMicrophone()
            guard captureID == id else { return }
            guard !Task.isCancelled else { cancel(); return }
            guard microphoneAllowed else {
                fail("Allow Microphone access in iPhone Settings to use voice.", id: id)
                return
            }
        } else if !Self.permissionsGranted {
            fail("Set up microphone and speech access on iPhone first.", id: id)
            return
        }

        guard captureID == id else { return }
        guard !Task.isCancelled else { cancel(); return }
        guard let locale = Self.supportedLocale(for: languageIdentifier),
              let recognizer = SFSpeechRecognizer(locale: locale) else {
            fail("Speech recognition is unavailable for this language. Choose another voice language on iPhone.", id: id)
            return
        }
        guard recognizer.isAvailable else {
            fail("Speech recognition is unavailable. Check your connection and try again.", id: id)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // Measurement mode suits transcription. HFP allows car/headset microphones without
            // forcing the built-in speaker or replacing an existing CarPlay route.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            ownsAudioSession = true
            guard session.isInputAvailable else {
                fail("No microphone is available. Check your audio connection and try again.", id: id)
                return
            }

            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                fail("The microphone is not ready. Check your audio connection and try again.", id: id)
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            // Apple's recognizer may use a network service depending on language and device.
            // Requiring on-device recognition here would exclude otherwise supported devices.
            request.requiresOnDeviceRecognition = false
            recognitionRequest = request
            self.recognizer = recognizer
            recognizer.queue = .main
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                Task { @MainActor [weak self] in
                    guard let self, self.captureID == id else { return }
                    if let text, text != self.transcript {
                        self.transcript = text
                        self.lastTranscriptChange = .now
                    }
                    if isFinal {
                        self.deliverTranscript(id: id)
                    } else if error != nil {
                        if self.isFinalizing, !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.deliverTranscript(id: id)
                        } else {
                            self.fail("Speech recognition stopped. Check your connection and try again.", id: id)
                        }
                    }
                }
            }

            tappedInput = input
            // Let the input node use its current hardware format instead of pinning a stale
            // sample rate across a Bluetooth/CarPlay route transition.
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            beganAt = .now
            lastTranscriptChange = beganAt
            isListening = true
            observeAudioChanges(id: id, engine: engine)
            monitorCapture(id: id)
        } catch {
            fail("Could not start the microphone. Check your audio connection and try again.", id: id)
        }
    }

    /// Ends microphone use immediately, allowing a short window for the recognizer's final text.
    func finish() {
        guard let id = captureID, !isFinalizing else { return }
        guard isListening else {
            // A tap during a pending permission prompt must not start recording later.
            cancel()
            return
        }
        isFinalizing = true
        stopMicrophone()
        endRecognitionAudio()
        finalizationDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            guard let self, self.captureID == id else { return }
            self.deliverTranscript(id: id)
        }
    }

    /// Cancellation never submits a partial transcript and never reports an error.
    func cancel() {
        captureID = nil
        finalHandler = nil
        errorHandler = nil
        cleanUp()
        transcript = ""
        lastError = nil
    }

    private func deliverTranscript(id: UUID) {
        guard captureID == id else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail("No speech was heard. Tap the microphone and try again.", id: id)
            return
        }
        captureID = nil
        let handler = finalHandler
        finalHandler = nil
        errorHandler = nil
        cleanUp()
        handler?(text)
    }

    private func fail(_ message: String, id: UUID) {
        guard captureID == id else { return }
        captureID = nil
        let handler = errorHandler
        finalHandler = nil
        errorHandler = nil
        cleanUp()
        lastError = message
        handler?(message)
    }

    private func monitorCapture(id: UUID) {
        captureMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, self.captureID == id, self.isListening else { return }
                let elapsed = Date().timeIntervalSince(self.beganAt)
                if elapsed >= 45 {
                    self.finish()
                    return
                }
                if !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   Date().timeIntervalSince(self.lastTranscriptChange) >= 2.5 {
                    self.finish()
                    return
                }
                if elapsed >= 12, self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.fail("No speech was heard. Tap the microphone and try again.", id: id)
                    return
                }
            }
        }
    }

    private func observeAudioChanges(id: UUID, engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                self.fail("Voice input was interrupted. Tap the microphone to try again.", id: id)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable || reason == .newDeviceAvailable || reason == .noSuitableRouteForCategory || reason == .routeConfigurationChange else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                self.fail("The audio connection changed. Tap the microphone to try again.", id: id)
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                self.fail("The microphone connection changed. Tap the microphone to try again.", id: id)
            }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isListening else { return }
                    self.fail("Audio became unavailable. Tap the microphone to try again.", id: id)
                }
            })
        }
    }

    private func stopMicrophone() {
        isListening = false
        captureMonitor?.cancel()
        captureMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        audioEngine?.stop()
        if tapInstalled {
            tappedInput?.removeTap(onBus: 0)
            tapInstalled = false
        }
        tappedInput = nil
        audioEngine = nil
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func cleanUp() {
        stopMicrophone()
        finalizationDeadline?.cancel()
        finalizationDeadline = nil
        endRecognitionAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        endedRecognitionAudio = false
        recognizer = nil
        isFinalizing = false
        hasPendingCapture = false
    }

    private func endRecognitionAudio() {
        guard !endedRecognitionAudio, let recognitionRequest else { return }
        endedRecognitionAudio = true
        recognitionRequest.endAudio()
    }

    private static func authorizeSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }

    private static func authorizeMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    private static func supportedLocale(for identifier: String) -> Locale? {
        let preferred = Locale(identifier: identifier.isEmpty ? Locale.current.identifier : identifier)
        let normalized = preferred.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let supported = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
        if let exact = supported.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == normalized }) {
            return exact
        }
        // Device language/region combinations such as en-CN need the supported dictation
        // locale for that language rather than silently switching to another language.
        guard let language = preferred.language.languageCode?.identifier else { return nil }
        return supported.first { $0.language.languageCode?.identifier == language }
    }

    deinit {
        captureMonitor?.cancel()
        finalizationDeadline?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        audioEngine?.stop()
        if tapInstalled { tappedInput?.removeTap(onBus: 0) }
        recognitionTask?.cancel()
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
