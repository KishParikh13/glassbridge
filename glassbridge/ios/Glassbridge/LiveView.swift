import SwiftUI
import UIKit
import AVKit
import PhotosUI
import UniformTypeIdentifiers

/// Full-screen capture surface. The viewfinder stays visually present, but the
/// actual camera stream only starts for explicit photo, record, or Ask actions.
struct LiveView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController

    @State private var showSetup = false
    @State private var showResponseSheet = false
    @State private var prompt = ""
    @State private var followUpPrompt = ""
    @State private var stagedMedia: CapturedMedia?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var shutterTask: Task<Void, Never>?
    @State private var shutterPressed = false
    @State private var holdRecordingStarted = false
    @State private var recordProgress: Double = 0
    @State private var recordTimerTask: Task<Void, Never>?
    @State private var recordAutoStopped = false
    @FocusState private var promptFocused: Bool

    private let maxRecordSeconds: Double = 10

    var body: some View {
        NavigationStack {
            ZStack {
                cameraStage
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topChrome
                        .padding(.horizontal, 18)
                        .padding(.top, 10)

                    Spacer()

                    bottomControls
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSetup) {
                SetupView(coordinator: coordinator, glasses: glasses, wake: coordinator.wake)
            }
            .sheet(isPresented: $showResponseSheet) {
                ChatResponseSheet(
                    coordinator: coordinator,
                    prompt: $followUpPrompt,
                    onSend: sendFollowUp
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .task { await coordinator.checkBackend() }
            .onAppear {
                if !coordinator.hasCompletedOnboarding { showSetup = true }
            }
            .onChange(of: coordinator.hasCompletedOnboarding) { _, completed in
                showSetup = !completed
            }
            .onChange(of: coordinator.reply) { _, newValue in
                if !newValue.isEmpty { showResponseSheet = true }
            }
            .onChange(of: coordinator.phase) { _, phase in
                if case .error = phase { showResponseSheet = true }
            }
            .onChange(of: coordinator.capturedMedia.first?.id) { _, _ in
                stagedMedia = coordinator.capturedMedia.first
            }
            .onChange(of: photoPickerItem) { _, item in
                guard let item else { return }
                Task { await handlePickedItem(item) }
            }
        }
    }

    // MARK: - Stage

    private var cameraStage: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.08),
                    Color(red: 0.08, green: 0.13, blue: 0.14),
                    Color(red: 0.01, green: 0.02, blue: 0.025),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(0.18))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: -150, y: -240)

            Circle()
                .fill(Color.orange.opacity(0.14))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 160, y: 170)

            if let stagedMedia {
                CapturedPreview(
                    media: stagedMedia,
                    onCollapse: { self.stagedMedia = nil },
                    onDelete: {
                        coordinator.removeCapturedMedia(stagedMedia)
                        self.stagedMedia = nil
                    }
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 118)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else if (coordinator.showLiveCamera || coordinator.isRecordingVideo), let preview = glasses.previewImage {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    Image(systemName: glasses.canCaptureFromGlasses ? "eyeglasses" : "camera.viewfinder")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(stageTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(stageSubtitle)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 34)
                }
                .padding(.bottom, 100)
            }

            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 270)
            }
        }
    }

    private var stageTitle: String {
        if coordinator.isRecordingVideo { return "Recording" }
        switch coordinator.phase {
        case .listening: return "Listening"
        case .thinking: return "Asking Claude"
        case .speaking: return "Response ready"
        case .error: return "Needs attention"
        case .idle: return glasses.canCaptureFromGlasses ? "Glasses ready" : "iPhone camera ready"
        }
    }

    private var stageSubtitle: String {
        if coordinator.isRecordingVideo { return "Release the shutter to stop recording." }
        if let error = coordinator.captureError, !error.isEmpty { return error }
        switch coordinator.phase {
        case .idle:
            return "Tap for photo, hold for video, or dictate a prompt and send."
        case .listening:
            return "Ask your question, then pause. It stops when you stop."
        case .thinking:
            return "Camera wakes only for this request."
        case .speaking:
            return "The reply is in the sheet."
        case .error(let message):
            return message
        }
    }

    // MARK: - Top Chrome

    private var topChrome: some View {
        HStack(spacing: 10) {
            Button {
                showSetup = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: chipIcon)
                    Text(glasses.connectionState.shortLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.black.opacity(0.35), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showSetup = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.35), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var chipIcon: String {
        switch glasses.connectionState {
        case .streaming, .connected: return "eyeglasses"
        case .usingPhone: return "iphone"
        case .registering, .connecting: return "ellipsis.circle"
        case .needsDeviceUpdate, .needsCameraPermission, .problem, .metaAINotInstalled: return "exclamationmark.triangle.fill"
        case .readyToConnect: return "eyeglasses"
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if !phaseStatus.isEmpty {
                Text(phaseStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            HStack(alignment: .center) {
                liveCameraToggle
                Spacer()
                shutterButton
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            composer
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: composerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: composerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private var composerRadius: CGFloat {
        coordinator.capturedMedia.isEmpty ? 34 : 28
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !coordinator.capturedMedia.isEmpty {
                attachmentStrip
            }
            TextField("", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .lineLimit(1...5)
                .focused($promptFocused)
                .foregroundStyle(.white)
                .tint(.white)
                .onSubmit(sendPrompt)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Ask about what you see")
                            .foregroundStyle(.white.opacity(0.5))
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 10) {
                uploadMenu
                modelMenu
                Spacer()
                Button(action: sendPrompt) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(canSendPrompt ? .white : .white.opacity(0.3))
                }
                .disabled(!canSendPrompt)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(SessionCoordinator.ClaudeModel.allCases) { model in
                Button {
                    coordinator.selectedModel = model
                } label: {
                    if coordinator.selectedModel == model {
                        Label(model.menuLabel, systemImage: "checkmark")
                    } else {
                        Text(model.menuLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                Text(coordinator.selectedModel.label)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.24), in: Capsule())
        }
    }

    // Icon-only attach (direct PhotosPicker — nesting in a Menu fails to present).
    private var uploadMenu: some View {
        PhotosPicker(selection: $photoPickerItem, matching: .any(of: [.images, .videos])) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 34)
        }
        .accessibilityLabel("Attach photo or video")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(coordinator.capturedMedia) { media in
                    AttachmentChip(
                        media: media,
                        onDelete: { coordinator.removeCapturedMedia(media) },
                        onCollapse: { stagedMedia = nil }
                    )
                }
            }
            .padding(.top, 2)
        }
    }

    private var liveCameraToggle: some View {
        Button {
            coordinator.setShowLiveCamera(!coordinator.showLiveCamera)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: coordinator.showLiveCamera ? "video.fill" : "video.slash.fill")
                Text("Show live camera")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(coordinator.showLiveCamera ? .white : .white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                coordinator.showLiveCamera ? Color.white.opacity(0.20) : Color.black.opacity(0.32),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show live camera")
    }

    private var shutterButton: some View {
        ZStack {
            // Snapchat-style elapsed-time ring while recording (fills over maxRecordSeconds).
            if coordinator.isRecordingVideo {
                Circle()
                    .trim(from: 0, to: recordProgress)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 88, height: 88)
                    .animation(.linear(duration: 0.1), value: recordProgress)
            }
            Circle()
                .fill(coordinator.isRecordingVideo ? Color.red : Color.white)
                .frame(width: shutterPressed ? 68 : 74, height: shutterPressed ? 68 : 74)
                .animation(.spring(response: 0.22, dampingFraction: 0.72), value: shutterPressed)
            Circle()
                .strokeBorder(coordinator.isRecordingVideo ? Color.white : Color.black.opacity(0.18), lineWidth: 4)
                .frame(width: 58, height: 58)
            if coordinator.isCapturingPhoto {
                ProgressView()
                    .tint(.black)
            } else if coordinator.isRecordingVideo {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: 88, height: 88)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginShutterPressIfNeeded() }
                .onEnded { _ in endShutterPress() }
        )
        .accessibilityLabel("Capture")
        .accessibilityHint("Tap for photo. Hold to record video (max \(Int(maxRecordSeconds))s).")
    }

    private var canSendPrompt: Bool {
        (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !coordinator.capturedMedia.isEmpty) && !isAsking
    }

    private var isAsking: Bool {
        switch coordinator.phase {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }

    private var phaseStatus: String {
        switch coordinator.phase {
        case .idle: return coordinator.isRecordingVideo ? "Recording video" : ""
        case .listening: return "Listening..."
        case .thinking: return "Sending to Claude..."
        case .speaking: return "Claude replied"
        case .error(let message): return message
        }
    }

    private func beginShutterPressIfNeeded() {
        guard !shutterPressed, !coordinator.isCapturingPhoto else { return }
        shutterPressed = true
        holdRecordingStarted = false
        recordAutoStopped = false
        shutterTask = Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                holdRecordingStarted = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            await coordinator.beginVideoRecording()
            startRecordTimer()
        }
    }

    private func endShutterPress() {
        shutterTask?.cancel()
        shutterTask = nil
        // The 10s timer already stopped the recording — just consume the release.
        if recordAutoStopped {
            recordAutoStopped = false
            shutterPressed = false
            holdRecordingStarted = false
            return
        }
        let shouldStopRecording = holdRecordingStarted
        shutterPressed = false
        holdRecordingStarted = false

        Task {
            if shouldStopRecording {
                recordTimerTask?.cancel()
                recordTimerTask = nil
                recordProgress = 0
                await coordinator.endVideoRecording()
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                await coordinator.takePhotoDirect()
            }
        }
    }

    /// Drives the shutter ring and enforces the max recording length.
    private func startRecordTimer() {
        recordProgress = 0
        recordTimerTask?.cancel()
        recordTimerTask = Task {
            let start = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                recordProgress = min(elapsed / maxRecordSeconds, 1)
                if elapsed >= maxRecordSeconds {
                    recordAutoStopped = true
                    await coordinator.endVideoRecording()
                    recordProgress = 0
                    shutterPressed = false
                    holdRecordingStarted = false
                    break
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            recordTimerTask = nil
        }
    }

    private func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = coordinator.capturedMedia.first
        guard !text.isEmpty || attachment != nil else { return }
        prompt = ""
        followUpPrompt = ""
        promptFocused = false
        showResponseSheet = true
        Task { await coordinator.askTypedPrompt(text, media: attachment) }
    }

    private func sendFollowUp() {
        let text = followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpPrompt = ""
        Task { await coordinator.askTypedPrompt(text) }
    }

    private func handlePickedItem(_ item: PhotosPickerItem) async {
        defer { photoPickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).mov")
            do {
                try data.write(to: url)
                coordinator.attachUploadedVideo(url)
            } catch {
                coordinator.captureError = "Couldn't attach video: \(error.localizedDescription)"
            }
        } else {
            coordinator.attachUploadedPhoto(data)
        }
    }

}

private struct CapturedPreview: View {
    let media: CapturedMedia
    let onCollapse: () -> Void
    let onDelete: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            preview
                .frame(maxWidth: .infinity)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.36), radius: 24, y: 14)

            HStack(spacing: 10) {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash.fill")
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.48), in: Circle())
                }
                Button(action: onCollapse) {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.bold))
                        .frame(width: 42, height: 42)
                        .background(.white, in: Circle())
                        .foregroundStyle(.black)
                }
            }
            .padding(14)
        }
        .task(id: media.id) {
            if !media.isVideo {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                onCollapse()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch media.kind {
        case .photo(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                Color.black.overlay(Text("Couldn't load photo").foregroundStyle(.white.opacity(0.7)))
            }
        case .video(let url):
            VideoAutoPreview(url: url, player: $player, onFinished: onCollapse)
        }
    }
}

private struct VideoAutoPreview: View {
    let url: URL
    @Binding var player: AVPlayer?
    let onFinished: () -> Void

    var body: some View {
        VideoPlayer(player: player)
            .background(Color.black)
            .onAppear {
                let nextPlayer = AVPlayer(url: url)
                player = nextPlayer
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: nextPlayer.currentItem,
                    queue: .main
                ) { _ in
                    onFinished()
                }
                nextPlayer.play()
            }
    }
}

private struct AttachmentChip: View {
    let media: CapturedMedia
    let onDelete: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        thumbnail
            .frame(width: 62, height: 62)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(alignment: .center) {
                if media.isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                }
                .padding(4)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture(perform: onCollapse)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch media.kind {
        case .photo(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.black
            }
        case .video(let url):
            VideoThumbnail(url: url)
        }
    }
}

private struct ChatResponseSheet: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Binding var prompt: String
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !coordinator.transcript.isEmpty {
                            bubble(label: "YOU", text: coordinator.transcript, accent: .blue)
                        }
                        if !coordinator.reply.isEmpty {
                            bubble(label: "CLAUDE", text: coordinator.reply, accent: .green, markdown: true)
                        }
                        if case .error(let message) = coordinator.phase {
                            bubble(label: "ERROR", text: message, accent: .red)
                        }
                        if !coordinator.latencySummary.isEmpty {
                            Text(coordinator.latencySummary)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    TextField("Continue the chat", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(onSend)
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                .padding([.horizontal, .bottom], 16)
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func bubble(label: String, text: String, accent: Color, markdown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(accent)
            Group {
                if markdown,
                   let attributed = try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                } else {
                    Text(text)
                }
            }
            .font(.body)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
