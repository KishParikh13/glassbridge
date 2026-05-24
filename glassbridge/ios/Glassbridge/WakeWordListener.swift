import Foundation
import Speech
import AVFoundation

/// Continuous on-device speech recognition that fires `onWake` when it hears a
/// trigger phrase (default "hey glass"). Lets you start an ASK hands-free with
/// the phone pocketed. Uses Apple's Speech framework — no extra keys/deps.
///
/// Coordination: the recognizer taps the mic via AVAudioEngine, which conflicts
/// with the ASK recorder. The owner must `pause()` before running an ASK and
/// `resume()` afterward.
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
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var enabled = false   // user wants it on
    private var paused = false    // temporarily suspended for an ASK

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

    /// Suspend listening (caller is about to record an ASK).
    func pause() {
        guard enabled else { return }
        paused = true
        teardown()
    }

    /// Resume listening after an ASK completes.
    func resume() {
        guard enabled else { return }
        paused = false
        beginTask()
    }

    // MARK: – Internals

    private func beginTask() {
        guard enabled, !paused else { return }
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .measurement,
                options: [.allowBluetoothHFP, .duckOthers, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            // Capture the request locally so the audio thread never touches `self`.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Extract Sendable primitives off the callback thread, then hop.
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
                    // Speech tasks cap out (~1 min) and end on silence; restart to
                    // keep listening unless we've been paused/stopped.
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
        // Suspend ourselves so the same utterance can't retrigger and the mic is
        // free for the ASK recorder. The owner calls resume() when the ASK ends.
        paused = true
        teardown()
        onWake?()
    }

    private func restart() {
        teardown()
        beginTask()
    }

    private func teardown() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}
