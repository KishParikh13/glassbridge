import Foundation
import MWDATCore

/// Owns the DAT `DeviceSession` lifecycle with a 1:1 device-to-session mapping,
/// mirroring Meta's canonical `DeviceSessionManager` from the CameraAccess sample.
///
/// Why this exists (and the old controller's eager approach didn't work):
/// - Session creation is **deferred** to `getSession()` so we never race device
///   availability against session creation.
/// - `getSession()` waits for `.started` while **racing the error stream**, so a
///   failure to start (battery/thermal/update-required/no-device) surfaces as a
///   thrown error instead of a silent hang.
/// - After `.stopped` the session is dropped so the next `getSession()` makes a
///   fresh one — matching the SDK rule "create a new session to restart."
@MainActor
final class GlassesSessionManager {
    private(set) var hasActiveDevice = false
    private(set) var isReady = false

    /// Invoked on the main actor whenever `hasActiveDevice` or `isReady` changes,
    /// so the owning controller can recompute its published `connectionState`.
    var onChange: (() -> Void)?

    private let wearables: WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private var deviceSession: DeviceSession?
    private var deviceMonitorTask: Task<Void, Never>?
    private var stateObserverTask: Task<Void, Never>?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        startDeviceMonitoring()
    }

    /// Stops the session and cancels monitoring. Call before releasing.
    func cleanup() {
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        stateObserverTask?.cancel()
        stateObserverTask = nil
        deviceSession?.stop()
        deviceSession = nil
        setReady(false)
    }

    /// Returns a `DeviceSession` in the `.started` state, creating one if needed.
    /// Throws a `DeviceSessionError` (or mapped error) if the session can't start.
    func getSession() async throws -> DeviceSession {
        if let session = deviceSession, session.state == .started {
            setReady(true)
            return session
        }
        if deviceSession?.state == .stopped {
            deviceSession = nil
        }

        // An in-progress session: wait for it to finish starting.
        if let session = deviceSession {
            if session.state == .started {
                setReady(true)
                startStateObserver(for: session)
                return session
            }
            try await waitForSessionStart(
                stateStream: session.stateStream(),
                errorStream: session.errorStream()
            )
            setReady(true)
            startStateObserver(for: session)
            return session
        }

        // Create a fresh session.
        do {
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            deviceSession = session
            let stateStream = session.stateStream()
            let errorStream = session.errorStream()
            try session.start()

            // The session may already be .started before the stream starts iterating
            // (state arrives on another thread and the stream doesn't buffer).
            if session.state == .started {
                setReady(true)
                startStateObserver(for: session)
                return session
            }
            try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
            setReady(true)
            startStateObserver(for: session)
            return session
        } catch {
            setReady(false)
            deviceSession = nil
            throw error
        }
    }

    // MARK: - Private

    /// Races the session's state stream against its error stream: returns when
    /// `.started` arrives, throws if `.stopped` arrives first or any error fires.
    private func waitForSessionStart(
        stateStream: AsyncStream<DeviceSessionState>,
        errorStream: AsyncStream<DeviceSessionError>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in stateStream {
                    if state == .started { return }
                    if state == .stopped {
                        throw DeviceSessionError.unexpectedError(description: "The session failed to start")
                    }
                }
                guard !Task.isCancelled else { return }
                throw DeviceSessionError.unexpectedError(description: "The session failed to start")
            }
            group.addTask {
                for await error in errorStream { throw error }
                guard !Task.isCancelled else { return }
                throw DeviceSessionError.unexpectedError(description: "The session failed to start")
            }
            guard try await group.next() != nil else {
                throw DeviceSessionError.unexpectedError(description: "The session failed to start")
            }
            group.cancelAll()
        }
    }

    /// Monitors device availability only — does NOT create sessions (avoids races).
    private func startDeviceMonitoring() {
        deviceMonitorTask = Task { [weak self] in
            guard let self else { return }
            for await device in deviceSelector.activeDeviceStream() {
                let active = device != nil
                if active != self.hasActiveDevice {
                    self.hasActiveDevice = active
                    self.onChange?()
                }
            }
        }
    }

    /// After a session is started, keep observing: drop it on `.stopped` so the
    /// next `getSession()` builds a fresh one.
    private func startStateObserver(for session: DeviceSession) {
        stateObserverTask?.cancel()
        stateObserverTask = Task { [weak self] in
            for await state in session.stateStream() {
                guard let self else { return }
                if state == .started {
                    self.setReady(true)
                } else if state == .stopped {
                    self.setReady(false)
                    self.deviceSession = nil
                    self.stateObserverTask = nil
                    return
                }
            }
        }
    }

    private func setReady(_ value: Bool) {
        guard value != isReady else { return }
        isReady = value
        onChange?()
    }
}
