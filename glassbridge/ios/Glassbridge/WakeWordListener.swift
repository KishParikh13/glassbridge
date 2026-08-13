import Foundation
import Speech
import AVFoundation

/// Continuous on-device speech recognition that fires `onWake` when it hears a trigger
/// phrase (default "hey glass"). Lets you start an ask hands-free with the phone pocketed.
/// Uses Apple's Speech framework, so no extra keys or dependencies.
///
/// It no longer owns an `AVAudioEngine` or the audio session. Buffers come from
/// `MicrophoneHub`, and `AudioSessionController` owns the session, so this can keep
/// listening while a recording or a reply is in flight instead of having to be torn down
/// around every ask.
@MainActor
final class WakeWordListener: ObservableObject {
    enum State: String {
        case off, listening, denied, unavailable
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastHeard: String = ""

    var onWake: (() -> Void)?

    private let phrase: String
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sinkID: UUID?
    private var enabled = false   // user wants it on
    private var paused = false    // temporarily suspended

    init(phrase: String = "hey glass") {
        self.phrase = phrase.lowercased()
    }

    var triggerPhrase: String { phrase }

    func start() {
        guard !enabled else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else { self.state = .denied; return }
                self.enabled = true
                self.paused = false
                self.beginTask()
            }
        }
    }

    func stop() {
        enabled = false
        paused = false
        teardown()
        state = .off
    }

    /// Suspend listening. Nothing about the audio route changes, so resuming is cheap.
    func pause() {
        guard enabled else { return }
        paused = true
        teardown()
    }

    func resume() {
        guard enabled else { return }
        paused = false
        beginTask()
    }

    // MARK: - Internals

    private func beginTask() {
        guard enabled, !paused else { return }
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        do {
            try AudioSessionController.shared.activate()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            // Capture the request rather than self, so the audio thread never touches an
            // actor-isolated object.
            sinkID = try MicrophoneHub.shared.addSink { buffer, _ in
                request.append(buffer)
            }

            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Pull out Sendable primitives on the callback thread, then hop.
                let text = result?.bestTranscription.formattedString.lowercased()
                let isFinal = result?.isFinal ?? false
                let hadError = error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let text {
                        self.lastHeard = text
                        if text.contains(self.phrase) {
                            self.fireWake()
                            return
                        }
                    }
                    // Speech tasks cap out (~1 min) and end on silence; restart to keep
                    // listening unless we have been paused or stopped.
                    if hadError || isFinal, self.enabled, !self.paused {
                        self.restart()
                    }
                }
            }
            state = .listening
        } catch {
            state = .unavailable
            teardown()
        }
    }

    private func fireWake() {
        // Suspend so the same utterance cannot retrigger. The owner calls resume() when
        // the ask ends.
        paused = true
        teardown()
        print("[WAKE] detected \"\(phrase)\"")
        onWake?()
    }

    private func restart() {
        teardown()
        beginTask()
    }

    /// Detaches from the shared mic. It deliberately does not deactivate the audio
    /// session: doing that here used to cut off whatever else was playing.
    private func teardown() {
        if let sinkID {
            MicrophoneHub.shared.removeSink(sinkID)
            self.sinkID = nil
        }
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }
}
