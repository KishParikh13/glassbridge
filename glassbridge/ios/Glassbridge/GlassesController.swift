import Foundation
import UIKit
import CoreMedia
import MWDATCore
import MWDATCamera

/// Owns DAT registration + DeviceSession + Stream lifecycle, exposes capturePhoto().
@MainActor
final class GlassesController: ObservableObject {
    enum Status: String {
        case unconfigured       // Wearables not yet configured / unavailable
        case available          // Meta AI present, not yet registered
        case registering
        case registered         // Registered but no eligible device available
        case waitingForDevice   // Stream waiting for the glasses to wake up
        case streaming          // Stream live, can capture
        case failed
    }

    @Published private(set) var status: Status = .unconfigured
    @Published private(set) var deviceId: String? = nil
    @Published private(set) var lastError: String? = nil
    @Published private(set) var debugLog: [String] = []
    @Published private(set) var cameraPermission: String = "unknown"
    @Published private(set) var isRecording: Bool = false

    private func log(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(8)
        debugLog.append("\(stamp) \(s)")
        if debugLog.count > 12 { debugLog.removeFirst(debugLog.count - 12) }
    }

    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?

    private var stateToken: (any AnyListenerToken)?
    private var photoToken: (any AnyListenerToken)?
    private var errorToken: (any AnyListenerToken)?
    private var videoFrameToken: (any AnyListenerToken)?
    private let videoRecorder = VideoRecorder()

    private var photoContinuation: CheckedContinuation<Data, Error>? = nil
    private let photoLock = NSLock()

    func start() {
        guard GlassbridgeApp.wearablesConfigured else {
            status = .unconfigured
            lastError = GlassbridgeApp.wearablesConfigureError ?? "Wearables.configure() not called"
            return
        }
        observeRegistration()
        observeDevices()
        // If we re-launched into an already-registered state, the stream may not
        // re-emit .registered. Kick the permission flow + session creation here too.
        if Wearables.shared.registrationState == .registered {
            status = .registered
            ensureCameraPermission()
            maybeStartDeviceSession()
        }
    }

    /// Manual retry hook for the UI when stuck in "registered · no device".
    func requestCameraPermissionAgain() {
        cameraPermissionRequested = false
        ensureCameraPermission()
    }

    func register() {
        guard GlassbridgeApp.wearablesConfigured else { return }
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.status = .registering
                self.log("registration: startRegistration()")
            }
            do {
                try await Wearables.shared.startRegistration()
                await MainActor.run { self.log("registration: returned ok") }
            } catch {
                await MainActor.run {
                    self.lastError = "startRegistration: \(error)"
                    self.status = .failed
                    self.log("registration: ERROR \(error)")
                }
            }
        }
    }

    private func observeRegistration() {
        Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                await MainActor.run {
                    switch state {
                    case .registered:
                        self.ensureCameraPermission()
                        self.maybeStartDeviceSession()
                    case .registering:
                        self.status = .registering
                    case .available:
                        self.status = .available
                    case .unavailable:
                        self.status = .unconfigured
                    @unknown default:
                        break
                    }
                }
            }
        }
    }

    /// DAT SDK won't put glasses in `devicesStream()` until the app holds at least
    /// one device permission. Requesting `.camera` triggers a Meta AI flow that grants
    /// it; once granted, the glasses appear and DeviceSession creation can succeed.
    private var cameraPermissionRequested = false
    private func ensureCameraPermission() {
        guard !cameraPermissionRequested else { log("cam: already requested this session, skipping"); return }
        cameraPermissionRequested = true
        log("cam: check status")
        Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await Wearables.shared.checkPermissionStatus(.camera)
                await MainActor.run {
                    self.cameraPermission = "\(current)"
                    self.log("cam: status=\(current)")
                }
                if current == .granted {
                    await MainActor.run { self.maybeStartDeviceSession() }
                    return
                }
                await MainActor.run { self.log("cam: requestPermission(.camera) — bouncing to Meta AI") }
                let result = try await Wearables.shared.requestPermission(.camera)
                await MainActor.run {
                    self.cameraPermission = "\(result)"
                    self.log("cam: result=\(result)")
                    if result == .granted {
                        self.maybeStartDeviceSession()
                    } else {
                        self.lastError = "Camera permission denied. Open Meta AI > App Connections > Glassbridge, or re-tap the button."
                    }
                }
            } catch {
                await MainActor.run {
                    self.log("cam: ERROR \(error)")
                    self.lastError = "requestPermission(.camera) threw: \(error)"
                }
            }
        }
    }

    private func observeDevices() {
        Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                guard let self else { return }
                await MainActor.run {
                    self.deviceId = devices.first
                    self.log("devicesStream: count=\(devices.count) first=\(devices.first ?? "nil")")
                    self.maybeStartDeviceSession()
                }
            }
        }
    }

    /// Create the DeviceSession + Stream once we're registered AND a device is visible.
    private func maybeStartDeviceSession() {
        guard deviceSession == nil else { return }
        guard Wearables.shared.registrationState == .registered else { return }
        guard !(Wearables.shared.devices.isEmpty) else {
            status = .registered
            return
        }

        do {
            let selector = AutoDeviceSelector(wearables: Wearables.shared)
            let session = try Wearables.shared.createSession(deviceSelector: selector)
            try session.start()
            self.deviceSession = session

            let config = StreamConfiguration(
                videoCodec: .raw,
                resolution: .medium,
                frameRate: 15
            )
            guard let stream = try session.addStream(config: config) else {
                throw NSError(domain: "GlassesController", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "addStream returned nil"])
            }
            self.stream = stream

            self.stateToken = stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .streaming: self.status = .streaming
                    case .waitingForDevice, .starting: self.status = .waitingForDevice
                    case .stopped, .stopping: self.status = .registered
                    case .paused: self.status = .waitingForDevice
                    @unknown default: break
                    }
                }
            }
            self.photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
                let data = photoData.data
                Task { @MainActor in
                    self?.deliverPhoto(.success(data))
                }
            }
            self.errorToken = stream.errorPublisher.listen { [weak self] err in
                Task { @MainActor in
                    self?.lastError = "stream error: \(err)"
                }
            }
            // Capture the recorder locally so the publisher thread never touches
            // MainActor-isolated `self`. The recorder ignores frames unless a
            // recording is in progress, so the always-on listener is cheap.
            let recorder = self.videoRecorder
            self.videoFrameToken = stream.videoFramePublisher.listen { frame in
                recorder.append(frame.sampleBuffer)
            }
            Task { await stream.start() }
        } catch {
            lastError = "createSession/addStream: \(error)"
            status = .failed
        }
    }

    /// Capture one JPEG from the glasses, blocking up to `timeout` seconds.
    func capturePhoto(timeout: TimeInterval = 4.0) async throws -> Data {
        guard let stream else {
            throw NSError(
                domain: "GlassesController", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Stream not initialized. Pair your glasses first."]
            )
        }
        // Wait briefly for streaming state.
        let waitStart = Date()
        while status != .streaming {
            if Date().timeIntervalSince(waitStart) > timeout {
                throw NSError(
                    domain: "GlassesController", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Glasses not streaming (status=\(status.rawValue))."]
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        return try await withCheckedThrowingContinuation { cont in
            photoLock.lock()
            self.photoContinuation = cont
            photoLock.unlock()
            let queued = stream.capturePhoto(format: .jpeg)
            if !queued {
                self.deliverPhoto(.failure(NSError(
                    domain: "GlassesController", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "capturePhoto refused (stream not ready)."]
                )))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.deliverPhoto(.failure(NSError(
                    domain: "GlassesController", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Photo capture timed out."]
                )))
            }
        }
    }

    /// Begin recording the live glasses video feed to an .mp4. Frames are pulled
    /// from `videoFramePublisher` (wired up in maybeStartDeviceSession).
    func startVideoRecording() throws {
        guard stream != nil else {
            throw NSError(domain: "GlassesController", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Stream not initialized. Pair your glasses first."])
        }
        guard status == .streaming else {
            throw NSError(domain: "GlassesController", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "Glasses not streaming (status=\(status.rawValue))."])
        }
        videoRecorder.start()
        isRecording = true
    }

    /// Stop recording and return the finished .mp4 URL.
    func stopVideoRecording() async throws -> URL {
        isRecording = false
        guard let url = await videoRecorder.finish() else {
            throw NSError(domain: "GlassesController", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "No video was recorded."])
        }
        return url
    }

    private func deliverPhoto(_ result: Result<Data, Error>) {
        photoLock.lock()
        let cont = self.photoContinuation
        self.photoContinuation = nil
        photoLock.unlock()
        switch result {
        case .success(let data): cont?.resume(returning: data)
        case .failure(let err): cont?.resume(throwing: err)
        }
    }
}
