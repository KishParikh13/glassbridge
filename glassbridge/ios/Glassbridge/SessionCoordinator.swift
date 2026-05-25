import Foundation
import SwiftUI
import UIKit
import AVFoundation

@MainActor
final class SessionCoordinator: ObservableObject {
    enum Tab: Hashable {
        case live
        case setup
        case more
    }

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

    @Published var phase: Phase = .idle {
        didSet { syncLiveActivity() }
    }
    @Published var transcript: String = ""
    @Published var reply: String = ""
    @Published var latencySummary: String = ""

    let glasses = GlassesController()
    let wake = WakeWordListener()
    private let audio = AudioController()
    private let backend = BackendClient()
    private let iPhoneCapture = IPhoneCapture()
    private let iPhoneVideo = IPhoneVideoRecorder()
    private let liveActivity = LiveActivityController()
    private var isBusy = false

    @Published var wakeWordEnabled = false
    @Published var captureSource: String = "auto"
    @Published var selectedTab: Tab = .live

    // MARK: – Onboarding + permissions + backend (Setup tab)

    private let onboardingKey = "gb.hasCompletedOnboarding"
    @Published var hasCompletedOnboarding: Bool
    @Published var micPermission: PermStatus = .undetermined
    @Published var cameraPermission: PermStatus = .undetermined
    @Published var speechPermission: PermStatus = .undetermined
    @Published var backendHealth: BackendHealth.Result?
    @Published var isCheckingBackend = false

    // MARK: – Camera gallery (direct capture, shown on Live)

    @Published var capturedMedia: [CapturedMedia] = []
    @Published var isCapturingPhoto = false
    @Published var isRecordingVideo = false
    @Published var captureError: String?
    private var recordingSource: CapturedMedia.Source = .iPhone

    /// True when glasses are live; otherwise capture falls back to the iPhone.
    var cameraUsesGlasses: Bool { glasses.isStreaming }

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "gb.hasCompletedOnboarding")
        glasses.start()
        refreshPermissionStatuses()
        if !hasCompletedOnboarding { selectedTab = .setup }
        #if DEBUG
        maybeRunAutomatedTestAtLaunch()
        #endif
    }

    // MARK: – Onboarding / permissions / backend

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
        selectedTab = .live
    }

    func restartOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: onboardingKey)
        selectedTab = .setup
    }

    func refreshPermissionStatuses() {
        micPermission = PermissionsService.microphoneStatus()
        cameraPermission = PermissionsService.cameraStatus()
        speechPermission = PermissionsService.speechStatus()
    }

    func requestMic() async { micPermission = await PermissionsService.requestMicrophone() }
    func requestCamera() async { cameraPermission = await PermissionsService.requestCamera() }
    func requestSpeech() async { speechPermission = await PermissionsService.requestSpeech() }

    func checkBackend() async {
        isCheckingBackend = true
        defer { isCheckingBackend = false }
        backendHealth = await BackendHealth.check()
    }

    /// The single source of truth for "what works and what it's connected to."
    func capabilities() -> [Capability] {
        Capability.all(
            connection: glasses.connectionState,
            micGranted: micPermission.isGranted,
            cameraGranted: cameraPermission.isGranted,
            speechGranted: speechPermission.isGranted,
            backendReachable: backendHealth?.reachable ?? false
        )
    }

    #if DEBUG
    /// When launched with GB_AUTO_TEST=1 (or --gb-auto-test), fire a self-contained
    /// test ASK using a stub image + silent wav + text_override (bypasses Whisper).
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
        await performAsk(presetImage: nil)
    }

    /// Run the ASK pipeline using a still already in the gallery instead of a fresh
    /// capture. Switches to the Live tab so transcript/reply are visible.
    func askAboutMedia(_ media: CapturedMedia) async {
        selectedTab = .live
        guard let image = await Self.imageJPEG(from: media) else {
            phase = .error("Couldn't get an image from that item.")
            return
        }
        await performAsk(presetImage: image)
    }

    private func performAsk(presetImage: Data?) async {
        guard !isBusy else { return }
        isBusy = true
        if wakeWordEnabled { wake.pause() }
        defer {
            isBusy = false
            if wakeWordEnabled { wake.resume() }
        }

        transcript = ""
        reply = ""
        latencySummary = ""

        do {
            phase = .listening
            try await audio.activateForGlasses()

            let useGlasses = glasses.isStreaming
            let micLabel = useGlasses ? "glasses-mic" : "iPhone mic"
            let image: Data
            let wav: URL
            if let presetImage {
                captureSource = "captured media + \(micLabel)"
                image = presetImage
                wav = try await audio.record(seconds: AppConfig.recordSeconds)
            } else {
                captureSource = useGlasses ? "glasses + glasses-mic" : "iPhone camera + iPhone mic"
                async let audioURL: URL = audio.record(seconds: AppConfig.recordSeconds)
                async let photoData: Data = useGlasses
                    ? glasses.capturePhoto()
                    : iPhoneCapture.capturePhoto()
                let (img, recorded) = try await (photoData, audioURL)
                image = img
                wav = recorded
            }

            let contextFrames: [Data] = (presetImage == nil && useGlasses && glasses.contextCaptureEnabled)
                ? glasses.recentContextFrames()
                : []

            phase = .thinking
            let result = try await backend.ask(
                audioURL: wav,
                imageJPEG: image,
                contextFramesJPEG: contextFrames,
                sessionId: AppConfig.sessionId
            )
            transcript = result.transcript ?? ""
            reply = result.reply ?? ""
            var summary = ""
            if let stt = result.sttLatency, let llm = result.llmLatency {
                summary = String(format: "stt %.2fs · llm %.2fs", stt, llm)
            }
            if !contextFrames.isEmpty {
                summary += summary.isEmpty ? "" : " · "
                summary += "\(contextFrames.count) ctx frames"
            }
            if let tools = result.tools, !tools.isEmpty {
                summary += summary.isEmpty ? "" : " · "
                summary += "tools: \(tools)"
            }
            latencySummary = summary

            phase = .speaking
            try await audio.play(mp3: result.mp3)

            phase = .idle
        } catch {
            phase = .error(error.localizedDescription)
        }

        audio.deactivate()
    }

    // MARK: – Direct camera control

    func takePhotoDirect() async {
        guard !isCapturingPhoto, !isRecordingVideo else { return }
        isCapturingPhoto = true
        captureError = nil
        defer { isCapturingPhoto = false }

        let useGlasses = cameraUsesGlasses
        do {
            let data: Data
            if useGlasses {
                data = try await glasses.capturePhoto()
            } else {
                data = try await iPhoneCapture.capturePhoto()
            }
            capturedMedia.insert(
                CapturedMedia(kind: .photo(data),
                              source: useGlasses ? .glasses : .iPhone,
                              date: Date()),
                at: 0)
        } catch {
            captureError = error.localizedDescription
        }
    }

    func toggleVideoRecording() async {
        if isRecordingVideo {
            await stopVideoRecording()
        } else {
            await startVideoRecording()
        }
    }

    private func startVideoRecording() async {
        guard !isCapturingPhoto, !isRecordingVideo else { return }
        captureError = nil
        let useGlasses = cameraUsesGlasses
        do {
            if useGlasses {
                try glasses.startVideoRecording()
            } else {
                try await iPhoneVideo.start()
            }
            recordingSource = useGlasses ? .glasses : .iPhone
            isRecordingVideo = true
        } catch {
            captureError = error.localizedDescription
        }
    }

    private func stopVideoRecording() async {
        isRecordingVideo = false
        do {
            let url: URL
            switch recordingSource {
            case .glasses: url = try await glasses.stopVideoRecording()
            case .iPhone:  url = try await iPhoneVideo.stop()
            }
            capturedMedia.insert(
                CapturedMedia(kind: .video(url), source: recordingSource, date: Date()),
                at: 0)
        } catch {
            captureError = error.localizedDescription
        }
    }

    func clearCapturedMedia() {
        for url in capturedMedia.compactMap(\.videoURL) {
            try? FileManager.default.removeItem(at: url)
        }
        capturedMedia.removeAll()
    }

    // MARK: – Hands-free (wake word + Live Activity)

    func setWakeWord(_ on: Bool) {
        wakeWordEnabled = on
        if on {
            wake.onWake = { [weak self] in
                Task { await self?.askPressed() }
            }
            wake.start()
            liveActivity.start(status: "Ready", detail: "Say \u{201C}\(wake.triggerPhrase)\u{201D}")
        } else {
            wake.stop()
            liveActivity.end()
        }
    }

    private func syncLiveActivity() {
        guard wakeWordEnabled else { return }
        let status: String
        switch phase {
        case .idle: status = "Ready"
        case .listening: status = "Listening"
        case .thinking: status = "Thinking"
        case .speaking: status = "Speaking"
        case .error: status = "Error"
        }
        let detail: String
        switch phase {
        case .idle: detail = "Say \u{201C}\(wake.triggerPhrase)\u{201D}"
        case .error(let msg): detail = msg
        default: detail = ""
        }
        liveActivity.update(status: status, detail: detail)
    }

    // MARK: – Debug / diagnostics (audio + general), surfaced under More → Advanced

    @Published var audioRoute: String = ""
    @Published var availableInputs: String = ""
    @Published var micLevel: Float = 0
    @Published var isMonitoringMic = false
    @Published var isAudioBusy = false
    @Published var diagLog: [String] = []

    private func diag(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(8)
        diagLog.append("\(stamp) \(s)")
        if diagLog.count > 40 { diagLog.removeFirst(diagLog.count - 40) }
    }

    func clearDiagLog() { diagLog.removeAll() }

    func refreshAudioRoute() {
        audioRoute = audio.routeSummary()
        availableInputs = audio.availableInputsSummary()
    }

    func activateAudioRoute() async {
        do {
            try await audio.activateForGlasses()
            diag("audio route activated")
        } catch {
            diag("activate failed: \(error.localizedDescription)")
        }
        refreshAudioRoute()
    }

    func deactivateAudioRoute() {
        audio.deactivate()
        diag("audio route deactivated")
        refreshAudioRoute()
    }

    func runMicLoopback(seconds: Double) async {
        guard !isAudioBusy, !isMonitoringMic else { return }
        isAudioBusy = true
        defer { isAudioBusy = false }
        do {
            try await audio.activateForGlasses()
            refreshAudioRoute()
            diag("loopback: recording \(Int(seconds))s")
            let url = try await audio.record(seconds: seconds)
            let bytes = (try? Data(contentsOf: url).count) ?? 0
            diag("loopback: \(bytes) bytes — playing back")
            try await audio.play(fileURL: url)
            diag("loopback: done")
        } catch {
            diag("loopback failed: \(error.localizedDescription)")
        }
        audio.deactivate()
    }

    func playSpeakerTone() async {
        guard !isAudioBusy, !isMonitoringMic else { return }
        isAudioBusy = true
        defer { isAudioBusy = false }
        do {
            try await audio.activateForGlasses()
            refreshAudioRoute()
            diag("tone: 880Hz 1s")
            try await audio.playTestTone()
            diag("tone: done")
        } catch {
            diag("tone failed: \(error.localizedDescription)")
        }
        audio.deactivate()
    }

    func toggleMicMeter() async {
        if isMonitoringMic {
            stopMicMeter()
        } else {
            await startMicMeter()
        }
    }

    private func startMicMeter() async {
        guard !isAudioBusy, !isMonitoringMic else { return }
        do {
            try await audio.activateForGlasses()
            refreshAudioRoute()
            try audio.startMicMonitor()
            isMonitoringMic = true
            diag("mic meter: started")
            while isMonitoringMic {
                micLevel = audio.micLevel()
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        } catch {
            diag("mic meter failed: \(error.localizedDescription)")
            isMonitoringMic = false
        }
    }

    private func stopMicMeter() {
        isMonitoringMic = false
        audio.stopMicMonitor()
        audio.deactivate()
        micLevel = 0
        diag("mic meter: stopped")
    }

    /// Resolve a JPEG to send to Claude: a photo's own bytes, or a mid-clip frame
    /// extracted from a video.
    private static func imageJPEG(from media: CapturedMedia) async -> Data? {
        switch media.kind {
        case .photo(let data):
            return data
        case .video(let url):
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { return nil }
            return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.7)
        }
    }
}
