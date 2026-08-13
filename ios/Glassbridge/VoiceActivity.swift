import Accelerate
import AVFoundation
import Foundation

/// Notices that you started talking, without caring what you said.
///
/// Recognising the wake phrase over a reply is the hardest version of barge-in: the
/// recogniser has to pick a specific sequence of words out of audio that already contains
/// a voice. Detecting that a second voice arrived at all is far easier and much faster,
/// and during a reply or a follow-up window it means the same thing — you want to talk.
///
/// Feeds from `MicrophoneHub` like everything else, so it costs no extra claim on the mic
/// and runs happily while a recording or the wake recogniser is also attached.
final class VoiceActivityDetector: @unchecked Sendable {

    struct Options {
        /// RMS above this counts as someone talking. Deliberately well above
        /// `MicRecorder`'s silence threshold: this has to survive whatever echo of the
        /// reply leaks past `.voiceChat` cancellation, and a false trigger here cuts off
        /// an answer you were listening to.
        var threshold: Float = 0.06
        /// How long it has to stay loud. Filters door slams and the earcons themselves.
        var sustain: TimeInterval = 0.22
    }

    /// Called on the main actor once per activation.
    private let onSpeech: @MainActor () -> Void
    private var options: Options

    private let lock = NSLock()
    private var sinkID: UUID?
    private var loudRun: TimeInterval = 0
    private var fired = false
    /// Loudest level seen since the last start, so the log can say how close it came.
    private var peak: Float = 0

    init(options: Options = Options(), onSpeech: @escaping @MainActor () -> Void) {
        self.options = options
        self.onSpeech = onSpeech
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return sinkID != nil
    }

    /// Highest RMS observed while running. Used to tune the threshold against real echo
    /// rather than guesswork.
    var observedPeak: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    func start() {
        lock.lock()
        guard sinkID == nil else { lock.unlock(); return }
        loudRun = 0
        fired = false
        peak = 0
        lock.unlock()

        let id = try? MicrophoneHub.shared.addSink { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        lock.lock()
        sinkID = id
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let id = sinkID
        sinkID = nil
        lock.unlock()
        if let id { MicrophoneHub.shared.removeSink(id) }
    }

    /// Realtime audio thread.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var level: Float = 0
        vDSP_rmsqv(channel, 1, &level, vDSP_Length(buffer.frameLength))

        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate

        lock.lock()
        if fired || sinkID == nil {
            lock.unlock()
            return
        }
        peak = max(peak, level)
        if level >= options.threshold {
            loudRun += seconds
        } else {
            loudRun = 0
        }
        let shouldFire = loudRun >= options.sustain
        if shouldFire { fired = true }
        lock.unlock()

        if shouldFire {
            Task { @MainActor [onSpeech] in onSpeech() }
        }
    }
}
