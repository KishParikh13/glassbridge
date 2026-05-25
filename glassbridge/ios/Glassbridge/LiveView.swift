import SwiftUI
import UIKit

/// Home screen: shows the live view (glasses stream or iPhone), with ASK as the
/// primary action plus direct Photo/Record. The capture source is always shown so
/// it's clear whether you're on glasses or the phone.
struct LiveView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @State private var selectedMedia: CapturedMedia?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    sourceChip
                    previewCard
                    askSection
                    captureControls
                    replyArea
                    recentStrip
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .navigationTitle("Glassbridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        coordinator.setWakeWord(!coordinator.wakeWordEnabled)
                    } label: {
                        Image(systemName: coordinator.wakeWordEnabled ? "mic.fill" : "mic")
                            .foregroundStyle(coordinator.wakeWordEnabled ? .red : .secondary)
                    }
                    .accessibilityLabel("Hands-free wake word")
                }
            }
            .sheet(item: $selectedMedia) { media in
                MediaDetailView(media: media) { item in
                    selectedMedia = nil
                    Task { await coordinator.askAboutMedia(item) }
                }
            }
            .task { await coordinator.checkBackend() }
            .onAppear {
                // Bring up the glasses stream if they're connected, so preview +
                // glasses capture are ready without an extra tap.
                if case .connected = glasses.connectionState {
                    Task { await glasses.startStreaming() }
                }
            }
        }
    }

    // MARK: – Source chip

    private var sourceChip: some View {
        Button {
            coordinator.selectedTab = .setup
        } label: {
            HStack(spacing: 8) {
                Image(systemName: chipIcon)
                Text(glasses.connectionState.shortLabel)
                    .fontWeight(.medium)
                Spacer()
                if !glasses.connectionState.isGlassesLive {
                    Text("Setup")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .font(.subheadline)
            .foregroundStyle(chipColor)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(chipColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
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

    private var chipColor: Color {
        switch glasses.connectionState {
        case .streaming: return .green
        case .connected, .readyToConnect, .registering, .connecting: return .blue
        case .usingPhone: return .secondary
        case .needsDeviceUpdate, .needsCameraPermission, .problem, .metaAINotInstalled: return .orange
        }
    }

    // MARK: – Preview

    private var previewCard: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black)
                if glasses.isStreaming, let img = glasses.previewImage {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: glasses.isStreaming ? "dot.radiowaves.left.and.right" : "camera.viewfinder")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(previewHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Glasses-only live toggles. Disabled (with explanation) on iPhone.
            HStack(spacing: 16) {
                Toggle("Live preview", isOn: $glasses.previewEnabled)
                    .toggleStyle(.switch)
                    .disabled(!glasses.isStreaming)
                Toggle("Rolling context", isOn: $glasses.contextCaptureEnabled)
                    .toggleStyle(.switch)
                    .disabled(!glasses.isStreaming)
            }
            .font(.caption)
            if glasses.isStreaming {
                HStack {
                    Text(String(format: "%.0f fps", glasses.measuredFPS))
                    if !glasses.lastFrameSize.isEmpty { Text("· \(glasses.lastFrameSize)") }
                    if glasses.contextCaptureEnabled { Text("· \(glasses.contextFrameCount) ctx") }
                    Spacer()
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var previewHint: String {
        if glasses.isStreaming { return "Waiting for frames…" }
        if glasses.connectionState == .usingPhone {
            return "Using the iPhone camera. Point it at something and tap ASK."
        }
        return "Glasses live preview appears here once connected. Tap the status above to finish setup."
    }

    // MARK: – ASK + capture

    private var askSection: some View {
        VStack(spacing: 8) {
            Button {
                Task { await coordinator.askPressed() }
            } label: {
                ZStack {
                    Circle()
                        .fill(askColor)
                        .frame(width: 132, height: 132)
                        .shadow(color: askColor.opacity(0.4), radius: 12, y: 4)
                    Text("ASK")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(askDisabled)
            .opacity(askDisabled ? 0.85 : 1)
            Text(phaseTitle)
                .font(.subheadline.weight(.semibold))
            if !phaseSubtitle.isEmpty {
                Text(phaseSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var captureControls: some View {
        HStack(spacing: 48) {
            smallCapture(title: "Photo", systemImage: "camera.fill", tint: .blue,
                         disabled: coordinator.isCapturingPhoto || coordinator.isRecordingVideo,
                         busy: coordinator.isCapturingPhoto) {
                Task { await coordinator.takePhotoDirect() }
            }
            smallCapture(title: coordinator.isRecordingVideo ? "Stop" : "Record",
                         systemImage: coordinator.isRecordingVideo ? "stop.fill" : "video.fill",
                         tint: .red,
                         disabled: coordinator.isCapturingPhoto,
                         busy: false) {
                Task { await coordinator.toggleVideoRecording() }
            }
        }
        .overlay(alignment: .bottom) {
            if let err = coordinator.captureError, !err.isEmpty {
                Text(err).font(.caption2).foregroundStyle(.red).padding(.top, 60)
            }
        }
    }

    private func smallCapture(title: String, systemImage: String, tint: Color,
                              disabled: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(tint.opacity(disabled ? 0.4 : 1)).frame(width: 60, height: 60)
                    if busy { ProgressView().tint(.white) }
                    else { Image(systemName: systemImage).font(.system(size: 24, weight: .bold)).foregroundStyle(.white) }
                }
                Text(title).font(.caption2.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: – Reply

    @ViewBuilder
    private var replyArea: some View {
        if !coordinator.transcript.isEmpty || !coordinator.reply.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !coordinator.transcript.isEmpty {
                    bubble(label: "YOU", text: coordinator.transcript, accent: .blue)
                }
                if !coordinator.reply.isEmpty {
                    bubble(label: "CLAUDE", text: coordinator.reply, accent: .purple, markdown: true)
                }
                if !coordinator.latencySummary.isEmpty {
                    Text(coordinator.latencySummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(attributed).font(.body)
                } else {
                    Text(text).font(.body)
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: – Recent captures

    @ViewBuilder
    private var recentStrip: some View {
        if !coordinator.capturedMedia.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", role: .destructive) { coordinator.clearCapturedMedia() }
                        .font(.caption2)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(coordinator.capturedMedia) { media in
                            MediaThumbnail(media: media)
                                .frame(width: 104)
                                .onTapGesture { selectedMedia = media }
                        }
                    }
                }
            }
        }
    }

    // MARK: – Phase derivations

    private var askColor: Color {
        switch coordinator.phase {
        case .idle: return .blue
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .green
        case .error: return .gray
        }
    }
    private var askDisabled: Bool {
        switch coordinator.phase {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }
    private var phaseTitle: String {
        switch coordinator.phase {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        case .error: return "Something went wrong"
        }
    }
    private var phaseSubtitle: String {
        switch coordinator.phase {
        case .idle: return ""
        case .listening: return "Speak for up to 5 seconds"
        case .thinking: return "Sending to Claude with what the camera sees"
        case .speaking: return "Playing Claude's reply"
        case .error(let msg): return msg
        }
    }
}
