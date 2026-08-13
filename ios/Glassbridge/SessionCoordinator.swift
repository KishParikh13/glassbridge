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

        /// Bare state name for the log. The user-facing `label` has ellipses and copy in
        /// it, which reads badly on a timeline.
        var recordLabel: String {
            switch self {
            case .idle: return "idle"
            case .listening: return "listening"
            case .thinking: return "thinking"
            case .speaking: return "speaking"
            case .error: return "error"
            }
        }
    }

    @Published var phase: Phase = .idle {
        didSet {
            syncLiveActivity()
            // What the listener is armed for follows the phase exactly: "stop" only means
            // something while a reply is playing, the trigger phrase only while idle.
            syncListenerScope()
            recorder.log(.phase, phase.recordLabel)
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
    let recorder = SessionRecorder()
    let agentDirectory = AgentDirectory()
    private var isBusy = false

    /// Which assistant the current turn is for, decided by the wake phrase that started
    /// it. Nil means the backend's default.
    private var currentAgentId: String?

    /// The turn in flight, held so a spoken "never mind" can cancel it.
    private var turnTask: Task<Void, Never>?

    /// A photo capture started mid-question by saying "look". Nil means this turn is
    /// language only, which is now the default: most questions do not need eyes, and a
    /// capture nobody asked for cost latency, tokens, and (with the glasses camera
    /// blocked) killed the whole turn on a 7 second timeout.
    private var photoTask: Task<Data, Error>?

    /// Bumped per turn so a turn that gets barged in on can tell it is no longer current.
    private var turnGeneration = 0

    /// True while a reply is playing or during the follow-up window after it. In this
    /// state just talking starts the next turn: no wake phrase, same conversation.
    @Published private(set) var conversationOpen = false
    private var followUpTimer: Task<Void, Never>?

    /// How long to keep listening after a reply ends.
    private let followUpWindow: TimeInterval = 15

    private lazy var voiceActivity = VoiceActivityDetector { [weak self] in
        self?.speechDetectedWhileOpen()
    }

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
        gblog("[LAUNCH] backend=\(AppConfig.backendURL.absoluteString) mic=\(micPermission) camera=\(cameraPermission) speech=\(speechPermission)")
        if !hasCompletedOnboarding { selectedTab = .setup }
        // "Go to sleep" is meant to stick. The listener comes back exactly as you left it
        // rather than resetting to off, or to on, on every launch.
        if UserDefaults.standard.bool(forKey: wakeWordKey) {
            setWakeWord(true, announce: false)
        }
        // Which agents exist, and what phrase reaches each, is the backend's to decide.
        Task { await refreshAgents() }
        #if DEBUG
        maybeRunAutomatedTestAtLaunch()
        #endif
    }

    /// Ask the backend which assistants exist and arm a trigger phrase for each.
    func refreshAgents() async {
        await agentDirectory.refresh()
        wake.setWakePhrases(agentDirectory.wakePhrases)
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
        gblog("[TEST] auto-test trigger detected (env=\(envHit) arg=\(argHit))")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.runTestAsk()
        }
    }

    func runTestAsk() async {
        guard !isBusy else { return }
        isBusy = true
        // Recorded like a real turn. There is no camera or mic in the simulator, so this
        // is the only way to check the recorder end to end, including the JSON write,
        // without standing in a room wearing the glasses.
        recorder.begin(route: audio.routeSummary())
        var outcome = "completed"
        var stt: Double?
        var llm: Double?
        defer {
            isBusy = false
            recorder.finish(
                outcome: outcome,
                transcript: transcript.isEmpty ? nil : transcript,
                reply: reply.isEmpty ? nil : reply,
                stt: stt,
                llm: llm
            )
        }
        do {
            phase = .listening
            captureSource = "automated test (stub image + silent wav + text_override)"
            guard let image = MockSetup.stubImageData(), !image.isEmpty else {
                outcome = "error: no stub image"
                phase = .error("test: no stub image"); return
            }
            cue(.captured)
            recorder.log(.capture, "stub photo", detail: "\(image.count) bytes")
            phase = .thinking
            let silent = MockSetup.silentWAV()
            let result = try await backend.ask(
                audioData: silent,
                imageJPEG: image,
                sessionId: AppConfig.sessionId,
                textOverride: "Describe this image in one short spoken sentence.",
                model: selectedModel.rawValue.isEmpty ? nil : selectedModel.rawValue,
                agent: currentAgentId
            )
            stt = result.sttLatency
            llm = result.llmLatency
            recorder.log(.backend, "reply", detail: String(
                format: "stt %.2fs · llm %.2fs · %d mp3 bytes",
                result.sttLatency ?? 0, result.llmLatency ?? 0, result.mp3.count
            ))
            transcript = result.transcript ?? ""
            reply = result.reply ?? ""
            gblog("[TEST] reply: \(reply)")
            gblog("[TEST] mp3 bytes: \(result.mp3.count)")
            phase = .speaking
            try? await audio.play(mp3: result.mp3)
            phase = .idle
            gblog("[TEST] DONE — pipeline OK")
        } catch {
            gblog("[TEST] FAILED: \(error)")
            outcome = "error: \(error.localizedDescription)"
            phase = .error(error.localizedDescription)
        }
    }
    #endif

    func askPressed() async {
        await runTurn(presetImage: nil)
    }

    /// One tap that proves capture → agent → voice actually works together. Four separate
    /// green status dots do not tell you the chain holds, and this app fails when things
    /// line up wrong rather than when one part is missing.
    ///
    /// `MockSetup` is `#if DEBUG` only (it imports MWDATMockDevice), so release cannot use
    /// the stub image. It runs a real capture with a fixed prompt instead, which exercises
    /// more of the chain anyway.
    func runSelfTest() async {
        #if DEBUG
        await runTestAsk()
        #else
        await askTypedPrompt("Describe what you can see in one short sentence.")
        #endif
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
    private func runTurn(presetImage: Data?, textOverride: String? = nil,
                         agentId: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        suppressCancelCue = false
        // The detector must not be listening while we record, or the question itself
        // would look like an interruption of its own turn.
        closeConversation(reason: "turn started")
        // Each turn decides for itself whether it needs eyes.
        photoTask?.cancel()
        photoTask = nil

        currentAgentId = agentId
        turnGeneration += 1
        let myGeneration = turnGeneration
        let task = Task { await performAsk(presetImage: presetImage, textOverride: textOverride) }
        turnTask = task
        await task.value

        // A barge-in may have already torn this turn down and started the next one. Only
        // clean up if we are still the current turn, or we would clear the new one's state.
        guard turnGeneration == myGeneration else { return }
        turnTask = nil
        photoTask = nil
        isBusy = false
    }

    // MARK: – Open conversation

    /// Start listening for the user simply talking, rather than for a phrase.
    ///
    /// Runs from the moment a reply starts playing until the follow-up window closes, so
    /// you can talk over the answer or pick it up a few seconds later, either way without
    /// saying the trigger phrase again.
    private func openConversation() {
        followUpTimer?.cancel()
        conversationOpen = true
        voiceActivity.start()
        // gblog, not recorder.log: this window outlives the turn recording, and anything
        // logged after `finish` was being silently dropped — which is how the peak levels
        // this exists to measure went missing.
        gblog("[OPEN] listening (adaptive floor tracking)")
        recorder.log(.turn, "conversation open")
    }

    /// Called when the reply finishes: hold the window open a while before going back to
    /// needing the wake phrase.
    private func startFollowUpCountdown() {
        followUpTimer?.cancel()
        followUpTimer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.followUpWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.closeConversation(reason: "window elapsed")
        }
    }

    private func closeConversation(reason: String) {
        guard conversationOpen else { return }
        followUpTimer?.cancel()
        followUpTimer = nil
        conversationOpen = false
        let levels = voiceActivity.levels
        voiceActivity.stop()
        // The peak is how close the room (and any echo of the reply that survived
        // cancellation) came to the trigger threshold. It is the number to tune against,
        // so it goes to the durable log rather than a turn recording that may be closed.
        // peakWhilePlaying is the echo measurement: if .voiceChat cancellation works it
        // stays near the floor, and that is what makes barge-in safe to be sensitive.
        gblog(String(format: "[OPEN] closed: %@ · peak %.4f · echo %.4f · floor %.4f · trigger %.4f",
                     reason, levels.peak, levels.peakWhilePlaying, levels.floor, levels.trigger))
        recorder.log(.turn, "conversation closed",
                     detail: String(format: "%@ · peak %.4f echo %.4f floor %.4f trigger %.4f",
                                    reason, levels.peak, levels.peakWhilePlaying,
                                    levels.floor, levels.trigger))
    }

    /// Someone started talking while the conversation was open.
    private func speechDetectedWhileOpen() {
        guard conversationOpen else { return }
        recorder.log(.command, "speech while open",
                     detail: String(format: "peak %.4f floor %.4f trigger %.4f",
                                    voiceActivity.levels.peak,
                                    voiceActivity.levels.floor,
                                    voiceActivity.levels.trigger))
        closeConversation(reason: "user spoke")
        cue(.listening)
        // A follow-up belongs to whoever was just talking.
        Task { await startTurnInterrupting(agentId: currentAgentId) }
    }

    /// Start a turn, cutting off whatever is playing first.
    ///
    /// Saying the trigger phrase over a reply means "I have heard enough, here is the next
    /// question". Stopping playback lets the current turn finish on its own terms rather
    /// than unwinding as a cancel, so no error cue fires.
    private func startTurnInterrupting(agentId: String?) async {
        if let current = turnTask {
            audio.stopPlayback()
            _ = await current.value
            // Its own cleanup may not have run yet, and the ordering is not guaranteed.
            // Claim the slot here so the guard in runTurn cannot drop this wake.
            turnTask = nil
            photoTask = nil
            isBusy = false
        }
        await runTurn(presetImage: nil, agentId: agentId)
    }

    private func performAsk(presetImage: Data?, textOverride: String? = nil) async {
        gblog("[ASK] start wakeWord=\(wakeWordEnabled)")
        // The listener deliberately keeps running for the whole turn now. Pausing it here
        // is what used to make a reply impossible to interrupt.
        defer { earcons.stopThinking() }

        recorder.begin(route: audio.routeSummary())
        var outcome = "completed"
        var stt: Double?
        var llm: Double?

        transcript = ""
        reply = ""
        latencySummary = ""

        do {
            if textOverride == nil {
                phase = .listening
                // Warm the camera while the question is still being asked.
                //
                // capturePhoto cold-starts the stream and tears it down again after every
                // shot, so each "look" paid the full spin-up and then had only the
                // remainder of its timeout to actually shoot. That is why it took 5.5s the
                // once it worked and timed out the rest of the time. Starting here gives
                // it the length of the question as a head start, and it costs nothing on
                // turns where "look" is never said: no frame is captured or sent, and
                // stopGlassesIfTransient shuts it down at the end of the turn either way.
                if glasses.canCaptureFromGlasses, !glasses.isStreaming {
                    Task { await glasses.startStreaming() }
                }
                try await audio.activateForGlasses()
                // The route at `begin` is the pre-activation one, which is not the number
                // that matters. Activation is what is supposed to pull the glasses off
                // A2DP (output only) onto a profile that actually carries a microphone.
                recorder.log(.route, "after activation", detail: audio.routeSummary())
                recorder.log(.route, "available inputs", detail: audio.availableInputsSummary())
            }

            let useGlasses = glasses.canCaptureFromGlasses
            let micLabel = useGlasses ? "glasses-mic" : "iPhone mic"
            var image: Data?
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
            } else if let textOverride {
                // Typed asks have no chance to say "look", so they keep the old behavior
                // of attaching whatever the camera sees.
                captureSource = useGlasses ? "glasses + typed" : "iPhone camera + typed"
                image = try await (useGlasses ? glasses.capturePhoto() : iPhoneCapture.capturePhoto())
                cue(.captured)
                transcript = textOverride
                wav = nil
                audioData = Self.silentWAV()
            } else {
                // Language only unless you ask for eyes. `requestLook()` may start a
                // capture while this is still recording.
                captureSource = "\(micLabel), no photo"
                let recorded = try await audio.recordQuestion()
                recorder.log(.recording, "endpointed", detail: Self.wavSummary(recorded))
                wav = recorded
                audioData = nil

                if let photoTask {
                    // Usually already finished: "look" lands mid-sentence and the capture
                    // has been running ever since.
                    //
                    // A photo that never arrives must not destroy the question. The
                    // glasses camera sits right on the timeout boundary (5.5s when it
                    // works, 7s when it gives up), and losing a good question to a slow
                    // shutter is far worse than answering without the picture.
                    do {
                        let captured = try await photoTask.value
                        image = captured
                        cue(.captured)
                        recorder.log(.capture, "photo",
                                     detail: "\(captured.count) bytes · \(captureSource)")
                    } catch {
                        gblog("[CAPTURE] photo failed, answering without it: \(error.localizedDescription)")
                        recorder.log(.capture, "photo failed",
                                     detail: "answering without it · \(error.localizedDescription)")
                        captureSource += " (photo failed)"
                    }
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
                model: selectedModel.rawValue.isEmpty ? nil : selectedModel.rawValue,
                agent: currentAgentId
            )
            earcons.stopThinking()
            try Task.checkCancellation()

            stt = result.sttLatency
            llm = result.llmLatency
            recorder.log(.backend, "reply", detail: String(
                format: "stt %.2fs · llm %.2fs · %d mp3 bytes",
                result.sttLatency ?? 0, result.llmLatency ?? 0, result.mp3.count
            ))

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
            // Listen from the moment it starts talking, so you can cut in mid-sentence.
            openConversation()
            voiceActivity.setPlaying(true)
            try await audio.play(mp3: result.mp3)
            voiceActivity.setPlaying(false)
            // Reply finished on its own. Hold the door open before requiring the phrase.
            if conversationOpen { startFollowUpCountdown() }
            // Cutting playback short resumes the player normally, so the cancel only
            // surfaces here.
            try Task.checkCancellation()

            phase = .idle
        } catch {
            // Whatever went wrong, do not leave the detector holding the mic open.
            closeConversation(reason: "turn ended abnormally")
            if Self.isCancellation(error) {
                gblog("[ASK] cancelled")
                outcome = "cancelled"
                if !suppressCancelCue { cue(.cancelled) }
                phase = .idle
            } else {
                gblog("[ASK] failed: \(error.localizedDescription)")
                outcome = "error: \(error.localizedDescription)"
                cue(.error)
                phase = .error(error.localizedDescription)
            }
        }
        suppressCancelCue = false
        recorder.finish(
            outcome: outcome,
            transcript: transcript.isEmpty ? nil : transcript,
            reply: reply.isEmpty ? nil : reply,
            stt: stt,
            llm: llm
        )

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
            // Direct capture never starts a turn, so this is the only trace it leaves.
            gblog("[CAPTURE] photo failed (glasses=\(useGlasses)): \(error.localizedDescription)")
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
        gblog("[WAKE] set enabled=\(on) · speechPermission=\(speechPermission) · route=\(audio.routeSummary())")
        wakeWordEnabled = on
        UserDefaults.standard.set(on, forKey: wakeWordKey)
        if on {
            wake.onCommand = { [weak self] command in self?.handle(command) }
            // Logged whether or not it fired. A match the scope declined is the whole
            // point of having a scope, and it leaves no other trace.
            wake.onObservation = { [weak self] observation in
                self?.recorder.log(
                    .heard,
                    observation.command.name,
                    detail: observation.transcript,
                    armed: observation.armed,
                    scope: observation.scope.names
                )
            }
            wake.start()
            syncListenerScope()
            if announce { cue(.awake) }
            liveActivity.start(status: "Ready", detail: "Say \u{201C}\(wake.triggerPhrase)\u{201D}")
        } else {
            wake.stop()
            liveActivity.end()
        }
    }

    /// The spoken control surface. Which of these can fire at any given moment is settled
    /// by `syncListenerScope`, so nothing here has to second-guess the phase.
    private func handle(_ command: WakeWordListener.Command) {
        recorder.log(.command, command.name)
        switch command {
        case .wake(let agentId):
            cue(.listening)
            Task { await startTurnInterrupting(agentId: agentId) }
        case .cancel:
            cancelTurn()
        case .stopSpeaking:
            // Resumes the player's continuation, so the turn finishes on its own terms
            // rather than unwinding as a cancel. You asked it to stop talking, not to
            // forget the question.
            audio.stopPlayback()
        case .look:
            requestLook()
        case .sleep:
            cue(.asleep)
            cancelTurn(silent: true)
            setWakeWord(false)
        }
    }

    /// Start a capture for the question being asked right now.
    ///
    /// Runs concurrently with the recording, so saying "look" partway through a sentence
    /// costs nothing: by the time you stop talking the frame is usually already there.
    private func requestLook() {
        guard photoTask == nil else { return }   // one photo per turn
        let tryGlasses = glasses.canCaptureFromGlasses
        captureSource = tryGlasses ? "glasses camera (asked)" : "iPhone camera (asked)"
        recorder.log(.capture, "look requested",
                     detail: tryGlasses
                        ? "glasses · camera permission \(glasses.cameraPermission)"
                        : "iPhone")

        photoTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await tryGlasses
                ? self.glasses.capturePhoto()
                : self.iPhoneCapture.capturePhoto()
        }
    }

    /// Play a cue and note it, so the timeline lines up with what you actually heard.
    private func cue(_ c: Earcons.Cue) {
        earcons.play(c)
        recorder.log(.earcon, String(describing: c))
    }

    /// 16kHz mono 16-bit, so bytes convert straight to seconds. Useful for checking
    /// whether silence endpointing is cutting people off.
    private static func wavSummary(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? Int) ?? 0
        let seconds = Double(bytes) / (16_000 * 2)
        return String(format: "%.2fs · %d bytes", seconds, bytes)
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
        case .listening:
            wake.setScope(.capturing)
        case .thinking:
            wake.setScope(.thinking)
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
