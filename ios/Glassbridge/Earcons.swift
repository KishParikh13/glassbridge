import AVFoundation
import Foundation

/// Synthesizes short WAV tones. Kept separate from playback so both the earcons and the
/// speaker diagnostic build sound the same way.
enum ToneSynth {
    struct Segment {
        var frequency: Double
        var duration: TimeInterval
        var amplitude: Double = 0.5

        /// A rest. Frequency is ignored.
        static func silence(_ duration: TimeInterval) -> Segment {
            Segment(frequency: 0, duration: duration, amplitude: 0)
        }
    }

    /// Nearest frequency that fits a whole number of cycles into `loopDuration`.
    ///
    /// This is what makes a bed loop without clicking: if every partial completes an
    /// integer number of cycles, the last sample is continuous with the first by
    /// construction rather than by luck. A click every four seconds would be far worse
    /// than the ticking it replaces.
    static func snap(_ freq: Double, loopDuration: Double) -> Double {
        (freq * loopDuration).rounded() / loopDuration
    }

    /// A seamless loop built from summed partials, with optional slow breathing.
    static func bedWAV(
        loopDuration: Double,
        partials: [(freq: Double, weight: Double)],
        amplitude: Double,
        tremoloHz: Double? = nil,
        tremoloDepth: Double = 0.30,
        sampleRate: Double = 16_000
    ) -> Data {
        let frameCount = Int(loopDuration * sampleRate)
        let snapped = partials.map { (snap($0.freq, loopDuration: loopDuration), $0.weight) }
        let tremolo = tremoloHz.map { snap($0, loopDuration: loopDuration) }
        let totalWeight = snapped.reduce(0) { $0 + $1.1 }

        var samples = Data(capacity: frameCount * 2)
        for n in 0..<frameCount {
            let t = Double(n) / sampleRate
            var value = snapped.reduce(0.0) { acc, p in
                acc + p.1 * sin(2 * Double.pi * p.0 * t)
            } / totalWeight
            if let tremolo {
                value *= 1.0 - tremoloDepth * (0.5 - 0.5 * cos(2 * Double.pi * tremolo * t))
            }
            var little = Int16(max(-1, min(1, value * amplitude)) * 32_767).littleEndian
            withUnsafeBytes(of: &little) { samples.append(contentsOf: $0) }
        }
        return riff(samples, sampleRate: sampleRate)
    }

    /// Struck or plucked notes over an optional drone, wrapping around the loop.
    ///
    /// A note started near the end continues into the beginning of the next pass, so the
    /// music does not audibly restart. Without the wrap, "seamless" would only mean "no
    /// click" and you would still hear it begin again every few seconds.
    ///
    /// `partials` shapes the timbre as (harmonic ratio, weight): one entry is a pure sine,
    /// adding an octave and a fifth moves it toward an electric piano.
    static func notesWAV(
        loopDuration: Double,
        events: [(at: Double, freq: Double, velocity: Double)],
        partials: [(ratio: Double, weight: Double)] = [(1.0, 1.0)],
        amplitude: Double,
        attack: Double = 0.02,
        decay: Double = 1.4,
        under: [(freq: Double, weight: Double)] = [],
        underAmplitude: Double = 0.05,
        sampleRate: Double = 16_000
    ) -> Data {
        let frameCount = Int(loopDuration * sampleRate)
        var buffer = [Double](repeating: 0, count: frameCount)

        for event in events {
            let snapped = partials.map {
                (snap(event.freq * $0.ratio, loopDuration: loopDuration), $0.weight)
            }
            let totalWeight = snapped.reduce(0) { $0 + $1.1 }
            let length = Int(min(decay * 4, loopDuration) * sampleRate)
            let start = Int(event.at * sampleRate)
            for i in 0..<length {
                let t = Double(i) / sampleRate
                let env = min(1.0, t / attack) * exp(-t / decay)
                if env < 1e-4 { break }
                let pos = (start + i) % frameCount
                let gt = Double(pos) / sampleRate
                let v = snapped.reduce(0.0) { $0 + $1.1 * sin(2 * Double.pi * $1.0 * gt) } / totalWeight
                buffer[pos] += v * amplitude * event.velocity * env
            }
        }

        if !under.isEmpty {
            let snapped = under.map { (snap($0.freq, loopDuration: loopDuration), $0.weight) }
            let totalWeight = snapped.reduce(0) { $0 + $1.1 }
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let v = snapped.reduce(0.0) { $0 + $1.1 * sin(2 * Double.pi * $1.0 * t) } / totalWeight
                buffer[i] += v * underAmplitude
            }
        }

        return pcm(buffer, sampleRate: sampleRate)
    }

    /// Sustained chords crossfading into one another, wrapping at the loop point.
    static func chordsWAV(
        loopDuration: Double,
        chords: [[Double]],
        amplitude: Double,
        crossfade: Double = 1.5,
        sampleRate: Double = 16_000
    ) -> Data {
        let frameCount = Int(loopDuration * sampleRate)
        var buffer = [Double](repeating: 0, count: frameCount)
        let span = loopDuration / Double(chords.count)

        for (index, chord) in chords.enumerated() {
            let snapped = chord.map { snap($0, loopDuration: loopDuration) }
            let start = Double(index) * span
            for i in 0..<frameCount {
                let gt = Double(i) / sampleRate
                var d = (gt - start).truncatingRemainder(dividingBy: loopDuration)
                if d < 0 { d += loopDuration }
                if d > span + crossfade { continue }
                let env: Double
                if d < crossfade { env = d / crossfade }
                else if d < span { env = 1.0 }
                else { env = max(0, 1.0 - (d - span) / crossfade) }
                if env <= 0 { continue }
                let v = snapped.reduce(0.0) { $0 + sin(2 * Double.pi * $1 * gt) } / Double(snapped.count)
                buffer[i] += v * amplitude * env
            }
        }
        return pcm(buffer, sampleRate: sampleRate)
    }

    private static func pcm(_ buffer: [Double], sampleRate: Double) -> Data {
        var samples = Data(capacity: buffer.count * 2)
        for value in buffer {
            var little = Int16(max(-1, min(1, value)) * 32_767).littleEndian
            withUnsafeBytes(of: &little) { samples.append(contentsOf: $0) }
        }
        return riff(samples, sampleRate: sampleRate)
    }

    static func wav(_ segments: [Segment], sampleRate: Double = 16_000) -> Data {
        var samples = Data()
        for segment in segments {
            let frameCount = Int(segment.duration * sampleRate)
            guard frameCount > 0 else { continue }
            for n in 0..<frameCount {
                let t = Double(n) / sampleRate
                // 8ms in and out so the tone does not click at the boundaries.
                let fade = min(1.0, min(t, segment.duration - t) / 0.008)
                let value = segment.frequency > 0
                    ? sin(2 * Double.pi * segment.frequency * t) * segment.amplitude * max(0, fade)
                    : 0
                var little = Int16(max(-1, min(1, value)) * 32_767).littleEndian
                withUnsafeBytes(of: &little) { samples.append(contentsOf: $0) }
            }
        }

        return riff(samples, sampleRate: sampleRate)
    }

    /// Wrap raw 16-bit mono PCM in a WAV header.
    private static func riff(_ samples: Data, sampleRate: Double) -> Data {
        let dataBytes = UInt32(samples.count)
        var out = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        out.append("data".data(using: .ascii)!); u32(dataBytes); out.append(samples)
        return out
    }
}

/// The app's audible vocabulary.
///
/// With the phone pocketed and no screen to look at, these are the only feedback the user
/// gets. `captured` matters most: it tells you the frame is taken and you can stop holding
/// the thing up to the light, and it is what makes "capture, then cancel if it misfired"
/// a usable trade rather than a silent surprise.
@MainActor
final class Earcons {
    enum Cue {
        /// Wake heard. Rising, "go ahead".
        case listening
        /// Frame taken. A single tick.
        case captured
        /// Still working. Quiet, repeated by the caller.
        case thinking
        /// Turn dropped. Falling, the inverse of `listening`.
        case cancelled
        /// Something failed.
        case error
        /// Wake word off. Long descending, clearly terminal.
        case asleep
        /// Wake word back on.
        case awake

        var segments: [ToneSynth.Segment] {
            switch self {
            case .listening:
                return [.init(frequency: 587.33, duration: 0.07),
                        .init(frequency: 880.00, duration: 0.09)]
            case .captured:
                return [.init(frequency: 1174.66, duration: 0.05, amplitude: 0.4)]
            case .thinking:
                return [.init(frequency: 440.00, duration: 0.04, amplitude: 0.18)]
            case .cancelled:
                return [.init(frequency: 880.00, duration: 0.07),
                        .init(frequency: 587.33, duration: 0.09)]
            case .error:
                return [.init(frequency: 311.13, duration: 0.09),
                        .silence(0.05),
                        .init(frequency: 311.13, duration: 0.09)]
            case .asleep:
                return [.init(frequency: 587.33, duration: 0.09),
                        .init(frequency: 440.00, duration: 0.09),
                        .init(frequency: 329.63, duration: 0.16)]
            case .awake:
                return [.init(frequency: 329.63, duration: 0.09),
                        .init(frequency: 440.00, duration: 0.09),
                        .init(frequency: 587.33, duration: 0.12)]
            }
        }
    }

    /// Rendered once and reused. These play many times per session and synthesis is cheap
    /// but not free.
    private var cache: [String: AVAudioPlayer] = [:]

    /// The continuous bed played while waiting for a reply.
    ///
    /// A repeating tick says "still ticking". A bed fills the wait instead of marking it,
    /// which matters more here than it would on a screen: there is nothing to look at, and
    /// KishOS turns run ten seconds or more.
    ///
    /// All of these are low, quiet, and deliberately unlike speech — no consonants, no
    /// sudden onsets, nothing in the 1-3 kHz band where vowels carry — because the wake
    /// recogniser is still listening underneath while this plays.
    /// The seven options in `docs/earcons/index.html`, so picking one is a one-word change
    /// here rather than a round trip.
    enum Bed: String, CaseIterable {
        /// Soft major-ninth chord breathing on a 4s cycle. Elevator music without a melody.
        case pad
        /// The pad with somewhere to go: two chords crossfading over 8s.
        case move
        /// Lower and richer. The least "device" of them, easiest to talk over.
        case deep
        /// Soft electric piano, two chords. The most straightforwardly hold music.
        case rhodes
        /// High sparse bells over a warm pad. Prettiest, most likely to be noticed.
        case box
        /// Four notes over a drone. The plainest musical option.
        case hold
        /// Two detuned low tones beating slowly. Not music; reads as "on".
        case drone

        // Note names used below, for readability.
        private static let c = 261.63, e = 329.63, f = 349.23
        private static let g = 392.00, a = 440.00, d5 = 587.33

        /// Soft electric piano.
        private static let rhodesTimbre: [(Double, Double)] =
            [(1.0, 1.0), (2.0, 0.35), (3.0, 0.12), (4.01, 0.06)]
        /// Music box / celeste: an inharmonic partial gives the struck-metal ring.
        private static let boxTimbre: [(Double, Double)] =
            [(1.0, 1.0), (2.0, 0.5), (5.4, 0.18)]

        var data: Data {
            switch self {
            case .pad:
                return ToneSynth.bedWAV(
                    loopDuration: 4.0,
                    partials: [(146.83, 1.0), (220.00, 0.7), (293.66, 0.5),
                               (329.63, 0.35), (440.00, 0.2)],
                    amplitude: 0.12, tremoloHz: 0.25)

            case .move:
                return ToneSynth.chordsWAV(
                    loopDuration: 8.0,
                    chords: [[146.83, 220.00, 293.66, 349.23],
                             [174.61, 261.63, 329.63, 392.00]],
                    amplitude: 0.115, crossfade: 1.6)

            case .deep:
                return ToneSynth.bedWAV(
                    loopDuration: 6.0,
                    partials: [(98.00, 1.0), (146.83, 0.8), (196.00, 0.55),
                               (246.94, 0.3), (293.66, 0.18)],
                    amplitude: 0.125, tremoloHz: 0.166, tremoloDepth: 0.22)

            case .rhodes:
                return ToneSynth.notesWAV(
                    loopDuration: 8.0,
                    events: [(0.0, Self.c, 1.0), (0.0, Self.e, 0.8), (0.0, Self.g, 0.7),
                             (0.55, Self.d5, 0.5),
                             (4.0, Self.a / 2, 1.0), (4.0, Self.c, 0.8), (4.0, Self.e, 0.7),
                             (4.55, Self.g, 0.5)],
                    partials: Self.rhodesTimbre, amplitude: 0.085,
                    attack: 0.015, decay: 1.9,
                    under: [(130.81, 1.0), (164.81, 0.5)], underAmplitude: 0.035)

            case .box:
                return ToneSynth.notesWAV(
                    loopDuration: 8.0,
                    events: [(0.0, Self.g * 2, 0.9), (0.9, Self.c * 2, 0.8),
                             (1.8, Self.e * 2, 0.75), (2.7, Self.d5 * 2, 0.6),
                             (4.0, Self.f * 2, 0.85), (4.9, Self.a * 2, 0.8),
                             (5.8, Self.c * 2, 0.7), (6.7, Self.g * 2, 0.55)],
                    partials: Self.boxTimbre, amplitude: 0.055,
                    attack: 0.006, decay: 1.0,
                    under: [(130.81, 1.0), (196.00, 0.55), (261.63, 0.3)],
                    underAmplitude: 0.05)

            case .hold:
                return ToneSynth.notesWAV(
                    loopDuration: 4.0,
                    events: [(0.0, Self.c, 1.0), (1.0, Self.e, 0.9),
                             (2.0, Self.g, 0.85), (3.0, Self.e, 0.8)],
                    amplitude: 0.11, attack: 0.25, decay: 1.1,
                    under: [(130.81, 1.0), (196.00, 0.4)], underAmplitude: 0.045)

            case .drone:
                return ToneSynth.bedWAV(
                    loopDuration: 4.0,
                    partials: [(110.00, 1.0), (110.75, 0.9), (220.00, 0.25)],
                    amplitude: 0.10)
            }
        }
    }

    /// Which bed to play. One line to change once a favourite is picked.
    var bed: Bed = .pad

    private var thinkingPlayer: AVAudioPlayer?
    private var thinkingStarter: Task<Void, Never>?

    /// Fade the bed in after a delay, and keep it going until `stopThinking()`.
    ///
    /// The delay is why a fast turn is completely silent: at ~3s for the built-in agent
    /// most replies land before it ever starts. It only shows up when the wait is long
    /// enough to need explaining.
    func startThinking(after delay: TimeInterval = 1.2, fadeIn: TimeInterval = 0.6) {
        stopThinking()
        thinkingStarter = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard let player = try? AVAudioPlayer(data: self.bed.data,
                                                  fileTypeHint: AVFileType.wav.rawValue) else { return }
            player.numberOfLoops = -1        // seamless by construction; see ToneSynth.snap
            player.volume = 0
            player.prepareToPlay()
            player.play()
            player.setVolume(1, fadeDuration: fadeIn)
            self.thinkingPlayer = player
        }
    }

    /// Fade out rather than cut, so the reply does not start on top of a hard stop.
    func stopThinking(fadeOut: TimeInterval = 0.25) {
        thinkingStarter?.cancel()
        thinkingStarter = nil
        guard let player = thinkingPlayer else { return }
        thinkingPlayer = nil
        player.setVolume(0, fadeDuration: fadeOut)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(fadeOut * 1_000_000_000))
            player.stop()
        }
    }

    /// Fire and forget. Deliberately does not await: an earcon must never delay the thing
    /// it is announcing, and overlapping cues are fine.
    func play(_ cue: Cue) {
        let key = String(describing: cue)
        if let cached = cache[key] {
            cached.currentTime = 0
            cached.play()
            return
        }
        guard let player = try? AVAudioPlayer(
            data: ToneSynth.wav(cue.segments),
            fileTypeHint: AVFileType.wav.rawValue
        ) else { return }
        player.prepareToPlay()
        cache[key] = player
        player.play()
    }
}
