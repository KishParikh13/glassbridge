import Foundation
import SwiftUI

@MainActor
final class SessionCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)

        var label: String {
            switch self {
            case .idle: return "Tap ASK"
            case .listening: return "Listening…"
            case .thinking: return "Thinking…"
            case .speaking: return "Speaking…"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var transcript: String = ""
    @Published var reply: String = ""
    @Published var latencySummary: String = ""

    let glasses = GlassesController()
    private let audio = AudioController()
    private let backend = BackendClient()
    private let iPhoneCapture = IPhoneCapture()
    private var isBusy = false

    @Published var captureSource: String = "auto"

    init() {
        glasses.start()
        #if DEBUG
        maybeRunAutomatedTestAtLaunch()
        #endif
    }

    #if DEBUG
    /// When launched with GB_AUTO_TEST=1 in the env, fire a self-contained test ASK
    /// using a stub silent WAV + the captured photo, with text_override bypassing
    /// Whisper. Result lands in the backend log so we can verify the pipeline end-to-end.
    private func maybeRunAutomatedTestAtLaunch() {
        let envHit = ProcessInfo.processInfo.environment["GB_AUTO_TEST"] == "1"
        let argHit = ProcessInfo.processInfo.arguments.contains("--gb-auto-test")
        guard envHit || argHit else { return }
        print("[TEST] auto-test trigger detected (env=\(envHit) arg=\(argHit))")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.runTestAsk()
        }
    }

    func runTestAsk() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            phase = .listening
            captureSource = "automated test (stub image + silent wav + text_override)"
            // Bypass glasses/iPhone capture entirely — use the stub image MockSetup
            // produced. Works regardless of whether Wearables.shared is usable.
            guard let image = MockSetup.stubImageData(), !image.isEmpty else {
                phase = .error("test: no stub image"); return
            }
            phase = .thinking
            let silent = MockSetup.silentWAV()
            let result = try await backend.ask(
                audioData: silent,
                imageJPEG: image,
                sessionId: AppConfig.sessionId,
                textOverride: "Describe this image in one short spoken sentence."
            )
            transcript = result.transcript ?? ""
            reply = result.reply ?? ""
            print("[TEST] reply: \(reply)")
            print("[TEST] mp3 bytes: \(result.mp3.count)")
            phase = .speaking
            try? await audio.play(mp3: result.mp3)
            phase = .idle
            print("[TEST] DONE — pipeline OK")
        } catch {
            print("[TEST] FAILED: \(error)")
            phase = .error(error.localizedDescription)
        }
    }
    #endif

    func askPressed() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        transcript = ""
        reply = ""
        latencySummary = ""

        do {
            phase = .listening
            try await audio.activateForGlasses()

            // Photo source: glasses when streaming, iPhone otherwise. Audio source
            // is whatever AVAudioSession ended up with (BT route if available, else
            // iPhone built-in mic — both produce a WAV the backend can transcribe).
            let useGlasses = (glasses.status == .streaming)
            captureSource = useGlasses ? "glasses + glasses-mic" : "iPhone camera + iPhone mic"

            async let audioURL: URL = audio.record(seconds: AppConfig.recordSeconds)
            async let photoData: Data = useGlasses
                ? glasses.capturePhoto()
                : iPhoneCapture.capturePhoto()
            let (image, wav) = try await (photoData, audioURL)

            phase = .thinking
            let result = try await backend.ask(
                audioURL: wav,
                imageJPEG: image,
                sessionId: AppConfig.sessionId
            )
            transcript = result.transcript ?? ""
            reply = result.reply ?? ""
            if let stt = result.sttLatency, let llm = result.llmLatency {
                latencySummary = String(format: "stt %.2fs · llm %.2fs", stt, llm)
            }

            phase = .speaking
            try await audio.play(mp3: result.mp3)

            phase = .idle
        } catch {
            phase = .error(error.localizedDescription)
        }

        audio.deactivate()
    }
}
