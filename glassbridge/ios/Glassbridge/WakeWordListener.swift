import Foundation
import Speech
import AVFoundation

/// Continuous on-device speech recognition that turns a small spoken grammar into
/// commands. The trigger phrase (default "hey glass") starts a turn; the rest of the
/// vocabulary is the handful of controls you need once one is already running.
///
/// It owns neither an `AVAudioEngine` nor the audio session. Buffers come from
/// `MicrophoneHub` and `AudioSessionController` owns the session, so this keeps listening
/// straight through a recording and through playback instead of being torn down around
/// every ask. That is what makes barge-in work: you can say "stop" over Claude's own
/// voice, and `.voiceChat` echo cancellation is what keeps the reply out of the recognizer.
@MainActor
final class WakeWordListener: ObservableObject {
    enum State: String {
        case off, listening, denied, unavailable
    }

    enum Command: Equatable {
        /// The trigger phrase. Starts a turn.
        case wake
        /// "never mind". Drops whatever is in flight.
        case cancel
        /// "stop". Cuts a reply short without dropping the turn.
        case stopSpeaking
        /// "go to sleep". Switches the listener off until you turn it back on.
        case sleep

        var flag: Scope {
            switch self {
            case .wake: return .wake
            case .cancel: return .cancel
            case .stopSpeaking: return .stopSpeaking
            case .sleep: return .sleep
            }
        }
    }

    /// What the owner currently wants to hear. Anything outside the scope is ignored,
    /// which is the whole reason this is safe to leave running: a question containing the
    /// word "stop" cannot cut off a reply that has not started, and the trigger phrase
    /// spoken inside a question cannot open a second turn on top of the first.
    struct Scope: OptionSet {
        let rawValue: Int

        static let wake = Scope(rawValue: 1 << 0)
        static let cancel = Scope(rawValue: 1 << 1)
        static let stopSpeaking = Scope(rawValue: 1 << 2)
        static let sleep = Scope(rawValue: 1 << 3)

        /// Nothing running: you can start a turn or send it to sleep.
        static let idle: Scope = [.wake, .sleep]
        /// Recording, or waiting on the backend. "stop" is deliberately absent here: it
        /// would fire on the question itself.
        static let capturing: Scope = [.cancel, .sleep]
        /// A reply is playing, so "stop" finally has something to mean.
        static let speaking: Scope = [.cancel, .stopSpeaking, .sleep]
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastHeard: String = ""

    var onCommand: ((Command) -> Void)?

    private let phrase: String
    private let phraseWords: [String]
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sinkID: UUID?
    private var enabled = false        // user wants it on
    private var scope: Scope = .idle   // what counts right now
    private var generation = 0         // stale recognition callbacks drop themselves
    private var consumed = false       // a command already fired on this transcript

    /// Checked in order, so a longer phrase wins over a shorter one that overlaps it.
    private static let controlPhrases: [(command: Command, words: [String])] = [
        (.sleep, ["go", "to", "sleep"]),
        (.cancel, ["never", "mind"]),
        // Apple's recognizer emits this as one token about as often as two.
        (.cancel, ["nevermind"]),
        (.stopSpeaking, ["stop"]),
    ]

    init(phrase: String = "hey glass") {
        self.phrase = phrase.lowercased()
        self.phraseWords = Self.words(in: phrase)
    }

    var triggerPhrase: String { phrase }

    func start() {
        guard !enabled else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else { self.state = .denied; return }
                self.enabled = true
                self.beginTask()
            }
        }
    }

    func stop() {
        enabled = false
        teardown()
        state = .off
    }

    /// Change what the listener is armed for. Restarts recognition so words already
    /// sitting in the buffer cannot fire a command that only just became legal.
    func setScope(_ newScope: Scope) {
        guard newScope != scope else { return }
        scope = newScope
        guard enabled else { return }
        restart()
    }

    // MARK: - Internals

    private func beginTask() {
        guard enabled else { return }
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        do {
            try AudioSessionController.shared.activate()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            generation += 1
            let myGeneration = generation
            consumed = false

            // Capture the request rather than self, so the audio thread never touches an
            // actor-isolated object.
            sinkID = try MicrophoneHub.shared.addSink { buffer, _ in
                request.append(buffer)
            }

            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Pull out Sendable primitives on the callback thread, then hop.
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let hadError = error != nil
                Task { @MainActor in
                    guard let self, self.generation == myGeneration else { return }
                    if let text { self.handle(transcript: text) }
                    // Speech tasks cap out (~1 min) and end on silence. Restart to keep
                    // listening, unless handling the transcript already did.
                    guard self.generation == myGeneration, self.enabled else { return }
                    if hadError || isFinal { self.restart() }
                }
            }
            state = .listening
        } catch {
            state = .unavailable
            teardown()
        }
    }

    private func handle(transcript: String) {
        guard !consumed else { return }
        lastHeard = transcript.lowercased()

        let heard = Self.words(in: transcript)
        if scope.contains(.wake), Self.contains(phraseWords, in: heard) {
            fire(.wake)
            return
        }
        for entry in Self.controlPhrases {
            guard scope.contains(entry.command.flag) else { continue }
            if Self.contains(entry.words, in: heard) {
                fire(entry.command)
                return
            }
        }
    }

    private func fire(_ command: Command) {
        // Ignore everything else this task produces. The words that just fired stay in the
        // transcript as it grows, and without this they would fire again on every partial.
        consumed = true
        print("[VOICE] \(command)")
        // The handler usually changes the scope, which restarts recognition for us. If it
        // did not, clear the buffer ourselves rather than sit on a spent transcript.
        onCommand?(command)
        if consumed, enabled { restart() }
    }

    /// Attach the replacement before dropping the old one. `MicrophoneHub` stops the audio
    /// engine the moment its last subscriber leaves, and at idle this listener is usually
    /// the only one, so tearing down first meant stopping and restarting the engine every
    /// time a recognition task hit its one minute cap.
    private func restart() {
        let oldSink = sinkID
        let oldTask = task
        let oldRequest = request
        sinkID = nil
        task = nil
        request = nil

        beginTask()

        if let oldSink { MicrophoneHub.shared.removeSink(oldSink) }
        oldTask?.cancel()
        oldRequest?.endAudio()
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

    // MARK: - Matching

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Whole-word sequence match. Substring matching would fire "stop" on "stopped" and
    /// let a half-heard trigger phrase through.
    private static func contains(_ phrase: [String], in heard: [String]) -> Bool {
        guard !phrase.isEmpty, heard.count >= phrase.count else { return false }
        for start in 0...(heard.count - phrase.count) {
            if Array(heard[start..<(start + phrase.count)]) == phrase { return true }
        }
        return false
    }
}
