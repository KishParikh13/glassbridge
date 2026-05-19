import AVFoundation
import Foundation

/// AVAudioSession + record + play, wired for Meta Ray-Ban HFP Bluetooth.
///
/// Key gotcha: `.playAndRecord` + `[.allowBluetoothHFP]` lets HFP appear in
/// `availableInputs`, but iOS only **activates** that route after you call
/// `setPreferredInput(...)` and wait. The HFP route appears with portType
/// `.bluetoothHFP`. If you skip the wait, the next recording grabs the
/// iPhone built-in mic instead.
final class AudioController {
    enum AudioError: LocalizedError {
        case sessionSetupFailed(String)
        case noBluetoothHFPRoute
        case routeActivationTimeout
        case recorderFailed(String)
        case playerFailed(String)

        var errorDescription: String? {
            switch self {
            case .sessionSetupFailed(let msg): return "Audio session: \(msg)"
            case .noBluetoothHFPRoute:
                return "Your Ray-Ban glasses aren't selected as the iPhone's audio device. " +
                       "Open Settings > Bluetooth, tap your glasses, and enable 'Use for Calls'."
            case .routeActivationTimeout:
                return "iOS didn't activate the glasses audio route in time."
            case .recorderFailed(let msg): return "Recorder: \(msg)"
            case .playerFailed(let msg): return "Player: \(msg)"
            }
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private let playbackDelegate = PlaybackDelegate()

    init() {
        playbackDelegate.onFinish = { [weak self] in
            self?.completePlayback()
        }
    }

    /// Configure + activate the session and pin the input to the glasses HFP route.
    /// Returns once the route is active (HFP input + output) or throws.
    func activateForGlasses(timeout: TimeInterval = 2.0) async throws {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .duckOthers, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            throw AudioError.sessionSetupFailed(error.localizedDescription)
        }

        // Glasses can show up as HFP (classic Bluetooth), BLE Audio (newer firmware
        // with LC3), or — fallback — as a wired-headset-like accessory. Accept any.
        let btPortTypes: Set<AVAudioSession.Port> = [
            .bluetoothHFP, .bluetoothLE, .bluetoothA2DP, .headsetMic, .headphones,
        ]
        let available = session.availableInputs ?? []
        let glassesNames = ["RB Meta", "Ray-Ban", "Ray Ban", "Meta"]
        let chosen = available.first(where: { p in
            btPortTypes.contains(p.portType)
                && glassesNames.contains(where: { p.portName.localizedCaseInsensitiveContains($0) })
        }) ?? available.first(where: { btPortTypes.contains($0.portType) })

        if let chosen {
            try? session.setPreferredInput(chosen)
            // Best-effort: poll briefly for BT route activation, but don't fail if it
            // doesn't activate — iPhone mic/speaker fallback is fine for the MVP.
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let route = session.currentRoute
                let inputBT = route.inputs.contains(where: { btPortTypes.contains($0.portType) })
                let outputBT = route.outputs.contains(where: { btPortTypes.contains($0.portType) })
                if inputBT && outputBT { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        // No BT input or BT didn't activate in time — proceed with default route
        // (iPhone built-in mic + speaker). The session is already active.
        return
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Records `seconds` of audio from the glasses mic to a temp WAV file.
    /// Returns the file URL.
    func record(seconds: TimeInterval) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassbridge-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            // HFP from the glasses is 8 kHz mono. Recording at 16 kHz here lets
            // iOS upsample cleanly; Whisper resamples again internally, no harm.
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let r: AVAudioRecorder
        do {
            r = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw AudioError.recorderFailed(error.localizedDescription)
        }
        r.isMeteringEnabled = false
        guard r.prepareToRecord() else {
            throw AudioError.recorderFailed("prepareToRecord returned false")
        }
        guard r.record(forDuration: seconds) else {
            throw AudioError.recorderFailed("record() returned false")
        }
        self.recorder = r

        // Wait the duration + a small tail.
        try await Task.sleep(nanoseconds: UInt64((seconds + 0.15) * 1_000_000_000))
        r.stop()
        self.recorder = nil
        return url
    }

    /// Plays an MP3 buffer through the active route (glasses if HFP active).
    /// Returns when playback finishes.
    func play(mp3 data: Data) async throws {
        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
        } catch {
            throw AudioError.playerFailed(error.localizedDescription)
        }
        p.delegate = playbackDelegate
        guard p.prepareToPlay() else {
            throw AudioError.playerFailed("prepareToPlay returned false")
        }
        self.player = p

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.playbackContinuation = cont
            if !p.play() {
                self.completePlayback()
            }
        }
    }

    private func completePlayback() {
        let cont = self.playbackContinuation
        self.playbackContinuation = nil
        self.player = nil
        cont?.resume()
    }

    /// Snapshot of the current route for the status label.
    func routeSummary() -> String {
        let route = session.currentRoute
        let i = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let o = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "in=[\(i)] out=[\(o)]"
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
