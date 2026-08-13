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

    enum Command: String, Hashable {
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

        /// Readable in a log, which is where this mostly gets looked at.
        var names: String {
            var out: [String] = []
            if contains(.wake) { out.append("wake") }
            if contains(.cancel) { out.append("cancel") }
            if contains(.stopSpeaking) { out.append("stop") }
            if contains(.sleep) { out.append("sleep") }
            return out.isEmpty ? "none" : out.joined(separator: "+")
        }
    }

    /// A phrase the recognizer matched, and what the listener did about it.
    ///
    /// The out-of-scope case is the interesting one and the reason this exists at all:
    /// hearing "stop" inside a question and declining to act is the scope design doing its
    /// job, and from outside it is indistinguishable from not having heard you.
    struct Observation {
        var transcript: String
        var command: Command
        var armed: Bool
        var scope: Scope
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastHeard: String = ""

    var onCommand: ((Command) -> Void)?
    var onObservation: ((Observation) -> Void)?

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
    private var reported: Set<Command> = []   // matches already logged for this task

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
                guard auth == .authorized else {
                    gblog("[WAKE] speech recognition not authorized (\(auth.rawValue)) — listener stays off")
                    self.state = .denied
                    return
                }
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
        guard let recognizer, recognizer.isAvailable else {
            gblog("[WAKE] recognizer unavailable (locale or on-device model missing)")
            state = .unavailable
            return
        }
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
            reported.removeAll()

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
            gblog("[WAKE] could not start listening: \(error.localizedDescription)")
            state = .unavailable
            teardown()
        }
    }

    private func handle(transcript: String) {
        guard !consumed else { return }
        lastHeard = transcript.lowercased()

        let heard = Self.words(in: transcript)
        if Self.contains(phraseWords, in: heard) {
            observe(transcript, .wake)
            if scope.contains(.wake) {
                fire(.wake)
                return
            }
        }
        for entry in Self.controlPhrases {
            guard Self.contains(entry.words, in: heard) else { continue }
            observe(transcript, entry.command)
            if scope.contains(entry.command.flag) {
                fire(entry.command)
                return
            }
        }
    }

    /// Report a match once per recognition task. Partial transcripts only grow, so a word
    /// that matched keeps matching on every update after it, and without this the log
    /// would be nothing but repeats.
    private func observe(_ transcript: String, _ command: Command) {
        guard reported.insert(command).inserted else { return }
        onObservation?(Observation(
            transcript: transcript.lowercased(),
            command: command,
            armed: scope.contains(command.flag),
            scope: scope
        ))
    }

    private func fire(_ command: Command) {
        // Ignore everything else this task produces. The words that just fired stay in the
        // transcript as it grows, and without this they would fire again on every partial.
        consumed = true
        gblog("[VOICE] \(command)")
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
