import Accelerate
import AVFoundation
import Foundation

/// Notices that you started talking, without caring what you said.
///
/// Recognising the wake phrase over a reply is the hardest version of barge-in: the
/// recogniser has to pick a specific sequence of words out of audio that already contains
/// a voice. Detecting that a second voice arrived at all is easier and much faster, and
/// during a reply or a follow-up window it means the same thing — you want to talk.
///
/// **Why the threshold adapts.** The first version used a fixed RMS, and picking that
/// number by hand failed twice: 0.06 was far too high and 0.03 was still above where
/// glasses speech actually lives. Measured, close-mic speech sits around -17 dBFS, but the
/// same voice over the glasses' HFP link arrives roughly 15 dB quieter, and how much
/// quieter depends on the room, the fit, and whatever the speaker is doing. A fixed number
/// cannot be right for a quiet kitchen and a noisy street at once.
///
/// So it tracks the floor — the quietest recent audio, which is room noise plus whatever
/// echo of the reply survives `.voiceChat` cancellation — and triggers on a jump above it.
/// This is what production voice stacks do, and it means the sensitivity follows the
/// environment instead of being guessed.
///
/// **What it cannot do.** Meta's own always-on mode filters "speech not intended for the
/// glasses", which is intent classification, not energy. Anything based on level alone
/// will trigger on a person next to you talking. That is the known ceiling here.
final class VoiceActivityDetector: @unchecked Sendable {

    struct Options {
        /// How far above the tracked noise floor counts as someone talking. Voiced speech
        /// runs 25-30 dB above room tone, so 12 dB is comfortably clear of the floor while
        /// still catching a quiet voice over HFP.
        var triggerOverFloorDb: Float = 12

        /// Never trigger below this no matter how quiet the room, so a silent room does
        /// not make the detector hysterical. -42 dBFS sits between the industry silence
        /// line (-45) and its barge-in line (-35), shaded low because HFP is quiet.
        var absoluteFloor: Float = 0.0079   // -42 dBFS

        /// Never require more than this, so a loud room cannot make it deaf.
        var absoluteCeiling: Float = 0.05   // -26 dBFS

        /// How long it has to stay loud. Industry practice is 200-300ms: under 200 is
        /// usually a backchannel ("mm", a cough) rather than someone taking the turn.
        var sustain: TimeInterval = 0.20

        /// Frames used to establish the floor before the detector will fire at all. At
        /// ~23ms per frame this is roughly half a second of listening first, which stops
        /// the very start of a reply from being mistaken for a voice.
        var warmupFrames: Int = 20
    }

    private let onSpeech: @MainActor () -> Void
    private var options: Options

    private let lock = NSLock()
    private var sinkID: UUID?
    private var loudRun: TimeInterval = 0
    private var fired = false
    private var frameCount = 0

    /// Tracked floor: falls fast toward quiet, rises slowly. Asymmetric on purpose, so a
    /// burst of speech does not drag the floor up behind it and deafen the detector.
    private var floor: Float = 0.02
    private var peak: Float = 0
    /// Peak seen while a reply was actually playing. This is the echo measurement: if
    /// cancellation works, it stays near the floor.
    private var peakWhilePlaying: Float = 0
    private var isPlaying = false

    init(options: Options = Options(), onSpeech: @escaping @MainActor () -> Void) {
        self.options = options
        self.onSpeech = onSpeech
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return sinkID != nil
    }

    /// A snapshot for the log, so the numbers can be tuned from evidence.
    struct Levels {
        let peak: Float
        let peakWhilePlaying: Float
        let floor: Float
        let trigger: Float
    }

    var levels: Levels {
        lock.lock(); defer { lock.unlock() }
        return Levels(peak: peak, peakWhilePlaying: peakWhilePlaying,
                      floor: floor, trigger: currentTriggerLocked())
    }

    /// Tell the detector when audio is coming out of the speaker, so echo can be measured
    /// separately from the room.
    func setPlaying(_ playing: Bool) {
        lock.lock()
        isPlaying = playing
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard sinkID == nil else { lock.unlock(); return }
        loudRun = 0
        fired = false
        frameCount = 0
        peak = 0
        peakWhilePlaying = 0
        floor = options.absoluteFloor
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
        isPlaying = false
        lock.unlock()
        if let id { MicrophoneHub.shared.removeSink(id) }
    }

    // MARK: - Internals

    /// Caller holds the lock.
    private func currentTriggerLocked() -> Float {
        let gain = pow(10, options.triggerOverFloorDb / 20)
        return min(options.absoluteCeiling, max(options.absoluteFloor, floor * gain))
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

        frameCount += 1
        peak = max(peak, level)
        if isPlaying { peakWhilePlaying = max(peakWhilePlaying, level) }

        // Down fast, up slow: the floor should chase silence immediately but only creep
        // upward, so a sentence cannot raise the bar it is being measured against.
        floor = level < floor ? (floor * 0.90 + level * 0.10) : (floor * 0.995 + level * 0.005)

        let trigger = currentTriggerLocked()
        if level >= trigger {
            loudRun += seconds
        } else {
            loudRun = 0
        }
        let shouldFire = frameCount >= options.warmupFrames && loudRun >= options.sustain
        if shouldFire { fired = true }
        lock.unlock()

        if shouldFire {
            Task { @MainActor [onSpeech] in onSpeech() }
        }
    }
}
