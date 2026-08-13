import Foundation
import UIKit
import CoreMedia
import MWDATCore
import MWDATCamera

/// Owns DAT registration, device/compatibility observation, camera permission, and
/// the camera `Stream`. Session creation is delegated to `GlassesSessionManager`
/// (deferred + race-free). Exposes one user-facing `connectionState`.
///
/// Differs from the original by following Meta's canonical CameraAccess pattern:
/// permission is requested lazily at stream start, device compatibility is
/// monitored (firmware updates surfaced), the session manager races state-vs-error
/// streams, and typed SDK errors are mapped to plain language via `DATErrorText`.
@MainActor
final class GlassesController: ObservableObject {
    enum Quality: String, CaseIterable {
        case low, medium, high
        var label: String {
            switch self {
            case .low: return "Low · 360×640"
            case .medium: return "Medium · 504×896"
            case .high: return "High · 720×1280"
            }
        }
        var resolution: StreamingResolution {
            switch self {
            case .low: return .low
            case .medium: return .medium
            case .high: return .high
            }
        }
    }
    static let frameRateOptions = [2, 7, 15, 24, 30]

    // User-facing state.
    @Published private(set) var connectionState: ConnectionState = .usingPhone
    @Published private(set) var deviceId: String?
    @Published private(set) var lastError: String?
    @Published private(set) var requiresFirmwareUpdate = false
    @Published private(set) var debugLog: [String] = []
    @Published private(set) var cameraPermission = "unknown"
    @Published private(set) var micPermission = "unknown"
    @Published private(set) var isRecording = false

    // Live diagnostics for the Live / More tabs.
    @Published var previewEnabled = false
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var lastFrameSize = ""
    @Published private(set) var lastPhotoLatencyMs: Int?
    @Published private(set) var quality: Quality = .medium
    @Published private(set) var frameRate = 15

    // Rolling context (#1): recent frames kept so the next ASK has temporal awareness.
    @Published var contextCaptureEnabled = false
    @Published private(set) var contextFrameCount = 0

    /// True while the glasses camera stream is actively being used.
    var isStreaming: Bool { connectionState == .streaming }

    /// True when glasses are connected enough for an on-demand camera action.
    var canCaptureFromGlasses: Bool {
        connectionState == .connected || connectionState == .streaming || connectionState == .needsCameraPermission
    }

    // MARK: - Internal state used to derive connectionState
    private var registrationState: RegistrationState = .unavailable
    private var streamState: StreamState?
    private var cameraPermissionDenied = false
    private var firmwareUpdateMessage: String?
    private var isStartingStream = false
    private var hasDeviceWaitTimedOut = false
    private var deviceWaitTimeoutTask: Task<Void, Never>?

    private var sessionManager: GlassesSessionManager?
    private var stream: MWDATCamera.Stream?

    private var stateToken: (any AnyListenerToken)?
    private var photoToken: (any AnyListenerToken)?
    private var errorToken: (any AnyListenerToken)?
    private var videoFrameToken: (any AnyListenerToken)?
    private let videoRecorder = VideoRecorder()

    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var deviceCompatibility: [DeviceIdentifier: Compatibility] = [:]
    private var compatibilityTokens: [DeviceIdentifier: any AnyListenerToken] = [:]

    private var photoContinuation: CheckedContinuation<Data, Error>?
    /// Cancelled as soon as a photo lands, so it cannot outlive its own capture.
    private var photoTimeoutTask: Task<Void, Never>?
    private let photoLock = NSLock()

    private func log(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(8)
        debugLog.append("\(stamp) \(s)")
        if debugLog.count > 16 { debugLog.removeFirst(debugLog.count - 16) }
    }

    // MARK: - Lifecycle

    func start() {
        guard GlassbridgeApp.wearablesConfigured else {
            lastError = GlassbridgeApp.wearablesConfigureError ?? "Wearables.configure() not called"
            connectionState = .usingPhone
            return
        }
        let wearables = Wearables.shared
        registrationState = wearables.registrationState

        let manager = GlassesSessionManager(wearables: wearables)
        manager.onChange = { [weak self] in self?.updateConnectionState() }
        sessionManager = manager

        observeRegistration(wearables)
        observeDevices(wearables)
        refreshPermissions()
        updateConnectionState()
    }

    private func observeRegistration(_ wearables: WearablesInterface) {
        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard let self else { return }
                self.registrationState = state
                self.log("registration: \(state)")
                self.updateConnectionState()
            }
        }
    }

    private func observeDevices(_ wearables: WearablesInterface) {
        devicesTask = Task { [weak self] in
            for await ids in wearables.devicesStream() {
                guard let self else { return }
                self.deviceId = ids.first
                self.log("devices: count=\(ids.count)")
                self.monitorCompatibility(ids, wearables: wearables)
                self.updateConnectionState()
            }
        }
    }

    // MARK: - Compatibility (firmware) monitoring

    private func monitorCompatibility(_ ids: [DeviceIdentifier], wearables: WearablesInterface) {
        let present = Set(ids)
        compatibilityTokens = compatibilityTokens.filter { present.contains($0.key) }
        deviceCompatibility = deviceCompatibility.filter { present.contains($0.key) }
        for id in ids {
            guard compatibilityTokens[id] == nil, let device = wearables.deviceForIdentifier(id) else { continue }
            deviceCompatibility[id] = device.compatibility()
            let token = device.addCompatibilityListener { [weak self] compatibility in
                Task { @MainActor in self?.handleCompatibility(compatibility, id: id) }
            }
            compatibilityTokens[id] = token
        }
        refreshFirmwareState()
    }

    private func handleCompatibility(_ compatibility: Compatibility, id: DeviceIdentifier) {
        deviceCompatibility[id] = compatibility
        refreshFirmwareState()
    }

    private func refreshFirmwareState() {
        let needsUpdate = deviceCompatibility.values.contains(.deviceUpdateRequired)
            || deviceCompatibility.values.contains(.sdkUpdateRequired)
        requiresFirmwareUpdate = needsUpdate
        firmwareUpdateMessage = needsUpdate
            ? "Your glasses need an update to work with Glassbridge. Open the update in Meta AI, then reconnect."
            : nil
        updateConnectionState()
    }

    // MARK: - connectionState derivation

    private func updateConnectionState() {
        guard GlassbridgeApp.wearablesConfigured else { connectionState = .usingPhone; return }
        if streamState == .streaming { connectionState = .streaming; return }
        if let msg = firmwareUpdateMessage { connectionState = .needsDeviceUpdate(msg); return }

        switch registrationState {
        case .unavailable:
            cancelDeviceWaitTimeout()
            connectionState = .usingPhone
        case .available:
            cancelDeviceWaitTimeout()
            connectionState = .readyToConnect
        case .registering:
            cancelDeviceWaitTimeout()
            connectionState = .registering
        case .registered:
            if !(sessionManager?.hasActiveDevice ?? false) {
                beginDeviceWaitTimeout()
                if hasDeviceWaitTimedOut {
                    connectionState = .problem("Make sure glasses are on and open, then try again.")
                } else {
                    connectionState = .connecting
                }
            } else if cameraPermissionDenied {
                cancelDeviceWaitTimeout()
                connectionState = .needsCameraPermission
            } else {
                cancelDeviceWaitTimeout()
                connectionState = .connected
            }
        @unknown default:
            cancelDeviceWaitTimeout()
            connectionState = .usingPhone
        }
    }

    private func beginDeviceWaitTimeout() {
        guard deviceWaitTimeoutTask == nil, !hasDeviceWaitTimedOut else { return }
        deviceWaitTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.hasDeviceWaitTimedOut = true
                self.deviceWaitTimeoutTask = nil
                self.log("devices: wait timed out")
                self.updateConnectionState()
            }
        }
    }

    private func cancelDeviceWaitTimeout() {
        deviceWaitTimeoutTask?.cancel()
        deviceWaitTimeoutTask = nil
        hasDeviceWaitTimedOut = false
    }

    // MARK: - Connect / disconnect

    func connect() {
        guard GlassbridgeApp.wearablesConfigured, registrationState != .registering else { return }
        lastError = nil
        cancelDeviceWaitTimeout()
        Task { [weak self] in
            guard let self else { return }
            self.log("connect: startRegistration()")
            do {
                try await Wearables.shared.startRegistration()
            } catch {
                // Calling through the `any WearablesInterface` existential erases the
                // typed throw to `any Error`, so downcast to inspect the case.
                let regError = error as? RegistrationError
                if regError == .alreadyRegistered { self.updateConnectionState(); return }
                let text = DATErrorText.describe(error)
                self.lastError = text
                self.connectionState = (regError == .metaAINotInstalled) ? .metaAINotInstalled : .problem(text)
                self.log("connect: ERROR \(error)")
            }
        }
    }

    func unregister() {
        guard GlassbridgeApp.wearablesConfigured else { return }
        Task { [weak self] in
            guard let self else { return }
            self.log("unregister")
            try? await Wearables.shared.startUnregistration()
            self.teardownStream()
            self.updateConnectionState()
        }
    }

    func openFirmwareUpdate() {
        guard GlassbridgeApp.wearablesConfigured else { return }
        Task { [weak self] in
            do { try await Wearables.shared.openFirmwareUpdate() }
            catch { self?.lastError = DATErrorText.describe(error) }
        }
    }

    func openDATGlassesAppUpdate() {
        guard GlassbridgeApp.wearablesConfigured else { return }
        Task { [weak self] in
            do { try await Wearables.shared.openDATGlassesAppUpdate() }
            catch { self?.lastError = DATErrorText.describe(error) }
        }
    }

    // MARK: - Permissions (lazy)

    func refreshPermissions() {
        guard GlassbridgeApp.wearablesConfigured else { return }
        Task { [weak self] in
            guard let self else { return }
            if let cam = try? await Wearables.shared.checkPermissionStatus(.camera) {
                self.cameraPermission = "\(cam)"
            }
            if let mic = try? await Wearables.shared.checkPermissionStatus(.microphone) {
                self.micPermission = "\(mic)"
            }
        }
    }

    func requestMicPermission() {
        guard GlassbridgeApp.wearablesConfigured else { return }
        Task { [weak self] in
            if let result = try? await Wearables.shared.requestPermission(.microphone) {
                self?.micPermission = "\(result)"
            }
        }
    }

    // MARK: - Streaming

    /// Start the glasses camera stream for an explicit capture/recording action.
    /// The UI should not keep this running just because glasses are connected.
    func startStreaming() async {
        guard GlassbridgeApp.wearablesConfigured, let sessionManager else { return }
        guard streamState != .streaming, !isStartingStream else { return }
        isStartingStream = true
        defer { isStartingStream = false }

        // 1. Camera permission — checked/requested HERE, not at registration.
        do {
            var status = try await Wearables.shared.checkPermissionStatus(.camera)
            if status != .granted {
                self.log("permission: requesting camera")
                status = try await Wearables.shared.requestPermission(.camera)
            }
            cameraPermission = "\(status)"
            guard status == .granted else {
                cameraPermissionDenied = true
                updateConnectionState()
                return
            }
            cameraPermissionDenied = false
        } catch {
            lastError = DATErrorText.describe(error)
            connectionState = .problem(lastError ?? "")
            log("permission: ERROR \(error)")
            return
        }

        // 2. A started device session (racing the error stream inside the manager).
        let session: DeviceSession
        do {
            session = try await sessionManager.getSession()
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            firmwareUpdateMessage = DATErrorText.describe(DeviceSessionError.datAppOnTheGlassesUpdateRequired)
            updateConnectionState()
            return
        } catch {
            lastError = DATErrorText.describe(error)
            connectionState = .problem(lastError ?? "")
            log("getSession: ERROR \(error)")
            return
        }

        // 3. Add + start the camera stream.
        startStream(on: session)
    }

    private func startStream(on session: DeviceSession) {
        guard stream == nil else { return }
        do {
            let config = StreamConfiguration(videoCodec: .raw, resolution: quality.resolution, frameRate: UInt(frameRate))
            guard let stream = try session.addStream(config: config) else {
                throw NSError(domain: "GlassesController", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "addStream returned nil"])
            }
            self.stream = stream

            stateToken = stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.handleStreamState(state) }
            }
            photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
                let data = photoData.data
                Task { @MainActor in self?.deliverPhoto(.success(data)) }
            }
            errorToken = stream.errorPublisher.listen { [weak self] err in
                Task { @MainActor in self?.handleStreamError(err) }
            }
            let recorder = self.videoRecorder
            videoFrameToken = stream.videoFramePublisher.listen { [weak self] frame in
                recorder.append(frame.sampleBuffer)
                Task { @MainActor in self?.onVideoFrame(frame) }
            }
            log("stream: \(quality.rawValue) @ \(frameRate)fps")
            Task { await stream.start() }
        } catch {
            lastError = DATErrorText.describe(error)
            connectionState = .problem(lastError ?? "")
            log("addStream: ERROR \(error)")
        }
    }

    private func handleStreamState(_ state: StreamState) {
        streamState = state
        switch state {
        case .stopped, .stopping:
            // Stream ended — drop it so a fresh one is added on next start.
            previewImage = nil
            measuredFPS = 0
        case .streaming, .waitingForDevice, .starting, .paused:
            break
        @unknown default:
            break
        }
        updateConnectionState()
    }

    private func handleStreamError(_ error: StreamError) {
        let text = DATErrorText.describe(error)
        lastError = text
        log("stream error: \(error)")
        // Battery/thermal/disconnect end the stream; reflect that the glasses aren't live.
        if streamState != .streaming { connectionState = .problem(text) }
    }

    private func teardownStream() {
        if let stream { Task { await stream.stop() } }
        stateToken = nil
        photoToken = nil
        errorToken = nil
        videoFrameToken = nil
        stream = nil
        streamState = nil
        previewImage = nil
        measuredFPS = 0
    }

    func stopStreaming() {
        teardownStream()
        updateConnectionState()
    }

    /// Apply new camera quality/frame rate. Rebuilds the stream if one is live.
    func applyStreamSettings(quality: Quality, frameRate: Int) {
        self.quality = quality
        self.frameRate = frameRate
        guard stream != nil else { return }
        teardownStream()
        Task { await startStreaming() }
    }

    // MARK: - Live frame diagnostics + rolling context

    private var fpsWindowStart = Date()
    private var fpsCount = 0
    private var lastPreviewAt = Date.distantPast
    private var contextFrames: [Data] = []
    private var lastContextAt = Date.distantPast
    private let contextMaxFrames = 4
    private let contextIntervalSec: TimeInterval = 1.5

    private func onVideoFrame(_ frame: VideoFrame) {
        fpsCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            measuredFPS = Double(fpsCount) / elapsed
            fpsCount = 0
            fpsWindowStart = now
        }

        let wantPreview = previewEnabled && now.timeIntervalSince(lastPreviewAt) > 0.1
        let wantContext = contextCaptureEnabled && now.timeIntervalSince(lastContextAt) > contextIntervalSec
        guard wantPreview || wantContext else { return }
        guard let image = frame.makeUIImage() else { return }

        if wantPreview {
            lastPreviewAt = now
            previewImage = image
            lastFrameSize = "\(Int(image.size.width))×\(Int(image.size.height))"
        }
        if wantContext {
            lastContextAt = now
            if let jpeg = Self.contextJPEG(image) {
                contextFrames.append(jpeg)
                if contextFrames.count > contextMaxFrames {
                    contextFrames.removeFirst(contextFrames.count - contextMaxFrames)
                }
                contextFrameCount = contextFrames.count
            }
        }
    }

    func recentContextFrames() -> [Data] { contextFrames }

    func clearContextFrames() {
        contextFrames.removeAll()
        contextFrameCount = 0
    }

    private static func contextJPEG(_ image: UIImage, maxDim: CGFloat = 640, quality: CGFloat = 0.5) -> Data? {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDim else { return image.jpegData(compressionQuality: quality) }
        let scale = maxDim / longEdge
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    // MARK: - Capture

    /// Capture one JPEG from the glasses, starting and stopping the stream on demand.
    ///
    /// The timeout used to be 6s, and the camera routinely takes 5 to 8 to deliver: the
    /// one measured success came back at 5.5s, half a second inside the limit. So captures
    /// were being abandoned that would have arrived. The glasses really were taking the
    /// picture; we stopped listening for it.
    ///
    /// The wait only costs anything when the photo genuinely never comes, and it is only
    /// ever entered because the user said "look", which is a request to be looked at.
    func capturePhoto(timeout: TimeInterval = 14.0) async throws -> Data {
        let startedForPhoto = streamState != .streaming
        if startedForPhoto { await startStreaming() }
        defer {
            if startedForPhoto && !isRecording {
                stopStreaming()
            }
        }
        guard let stream else {
            throw NSError(domain: "GlassesController", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Glasses aren't streaming. Connect your glasses first."])
        }
        try await waitUntilStreaming(timeout: timeout)

        let t0 = Date()
        let data: Data = try await withCheckedThrowingContinuation { cont in
            photoLock.lock()
            self.photoContinuation = cont
            photoLock.unlock()
            let queued = stream.capturePhoto(format: .jpeg)
            if !queued {
                self.deliverPhoto(.failure(NSError(
                    domain: "GlassesController", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "capturePhoto refused (stream not ready)."])))
                return
            }
            // Held so delivery can cancel it. Left running, a timeout from one capture
            // fires long after that photo arrived and resolves the *next* capture's
            // continuation with a spurious timeout.
            photoTimeoutTask?.cancel()
            photoTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.deliverPhoto(.failure(NSError(
                    domain: "GlassesController", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Photo capture timed out."])))
            }
        }
        lastPhotoLatencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        return data
    }

    func testCameraOnce() async {
        do {
            _ = try await capturePhoto()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startVideoRecording() async throws {
        if streamState != .streaming { await startStreaming() }
        if streamState != .streaming {
            try await waitUntilStreaming(timeout: 6.0)
        }
        guard stream != nil, streamState == .streaming else {
            throw NSError(domain: "GlassesController", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Glasses aren't streaming. Connect your glasses first."])
        }
        videoRecorder.start()
        isRecording = true
    }

    func stopVideoRecording() async throws -> URL {
        isRecording = false
        guard let url = await videoRecorder.finish() else {
            throw NSError(domain: "GlassesController", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "No video was recorded."])
        }
        stopStreaming()
        return url
    }

    private func waitUntilStreaming(timeout: TimeInterval) async throws {
        let waitStart = Date()
        while streamState != .streaming {
            if Date().timeIntervalSince(waitStart) > timeout {
                throw NSError(domain: "GlassesController", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: lastError ?? "Glasses didn't start streaming."])
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func deliverPhoto(_ result: Result<Data, Error>) {
        photoTimeoutTask?.cancel()
        photoTimeoutTask = nil
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
