import Foundation
import SwiftUI
import UIKit
import AVFoundation

@MainActor
final class SessionCoordinator: ObservableObject {
    enum ClaudeModel: String, CaseIterable, Identifiable {
        case opus47 = "claude-opus-4-7"
        case sonnet46 = "claude-sonnet-4-6"
        case haiku45 = "claude-haiku-4-5-20251001"

        /// The model used when the user hasn't picked one — matches the backend's
        /// configured default (`anthropic_model` in config.py).
        static let `default`: ClaudeModel = .sonnet46

        var id: String { rawValue }

        var label: String {
            switch self {
            case .opus47: return "Opus 4.7"
            case .sonnet46: return "Sonnet 4.6"
            case .haiku45: return "Haiku 4.5"
            }
        }

        /// Label shown in the picker menu, marking which model is the default.
        var menuLabel: String { self == .default ? "\(label) (Default)" : label }
    }

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
        didSet {
            syncLiveActivity()
            // What the listener is armed for follows the phase exactly: "stop" only means
            // something while a reply is playing, the trigger phrase only while idle.
            syncListenerScope()
        }
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
    private let earcons = Earcons()
    private var isBusy = false

    /// The turn in flight, held so a spoken "never mind" can cancel it.
    private var turnTask: Task<Void, Never>?

    @Published var wakeWordEnabled = false
    @Published var captureSource: String = "auto"
    @Published var selectedTab: Tab = .live
    @Published var selectedModel: ClaudeModel = .default

    /// When on, the glasses keep streaming and the live feed is shown in the stage.
    /// Off by default — otherwise the camera only wakes for a capture/ask.
    @Published var showLiveCamera = false

    func setShowLiveCamera(_ on: Bool) {
        showLiveCamera = on
        glasses.previewEnabled = on
        if on {
            Task { await glasses.startStreaming() }
        } else if !isRecordingVideo {
            glasses.stopStreaming()
        }
    }

    /// Turn the glasses camera back off after a one-off action, unless the user
    /// asked to keep the live feed on (or a recording is still in progress).
    private func stopGlassesIfTransient() {
        if !showLiveCamera && !isRecordingVideo { glasses.stopStreaming() }
    }

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

    /// True when glasses can be used for an on-demand camera action.
    var cameraUsesGlasses: Bool { glasses.canCaptureFromGlasses }

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "gb.hasCompletedOnboarding")
        glasses.start()
        refreshPermissionStatuses()
        if !hasCompletedOnboarding { selectedTab = .setup }
        // "Go to sleep" is meant to stick. The listener comes back exactly as you left it
        // rather than resetting to off, or to on, on every launch.
        if UserDefaults.standard.bool(forKey: wakeWordKey) {
            setWakeWord(true, announce: false)
        }
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
                textOverride: "Describe this image in one short spoken sentence.",
                model: selectedModel.rawValue.isEmpty ? nil : selectedModel.rawValue
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
        await runTurn(presetImage: nil)
    }

    func askTypedPrompt(_ prompt: String, presetImage: Data? = nil) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runTurn(presetImage: presetImage, textOverride: trimmed)
    }

    func askTypedPrompt(_ prompt: String, media: CapturedMedia?) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || media != nil else { return }
        let image = media == nil ? nil : await Self.imageJPEG(from: media!)
        await runTurn(presetImage: image, textOverride: trimmed.isEmpty ? "Describe this." : trimmed)
    }

    /// Run the ASK pipeline using a still already in the gallery instead of a fresh
    /// capture. Switches to the Live tab so transcript/reply are visible.
    func askAboutMedia(_ media: CapturedMedia) async {
        selectedTab = .live
        guard let image = await Self.imageJPEG(from: media) else {
            phase = .error("Couldn't get an image from that item.")
            return
        }
        await runTurn(presetImage: image)
    }

    /// Every entry point comes through here, so there is exactly one turn in flight and
    /// exactly one handle on it for a spoken "never mind" to cancel.
    private func runTurn(presetImage: Data?, textOverride: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        suppressCancelCue = false
        let task = Task { await performAsk(presetImage: presetImage, textOverride: textOverride) }
        turnTask = task
        await task.value
        turnTask = nil
        isBusy = false
    }

    private func performAsk(presetImage: Data?, textOverride: String? = nil) async {
        print("[ASK] start wakeWord=\(wakeWordEnabled)")
        // The listener deliberately keeps running for the whole turn now. Pausing it here
        // is what used to make a reply impossible to interrupt.
        defer { earcons.stopThinking() }

        transcript = ""
        reply = ""
        latencySummary = ""

        do {
            if textOverride == nil {
                phase = .listening
                try await audio.activateForGlasses()
            }

            let useGlasses = glasses.canCaptureFromGlasses
            let micLabel = useGlasses ? "glasses-mic" : "iPhone mic"
            let image: Data
            let wav: URL?
            let audioData: Data?
            if let presetImage {
                captureSource = "captured media + \(micLabel)"
                image = presetImage
                if textOverride == nil {
                    wav = try await audio.recordQuestion()
                    audioData = nil
                } else {
                    wav = nil
                    audioData = Self.silentWAV()
                }
            } else {
                captureSource = useGlasses ? "glasses + \(micLabel)" : "iPhone camera + iPhone mic"
                if let textOverride {
                    image = try await (useGlasses ? glasses.capturePhoto() : iPhoneCapture.capturePhoto())
                    earcons.play(.captured)
                    transcript = textOverride
                    wav = nil
                    audioData = Self.silentWAV()
                } else {
                    async let audioURL: URL = audio.recordQuestion()
                    async let photoData: Data = useGlasses
                        ? glasses.capturePhoto()
                        : iPhoneCapture.capturePhoto()
                    // Click the moment the frame lands, not when the whole turn's IO
                    // settles. This is the cue that tells you to stop holding the thing up
                    // to the light, so it is worth nothing if it waits for the recording
                    // to endpoint first.
                    image = try await photoData
                    earcons.play(.captured)
                    wav = try await audioURL
                    audioData = nil
                }
            }

            try Task.checkCancellation()

            phase = .thinking
            earcons.startThinking()
            let result = try await backend.ask(
                audioURL: wav,
                audioData: audioData,
                imageJPEG: image,
                contextFramesJPEG: [],
                sessionId: AppConfig.sessionId,
                textOverride: textOverride,
                model: selectedModel.rawValue.isEmpty ? nil : selectedModel.rawValue
            )
            earcons.stopThinking()
            try Task.checkCancellation()

            transcript = result.transcript ?? ""
            reply = result.reply ?? ""
            var summary = ""
            if let stt = result.sttLatency, let llm = result.llmLatency {
                summary = String(format: "stt %.2fs · llm %.2fs", stt, llm)
            }
            if let tools = result.tools, !tools.isEmpty {
                summary += summary.isEmpty ? "" : " · "
                summary += "tools: \(tools)"
            }
            latencySummary = summary

            phase = .speaking
            try await audio.play(mp3: result.mp3)
            // Cutting playback short resumes the player normally, so the cancel only
            // surfaces here.
            try Task.checkCancellation()

            phase = .idle
        } catch {
            if Self.isCancellation(error) {
                print("[ASK] cancelled")
                if !suppressCancelCue { earcons.play(.cancelled) }
                phase = .idle
            } else {
                print("[ASK] failed: \(error.localizedDescription)")
                earcons.play(.error)
                phase = .error(error.localizedDescription)
            }
        }
        suppressCancelCue = false

        // The session deliberately stays active between asks. Tearing it down here is what
        // used to cut off the wake word listener and make a follow-up impossible.
        stopGlassesIfTransient()
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
            stopGlassesIfTransient()
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

    func beginVideoRecording() async {
        await startVideoRecording()
    }

    func endVideoRecording() async {
        await stopVideoRecording()
    }

    private func startVideoRecording() async {
        guard !isCapturingPhoto, !isRecordingVideo else { return }
        captureError = nil
        let useGlasses = cameraUsesGlasses
        do {
            if useGlasses {
                try await glasses.startVideoRecording()
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
            case .upload:
                throw NSError(domain: "SessionCoordinator", code: 31,
                              userInfo: [NSLocalizedDescriptionKey: "No upload recording is active."])
            }
            capturedMedia.insert(
                CapturedMedia(kind: .video(url), source: recordingSource, date: Date()),
                at: 0)
            stopGlassesIfTransient()
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

    func removeCapturedMedia(_ media: CapturedMedia) {
        if let url = media.videoURL {
            try? FileManager.default.removeItem(at: url)
        }
        capturedMedia.removeAll { $0.id == media.id }
    }

    func attachUploadedPhoto(_ data: Data) {
        // Library/HEIC photos are often 5–8 MB — over Anthropic's 5 MB inline cap.
        // Downsize (and transcode HEIC → JPEG) before attaching.
        let prepared = Self.downsizedJPEG(data) ?? data
        capturedMedia.insert(CapturedMedia(kind: .photo(prepared), source: .upload, date: Date()), at: 0)
    }

    private static func downsizedJPEG(_ data: Data, maxDim: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDim ? maxDim / longEdge : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    func attachUploadedVideo(_ url: URL) {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            capturedMedia.insert(CapturedMedia(kind: .video(target), source: .upload, date: Date()), at: 0)
        } catch {
            captureError = "Couldn't attach video: \(error.localizedDescription)"
        }
    }

    // MARK: – Hands-free (wake word + voice control + Live Activity)

    private let wakeWordKey = "gb.wakeWordEnabled"

    /// Set once when a turn is cancelled by something that has its own closing sound, so
    /// "go to sleep" mid-reply does not stack the cancel cue on top of the sleep cue.
    private var suppressCancelCue = false

    func setWakeWord(_ on: Bool, announce: Bool = true) {
        wakeWordEnabled = on
        UserDefaults.standard.set(on, forKey: wakeWordKey)
        if on {
            wake.onCommand = { [weak self] command in self?.handle(command) }
            wake.start()
            syncListenerScope()
            if announce { earcons.play(.awake) }
            liveActivity.start(status: "Ready", detail: "Say \u{201C}\(wake.triggerPhrase)\u{201D}")
        } else {
            wake.stop()
            liveActivity.end()
        }
    }

    /// The spoken control surface. Which of these can fire at any given moment is settled
    /// by `syncListenerScope`, so nothing here has to second-guess the phase.
    private func handle(_ command: WakeWordListener.Command) {
        switch command {
        case .wake:
            earcons.play(.listening)
            Task { await runTurn(presetImage: nil) }
        case .cancel:
            cancelTurn()
        case .stopSpeaking:
            // Resumes the player's continuation, so the turn finishes on its own terms
            // rather than unwinding as a cancel. You asked it to stop talking, not to
            // forget the question.
            audio.stopPlayback()
        case .sleep:
            earcons.play(.asleep)
            cancelTurn(silent: true)
            setWakeWord(false)
        }
    }

    /// Drop the turn in flight. A false trigger captures first and this is how you take it
    /// back, which is the whole reason the capture click has to be audible.
    func cancelTurn(silent: Bool = false) {
        guard let turnTask else { return }
        suppressCancelCue = silent
        turnTask.cancel()
    }

    /// The listener is armed for exactly what makes sense right now: the trigger phrase
    /// only while idle, so a question cannot open a second turn, and "stop" only while a
    /// reply is playing, so asking whether you should stop taking something does not cut
    /// itself off.
    private func syncListenerScope() {
        guard wakeWordEnabled else { return }
        switch phase {
        case .idle, .error:
            wake.setScope(.idle)
        case .listening, .thinking:
            wake.setScope(.capturing)
        case .speaking:
            wake.setScope(.speaking)
        }
    }

    /// A dropped turn is not a failure, and it arrives wearing a different coat depending
    /// on which await was in flight when the cancel landed.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let recorder = error as? MicRecorder.RecorderError, case .cancelled = recorder { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
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
        AudioSessionController.shared.deactivate()
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

    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let samples: UInt32 = sampleRate
        let dataBytes: UInt32 = samples * 2
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndianUInt32: 36 + dataBytes)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndianUInt32: 16)
        data.append(littleEndianUInt16: 1)
        data.append(littleEndianUInt16: 1)
        data.append(littleEndianUInt32: sampleRate)
        data.append(littleEndianUInt32: sampleRate * 2)
        data.append(littleEndianUInt16: 2)
        data.append(littleEndianUInt16: 16)
        data.append("data".data(using: .ascii)!)
        data.append(littleEndianUInt32: dataBytes)
        data.append(Data(count: Int(dataBytes)))
        return data
    }
}

private extension Data {
    mutating func append(littleEndianUInt16 value: UInt16) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func append(littleEndianUInt32 value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
