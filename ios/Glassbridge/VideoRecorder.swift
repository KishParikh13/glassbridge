import Foundation
import AVFoundation
import CoreMedia

/// Encodes a stream of raw `CMSampleBuffer`s (from the glasses' videoFramePublisher)
/// into an H.264 .mp4 on disk via AVAssetWriter. All mutable state is confined to a
/// serial queue so it's safe to feed from the SDK's publisher thread.
final class VideoRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kish.glassbridge.videorecorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var recording = false
    private var outputURL: URL?

    /// Begin a new recording. Frames fed via `append` are written until `finish()`.
    func start() {
        queue.async {
            guard !self.recording else { return }
            self.recording = true
            self.sessionStarted = false
            self.writer = nil
            self.input = nil
            self.outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("glasses-\(UUID().uuidString).mp4")
        }
    }

    /// Feed one frame. No-op unless a recording is in progress. The first frame
    /// lazily configures the writer (dimensions are read from the frame itself).
    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.recording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
            if self.writer == nil, !self.setupWriter(with: sampleBuffer) { return }
            guard let writer = self.writer, let input = self.input,
                  writer.status == .writing else { return }
            if !self.sessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                self.sessionStarted = true
            }
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    /// Finish writing and return the file URL, or nil if nothing usable was captured.
    func finish() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async {
                guard self.recording else { cont.resume(returning: nil); return }
                self.recording = false
                guard let writer = self.writer, let input = self.input, self.sessionStarted else {
                    self.writer = nil; self.input = nil
                    cont.resume(returning: nil)
                    return
                }
                let url = self.outputURL
                input.markAsFinished()
                writer.finishWriting {
                    let ok = writer.status == .completed
                    self.writer = nil
                    self.input = nil
                    self.sessionStarted = false
                    cont.resume(returning: ok ? url : nil)
                }
            }
        }
    }

    /// Must be called on `queue`. Configures the writer from the first frame's dimensions.
    private func setupWriter(with sampleBuffer: CMSampleBuffer) -> Bool {
        guard let url = outputURL,
              let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height),
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else { return false }
            self.writer = writer
            self.input = input
            return true
        } catch {
            return false
        }
    }
}
