import SwiftUI
import UIKit
import AVKit

/// Direct glasses control, separate from the ASK/AI flow: take a photo or record
/// video on demand and see the result load straight into an in-app gallery.
struct CameraView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @State private var selected: CapturedMedia?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                sourceChip
                previewSection
                qualityControls
                controls
                if let err = coordinator.captureError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                gallery
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !coordinator.capturedMedia.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            coordinator.clearCapturedMedia()
                        }
                    }
                }
            }
            .sheet(item: $selected) { media in
                MediaDetailView(media: media) { item in
                    selected = nil
                    Task { await coordinator.askAboutMedia(item) }
                }
            }
        }
    }

    // MARK: – Pieces

    private var previewSection: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black)
                if let img = glasses.previewImage {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: glasses.previewEnabled ? "dot.radiowaves.left.and.right" : "eye.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(previewHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Toggle("Live preview", isOn: $glasses.previewEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .disabled(glasses.status != .streaming)
                Spacer()
                if glasses.status == .streaming {
                    Text(String(format: "%.0f fps", glasses.measuredFPS))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !glasses.lastFrameSize.isEmpty {
                        Text(glasses.lastFrameSize)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Toggle("Rolling context", isOn: $glasses.contextCaptureEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .disabled(glasses.status != .streaming)
                Spacer()
                if glasses.contextCaptureEnabled {
                    Text("\(glasses.contextFrameCount) frames")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var previewHint: String {
        if glasses.status != .streaming {
            return "Live frames appear here once the glasses are streaming."
        }
        return glasses.previewEnabled ? "Waiting for frames…" : "Toggle Live preview to see the feed."
    }

    private var qualityControls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(GlassesController.Quality.allCases, id: \.self) { q in
                    Button(q.label) {
                        glasses.applyStreamSettings(quality: q, frameRate: glasses.frameRate)
                    }
                }
            } label: {
                Label(glasses.quality.label, systemImage: "rectangle.3.group")
            }
            Spacer()
            Menu {
                ForEach(GlassesController.frameRateOptions, id: \.self) { f in
                    Button("\(f) fps") {
                        glasses.applyStreamSettings(quality: glasses.quality, frameRate: f)
                    }
                }
            } label: {
                Label("\(glasses.frameRate) fps", systemImage: "speedometer")
            }
        }
        .font(.caption)
        .disabled(glasses.deviceId == nil)
    }

    private var sourceChip: some View {
        HStack(spacing: 6) {
            Image(systemName: coordinator.cameraUsesGlasses ? "eyeglasses" : "iphone")
            Text(coordinator.cameraUsesGlasses ? "Ray-Ban glasses" : "iPhone camera")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Capsule().fill(.secondary.opacity(0.12)))
    }

    private var controls: some View {
        HStack(spacing: 40) {
            captureButton(
                title: "Photo",
                systemImage: "camera.fill",
                tint: .blue,
                disabled: coordinator.isCapturingPhoto || coordinator.isRecordingVideo,
                busy: coordinator.isCapturingPhoto
            ) {
                Task { await coordinator.takePhotoDirect() }
            }

            captureButton(
                title: coordinator.isRecordingVideo ? "Stop" : "Record",
                systemImage: coordinator.isRecordingVideo ? "stop.fill" : "video.fill",
                tint: .red,
                disabled: coordinator.isCapturingPhoto,
                busy: false
            ) {
                Task { await coordinator.toggleVideoRecording() }
            }
        }
        .padding(.vertical, 8)
    }

    private func captureButton(title: String, systemImage: String, tint: Color,
                               disabled: Bool, busy: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(disabled ? 0.4 : 1.0))
                        .frame(width: 88, height: 88)
                        .shadow(color: tint.opacity(0.35), radius: 10, y: 3)
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    @ViewBuilder
    private var gallery: some View {
        if coordinator.capturedMedia.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Tap Photo or Record to capture from your glasses.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(coordinator.capturedMedia) { media in
                        MediaThumbnail(media: media)
                            .onTapGesture { selected = media }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// A single gallery cell: photo bitmap or video thumbnail with a play badge.
private struct MediaThumbnail: View {
    let media: CapturedMedia

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if media.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            Text(media.source.rawValue)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(5)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch media.kind {
        case .photo(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        case .video(let url):
            VideoThumbnail(url: url)
        }
    }

    private var placeholder: some View {
        Rectangle().fill(.secondary.opacity(0.15))
    }
}

/// Generates a first-frame thumbnail for a recorded video file.
private struct VideoThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.secondary.opacity(0.15))
            }
        }
        .task(id: url) {
            image = await Self.makeThumbnail(url)
        }
    }

    private static func makeThumbnail(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

/// Full-screen viewer: zoomable photo or an inline video player, plus a hand-off
/// to the Claude ASK pipeline ("Ask about this").
private struct MediaDetailView: View {
    let media: CapturedMedia
    let onAsk: (CapturedMedia) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch media.kind {
                    case .photo(let data):
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.black)
                        } else {
                            Text("Couldn't load image.").foregroundStyle(.secondary)
                        }
                    case .video(let url):
                        VideoPlayer(player: AVPlayer(url: url))
                    }
                }

                Button {
                    onAsk(media)
                } label: {
                    Label(media.isVideo ? "Ask Claude about this clip" : "Ask Claude about this",
                          systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(16)
            }
            .navigationTitle("\(media.source.rawValue) · \(media.isVideo ? "Video" : "Photo")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
