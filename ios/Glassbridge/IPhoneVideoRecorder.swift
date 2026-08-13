import AVFoundation

/// Records a short movie clip from the iPhone rear camera + mic using
/// AVCaptureMovieFileOutput. Fallback for the Camera tab when the glasses stream
/// isn't available, mirroring how IPhoneCapture backstops glasses photo capture.
final class IPhoneVideoRecorder: NSObject {
    enum RecordError: LocalizedError {
        case noCamera
        case permissionDenied(String)
        case sessionFailed(String)
        case notRecording

        var errorDescription: String? {
            switch self {
            case .noCamera: return "iPhone has no rear camera available."
            case .permissionDenied(let m): return m
            case .sessionFailed(let m): return "Camera session: \(m)"
            case .notRecording: return "No recording in progress."
            }
        }
    }

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var stopContinuation: CheckedContinuation<URL, Error>?

    var isRecording: Bool { movieOutput.isRecording }

    func start() async throws {
        try await prepareSessionIfNeeded()
        if !session.isRunning {
            session.startRunning()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stop() async throws -> URL {
        guard movieOutput.isRecording else { throw RecordError.notRecording }
        return try await withCheckedThrowingContinuation { cont in
            self.stopContinuation = cont
            movieOutput.stopRecording()
        }
    }

    private func prepareSessionIfNeeded() async throws {
        try await ensurePermission(.video)
        try await ensurePermission(.audio)

        if session.inputs.isEmpty {
            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            ) else {
                throw RecordError.noCamera
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            do {
                let videoInput = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(videoInput) else {
                    session.commitConfiguration()
                    throw RecordError.sessionFailed("canAddInput(video)=false")
                }
                session.addInput(videoInput)

                if let mic = AVCaptureDevice.default(for: .audio) {
                    let audioInput = try AVCaptureDeviceInput(device: mic)
                    if session.canAddInput(audioInput) { session.addInput(audioInput) }
                }
            } catch let e as RecordError {
                session.commitConfiguration()
                throw e
            } catch {
                session.commitConfiguration()
                throw RecordError.sessionFailed(error.localizedDescription)
            }
            guard session.canAddOutput(movieOutput) else {
                session.commitConfiguration()
                throw RecordError.sessionFailed("canAddOutput=false")
            }
            session.addOutput(movieOutput)
            session.commitConfiguration()
        }
    }

    private func ensurePermission(_ type: AVMediaType) async throws {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: type) { return }
            throw RecordError.permissionDenied("\(type.rawValue) permission denied by user.")
        default:
            throw RecordError.permissionDenied(
                "\(type.rawValue) permission denied. Enable it in Settings > Glassbridge.")
        }
    }
}

extension IPhoneVideoRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if session.isRunning { session.stopRunning() }
        let cont = stopContinuation
        stopContinuation = nil
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: outputFileURL)
        }
    }
}
