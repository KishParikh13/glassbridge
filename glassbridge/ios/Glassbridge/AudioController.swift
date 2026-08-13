import Accelerate
import AVFoundation
import Foundation

/// Recording and playback for the ask loop.
///
/// This deliberately owns neither the audio session nor the microphone any more.
/// `AudioSessionController` owns the session for the app's lifetime, and `MicrophoneHub`
/// owns the single input tap that both this and `WakeWordListener` feed from. That split
/// is what lets the wake word keep listening while a reply is playing.
@MainActor
final class AudioController {
    enum AudioError: LocalizedError {
        case playerFailed(String)

        var errorDescription: String? {
            switch self {
            case .playerFailed(let message): return "Player: \(message)"
            }
        }
    }

    private let recorder = MicRecorder()
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private let playbackDelegate = PlaybackDelegate()

    private var meterSinkID: UUID?
    private let meter = MeterBox()

    init() {
        playbackDelegate.onFinish = { [weak self] in
            Task { @MainActor in self?.completePlayback() }
        }
    }

    // MARK: - Session

    /// Bring the shared session up and give the glasses route a moment to activate.
    /// Falls through to the iPhone mic and speaker when no Bluetooth route appears,
    /// which is the normal case when the glasses are folded or out of range.
    func activateForGlasses(timeout: TimeInterval = 2.0) async throws {
        try AudioSessionController.shared.activate()
        await AudioSessionController.shared.waitForBluetoothRoute(timeout: timeout)
    }

    // MARK: - Recording

    /// Record a question, ending on silence rather than a fixed timer.
    func recordQuestion() async throws -> URL {
        try await recorder.record(.ask)
    }

    /// Record for an exact duration. Used by the loopback diagnostic, which wants a
    /// predictable length rather than a natural one.
    func record(seconds: TimeInterval) async throws -> URL {
        try await recorder.record(.fixed(seconds: seconds))
    }

    // MARK: - Playback

    /// Plays an MP3 buffer through the active route. Returns when playback finishes.
    func play(mp3 data: Data) async throws {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
        } catch {
            throw AudioError.playerFailed(error.localizedDescription)
        }
        try await play(player)
    }

    /// Play any audio file, for example a recorded WAV during loopback.
    func play(fileURL url: URL) async throws {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw AudioError.playerFailed(error.localizedDescription)
        }
        try await play(player)
    }

    /// Synthesize and play a sine tone. A quick check that the glasses speaker works.
    func playTestTone(frequency: Double = 880, seconds: Double = 1.0) async throws {
        let data = Self.sineWAV(frequency: frequency, seconds: seconds)
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        } catch {
            throw AudioError.playerFailed(error.localizedDescription)
        }
        try await play(player)
    }

    /// Stop whatever is playing right now. The spoken-interrupt path will call this.
    func stopPlayback() {
        player?.stop()
        completePlayback()
    }

    private func play(_ player: AVAudioPlayer) async throws {
        // A second play() while one is pending used to overwrite the stored continuation,
        // stranding the first caller forever. Release it before taking over.
        completePlayback()

        player.delegate = playbackDelegate
        guard player.prepareToPlay() else {
            throw AudioError.playerFailed("prepareToPlay returned false")
        }
        self.player = player

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.playbackContinuation = continuation
            if !player.play() {
                self.completePlayback()
            }
        }
    }

    private func completePlayback() {
        let continuation = playbackContinuation
        playbackContinuation = nil
        player = nil
        continuation?.resume()
    }

    // MARK: - Diagnostics

    func routeSummary() -> String { AudioSessionController.shared.routeSummary() }
    func availableInputsSummary() -> String { AudioSessionController.shared.availableInputsSummary() }

    /// Live input metering, fed by the same tap everything else uses rather than a second
    /// recorder competing for the mic.
    func startMicMonitor() throws {
        guard meterSinkID == nil else { return }
        // Capture the box rather than self: the sink runs on the audio thread and must not
        // touch main-actor state.
        let meter = self.meter
        meterSinkID = try MicrophoneHub.shared.addSink { buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var value: Float = 0
            vDSP_rmsqv(channel, 1, &value, vDSP_Length(buffer.frameLength))
            meter.store(value)
        }
    }

    /// Normalized 0...1 input level. Poll while monitoring.
    func micLevel() -> Float {
        let value = meter.load()
        guard value > 0 else { return 0 }
        let db = 20 * log10(value)
        let floor: Float = -50
        let clamped = max(floor, min(0, db))
        return (clamped - floor) / (0 - floor)
    }

    func stopMicMonitor() {
        if let meterSinkID {
            MicrophoneHub.shared.removeSink(meterSinkID)
            self.meterSinkID = nil
        }
        meter.store(0)
    }

    private static func sineWAV(frequency: Double, seconds: Double, sampleRate: Double = 16_000) -> Data {
        let frameCount = Int(seconds * sampleRate)
        var samples = Data(capacity: frameCount * 2)
        let amplitude = 0.6
        for n in 0..<frameCount {
            let t = Double(n) / sampleRate
            let fade = min(1.0, min(t, seconds - t) / 0.01)   // 10ms in/out fade
            let v = sin(2 * Double.pi * frequency * t) * amplitude * max(0, fade)
            var le = Int16(max(-1, min(1, v)) * 32_767).littleEndian
            withUnsafeBytes(of: &le) { samples.append(contentsOf: $0) }
        }
        let dataBytes = UInt32(samples.count)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes); d.append(samples)
        return d
    }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}

/// A one-value mailbox so the realtime audio thread can hand levels to the main actor
/// without either side reaching into the other's isolation.
private final class MeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func store(_ newValue: Float) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
