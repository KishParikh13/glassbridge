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

    private var thinkingTicker: Task<Void, Never>?

    /// Tick quietly until `stopThinking()`. The first tick is held back, so a fast reply
    /// makes no sound at all and the ticking only ever means "this one is taking a while."
    func startThinking(after delay: TimeInterval = 1.2, every interval: TimeInterval = 1.6) {
        stopThinking()
        thinkingTicker = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                guard let self else { return }
                self.play(.thinking)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopThinking() {
        thinkingTicker?.cancel()
        thinkingTicker = nil
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
