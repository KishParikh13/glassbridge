import AVFoundation
import Foundation

/// The single owner of `AVAudioSession` for the whole app.
///
/// Before this existed, `AudioController` and `WakeWordListener` each set their own
/// category and each called `setActive(false, .notifyOthersOnDeactivation)` on teardown,
/// so whichever finished last silenced the other. That is also why the wake word had to
/// be paused for the entire ask: there was no way for listening and playback to coexist.
///
/// Nothing else in the app may call `setCategory`, `setActive`, or `setPreferredInput`.
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    enum SessionError: LocalizedError {
        case configureFailed(String)

        var errorDescription: String? {
            switch self {
            case .configureFailed(let message): return "Audio session: \(message)"
            }
        }
    }

    /// Port types the glasses can show up as: classic HFP, BLE Audio on newer firmware,
    /// or a wired-headset-like accessory.
    static let bluetoothPorts: Set<AVAudioSession.Port> = [
        .bluetoothHFP, .bluetoothLE, .bluetoothA2DP, .headsetMic, .headphones,
    ]
    private static let glassesNames = ["RB Meta", "Ray-Ban", "Ray Ban", "Meta"]

    private let session = AVAudioSession.sharedInstance()
    private var isConfigured = false
    private var routeObserver: NSObjectProtocol?

    private init() {}

    /// Configure once, then leave the session active for the app's lifetime.
    /// Safe to call repeatedly; only the first call configures.
    ///
    /// `.voiceChat` is doing more work than route selection here. It turns on echo
    /// cancellation, which is what lets the wake word recognizer keep listening while a
    /// reply plays out of the same speaker without triggering on Claude's own voice.
    func activate() throws {
        do {
            if !isConfigured {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetoothHFP, .duckOthers, .defaultToSpeaker]
                )
                isConfigured = true
                observeRouteChanges()
            }
            try session.setActive(true, options: [])
        } catch {
            throw SessionError.configureFailed(error.localizedDescription)
        }
        preferGlassesInput()
    }

    /// Only for an explicit teardown from the diagnostics panel. The normal loop never
    /// deactivates, because an always-live session is what keeps the wake word listening.
    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// True when a Bluetooth route is carrying both input and output.
    var isBluetoothRouteLive: Bool {
        let route = session.currentRoute
        let input = route.inputs.contains { Self.bluetoothPorts.contains($0.portType) }
        let output = route.outputs.contains { Self.bluetoothPorts.contains($0.portType) }
        return input && output
    }

    /// iOS lists an HFP route in `availableInputs` before it actually activates it, so a
    /// recording started too early quietly grabs the iPhone mic instead. Poll briefly.
    /// Returns false on timeout rather than throwing: the iPhone mic is a fine fallback.
    @discardableResult
    func waitForBluetoothRoute(timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isBluetoothRouteLive { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isBluetoothRouteLive
    }

    private func preferGlassesInput() {
        let available = session.availableInputs ?? []
        let chosen = available.first { port in
            Self.bluetoothPorts.contains(port.portType)
                && Self.glassesNames.contains { port.portName.localizedCaseInsensitiveContains($0) }
        } ?? available.first { Self.bluetoothPorts.contains($0.portType) }
        if let chosen {
            try? session.setPreferredInput(chosen)
        }
    }

    /// Glasses fold, unfold, and drop out of range constantly. Re-pin the preferred input
    /// on every route change so a brief disconnect does not strand us on the iPhone mic.
    private func observeRouteChanges() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AudioSessionController.shared.preferGlassesInput()
            }
        }
    }

    // MARK: - Diagnostics

    func routeSummary() -> String {
        let route = session.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "in=[\(inputs)] out=[\(outputs)]"
    }

    func availableInputsSummary() -> String {
        let inputs = session.availableInputs ?? []
        guard !inputs.isEmpty else { return "none" }
        return inputs.map { "\($0.portType.rawValue): \($0.portName)" }.joined(separator: "\n")
    }
}
