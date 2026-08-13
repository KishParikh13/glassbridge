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

    private enum StartError: LocalizedError {
        case noInputYet
        var errorDescription: String? {
            "No microphone input on the current route yet."
        }
    }

    /// One trigger phrase and the agent it reaches.
    ///
    /// These come from the backend's `GET /agents` rather than being compiled in, so
    /// adding an assistant is a config edit on the server. The device arms whatever it is
    /// told about.
    struct WakePhrase: Equatable {
        let agentId: String
        let phrase: String
        let words: [String]

        init(agentId: String, phrase: String) {
            self.agentId = agentId
            self.phrase = phrase.lowercased()
            self.words = WakeWordListener.words(in: phrase)
        }
    }

    enum Command: Hashable {
        /// A trigger phrase. Starts a turn with the agent that phrase belongs to.
        case wake(agentId: String)
        /// "never mind". Drops whatever is in flight.
        case cancel
        /// "stop". Cuts a reply short without dropping the turn.
        case stopSpeaking
        /// "go to sleep". Switches the listener off until you turn it back on.
        case sleep
        /// "look". Attaches a photo to the question being asked right now.
        ///
        /// Deliberately not a wake variant. The listener keeps running through the whole
        /// turn, so this can fire from anywhere in the sentence ("hey glass, look at this
        /// label" or "hey glass, what is this, have a look") and the capture starts the
        /// moment the word lands, concurrently with the rest of the recording. Making it
        /// part of the wake phrase would have meant pausing after every "hey glass" to
        /// see whether "look" followed.
        case look

        var flag: Scope {
            switch self {
            case .wake: return .wake
            case .cancel: return .cancel
            case .stopSpeaking: return .stopSpeaking
            case .sleep: return .sleep
            case .look: return .look
            }
        }

        /// Stable name for logs and recordings.
        var name: String {
            switch self {
            case .wake(let agentId): return "wake:\(agentId)"
            case .cancel: return "cancel"
            case .stopSpeaking: return "stopSpeaking"
            case .sleep: return "sleep"
            case .look: return "look"
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
        static let look = Scope(rawValue: 1 << 4)

        /// Nothing running: you can start a turn or send it to sleep.
        static let idle: Scope = [.wake, .sleep]
        /// Recording the question. "stop" is deliberately absent: it would fire on the
        /// question itself. "look" is armed because this is exactly when you say it.
        static let capturing: Scope = [.cancel, .sleep, .look]
        /// Waiting on the backend. Too late to ask for a photo, the audio is already sent,
        /// but the trigger phrase is armed: saying it while it thinks means "forget that,
        /// here is a different question", and being ignored there just feels broken.
        static let thinking: Scope = [.wake, .cancel, .sleep]
        /// A reply is playing, so "stop" finally has something to mean. The trigger phrase
        /// is armed too: talking over the answer to ask the next thing is the whole point
        /// of barge-in, and waiting politely for it to finish is not a conversation.
        static let speaking: Scope = [.wake, .cancel, .stopSpeaking, .sleep]

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
    /// What the recogniser is hearing right now, in its original casing.
    ///
    /// The recogniser already runs continuously, so the words are transcribed on device
    /// before the recording is ever uploaded. Showing them costs nothing and turns the
    /// listening phase from a blank screen into something you can watch.
    @Published private(set) var liveTranscript: String = ""

    var onCommand: ((Command) -> Void)?
    var onObservation: ((Observation) -> Void)?

    /// Longest phrase first, so "hey glass studio" would win over "hey glass" rather than
    /// the shorter one swallowing it.
    private var wakePhrases: [WakePhrase]
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sinkID: UUID?
    private var enabled = false        // user wants it on
    private var scope: Scope = .idle   // what counts right now
    private var generation = 0         // stale recognition callbacks drop themselves
    private var consumed = false       // a command already fired on this transcript
    private var reported: Set<Command> = []   // matches already logged for this task
    private var retryAttempt = 0       // consecutive failed starts
    private var retryTask: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?

    /// Checked in order, so a longer phrase wins over a shorter one that overlaps it.
    private static let controlPhrases: [(command: Command, words: [String])] = [
        (.sleep, ["go", "to", "sleep"]),
        (.cancel, ["never", "mind"]),
        // Apple's recognizer emits this as one token about as often as two.
        (.cancel, ["nevermind"]),
        (.stopSpeaking, ["stop"]),
        // Whole-word, so "looking" and "lookout" do not fire it.
        (.look, ["look"]),
    ]

    init(phrase: String = "hey glass") {
        self.wakePhrases = [WakePhrase(agentId: "glass", phrase: phrase)]
    }

    /// Replace the armed phrases, normally from `GET /agents`.
    ///
    /// Falls back to whatever is already armed if handed nothing, so a backend that is
    /// unreachable at launch leaves the glasses still answering to the built-in phrase
    /// instead of going deaf.
    func setWakePhrases(_ phrases: [WakePhrase]) {
        guard !phrases.isEmpty else { return }
        let sorted = phrases.sorted { $0.words.count > $1.words.count }
        guard sorted != wakePhrases else { return }
        wakePhrases = sorted
        gblog("[WAKE] armed phrases: \(sorted.map { "\($0.phrase) → \($0.agentId)" }.joined(separator: ", "))")
        if enabled { restart() }
    }

    /// The default agent's phrase, for UI that shows a single example.
    var triggerPhrase: String { wakePhrases.last?.phrase ?? "hey glass" }

    var allTriggerPhrases: [String] { wakePhrases.map(\.phrase) }

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
                self.observeRouteChanges()
                self.beginTask()
            }
        }
    }

    func stop() {
        enabled = false
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        teardown()
        state = .off
    }

    /// Try again after a failed start, backing off.
    ///
    /// The failures that matter here are transient: another Bluetooth device takes the
    /// route, the glasses fold, the session activates a moment before an input attaches.
    /// Before this, one of those at launch left the wake word dead for the rest of the
    /// session with no indication beyond it silently not working.
    private func scheduleRetry() {
        guard enabled, retryTask == nil else { return }
        retryAttempt += 1
        let delay = min(8.0, 0.5 * pow(2.0, Double(retryAttempt - 1)))
        gblog("[WAKE] retry \(retryAttempt) in \(String(format: "%.1f", delay))s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            guard self.enabled, self.state != .listening else { return }
            self.beginTask()
        }
    }

    /// Routes change constantly in this product: glasses fold, AirPods connect, a call
    /// arrives. Any of those can hand us an input where there was none, so treat a route
    /// change as a free retry rather than waiting out the backoff.
    private func observeRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.state != .listening else { return }
                gblog("[WAKE] route changed while not listening — retrying")
                self.retryTask?.cancel()
                self.retryTask = nil
                self.retryAttempt = 0
                self.beginTask()
            }
        }
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

            // The session reports an active route before an input is necessarily attached,
            // which happens routinely when another Bluetooth device (AirPods) takes over
            // and leaves an A2DP output with no microphone. Starting the tap then throws.
            // Treat it as "not yet" and retry, rather than as fatal.
            guard MicrophoneHub.shared.inputFormat.sampleRate > 0 else {
                throw StartError.noInputYet
            }

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
            liveTranscript = ""

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
            retryAttempt = 0
        } catch {
            gblog("[WAKE] could not start listening: \(error.localizedDescription)")
            state = .unavailable
            teardown()
            scheduleRetry()
        }
    }

    private func handle(transcript: String) {
        guard !consumed else { return }
        lastHeard = transcript.lowercased()
        liveTranscript = transcript

        let heard = Self.words(in: transcript)
        for wake in wakePhrases where Self.contains(wake.words, in: heard) {
            let command = Command.wake(agentId: wake.agentId)
            observe(transcript, command)
            if scope.contains(.wake) {
                fire(command)
                return
            }
            break
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
        gblog("[VOICE] \(command.name)")
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

    nonisolated static func words(in text: String) -> [String] {
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
