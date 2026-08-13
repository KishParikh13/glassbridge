import SwiftUI
import UIKit
import AVKit

/// A single gallery cell: photo bitmap or video thumbnail with a play badge and a
/// source tag (Glasses / iPhone).
struct MediaThumbnail: View {
    let media: CapturedMedia

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
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
                Rectangle().fill(.secondary.opacity(0.15))
            }
        case .video(let url):
            VideoThumbnail(url: url)
        }
    }
}

/// Generates a first-frame thumbnail for a recorded video file.
struct VideoThumbnail: View {
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

/// Full-screen viewer: zoomable photo or inline video player, plus a hand-off to
/// the Claude ASK pipeline ("Ask about this").
struct MediaDetailView: View {
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
