import AVFoundation
import UIKit

/// Single-shot photo capture from the iPhone rear camera using AVCaptureSession.
/// Used as a fallback when the DAT/glasses stream isn't available.
final class IPhoneCapture: NSObject {
    enum CaptureError: LocalizedError {
        case noCamera
        case sessionFailed(String)
        case captureFailed(String)
        case dataMissing

        var errorDescription: String? {
            switch self {
            case .noCamera: return "iPhone has no rear camera available."
            case .sessionFailed(let m): return "Camera session: \(m)"
            case .captureFailed(let m): return "Photo capture: \(m)"
            case .dataMissing: return "Captured photo had no data."
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<Data, Error>?

    /// Capture one JPEG from the rear camera. Spins up the session per call (a few
    /// hundred ms) — simpler than keeping it warm, and we only ASK every few seconds.
    func capturePhoto() async throws -> Data {
        try await prepareSessionIfNeeded()

        if !session.isRunning {
            session.startRunning()
            // Give the camera a moment to expose.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        defer {
            if session.isRunning { session.stopRunning() }
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let settings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.jpeg
            ])
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func prepareSessionIfNeeded() async throws {
        if session.inputs.isEmpty {
            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            ) else {
                throw CaptureError.noCamera
            }
            let input: AVCaptureDeviceInput
            do { input = try AVCaptureDeviceInput(device: device) }
            catch { throw CaptureError.sessionFailed(error.localizedDescription) }

            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CaptureError.sessionFailed("canAddInput=false")
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CaptureError.sessionFailed("canAddOutput=false")
            }
            session.addOutput(output)
            session.commitConfiguration()
        }

        // Ensure camera permission.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CaptureError.sessionFailed("camera permission denied by user") }
        default:
            throw CaptureError.sessionFailed("iOS camera permission denied. Settings > Glassbridge > Camera.")
        }
    }
}

extension IPhoneCapture: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let cont = self.continuation
        self.continuation = nil
        if let error {
            cont?.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
            return
        }
        guard let raw = photo.fileDataRepresentation() else {
            cont?.resume(throwing: CaptureError.dataMissing)
            return
        }
        // Anthropic vision caps inline images at 5 MB. iPhone JPEGs are 5–8 MB
        // at native resolution — downsize to 1600 px on the long edge and
        // re-encode at quality 0.7 (well under 1 MB, plenty of detail for Claude).
        let shrunk = downsizeJPEG(raw, maxDimension: 1600, quality: 0.7) ?? raw
        cont?.resume(returning: shrunk)
    }

    private func downsizeJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let w = image.size.width, h = image.size.height
        let longEdge = max(w, h)
        guard longEdge > maxDimension else {
            return image.jpegData(compressionQuality: quality)
        }
        let scale = maxDimension / longEdge
        let newSize = CGSize(width: w * scale, height: h * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
