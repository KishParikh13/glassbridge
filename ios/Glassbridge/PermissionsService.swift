import Foundation
import AVFoundation
import Speech

/// Coarse status for an iOS permission, used by the Setup onboarding flow.
enum PermStatus: String {
    case granted = "Allowed"
    case denied = "Denied"
    case undetermined = "Not asked"

    var isGranted: Bool { self == .granted }
}

/// Thin wrappers over the iOS permission APIs Glassbridge needs. These are the
/// *phone's* permissions (mic/camera/speech) — distinct from the glasses' DAT
/// camera permission, which `GlassesController` handles.
enum PermissionsService {

    // MARK: Microphone (iPhone mic for ASK + loopback)

    static func microphoneStatus() -> PermStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    static func requestMicrophone() async -> PermStatus {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted ? .granted : .denied)
            }
        }
    }

    // MARK: Camera (iPhone camera fallback)

    static func cameraStatus() -> PermStatus { map(AVCaptureDevice.authorizationStatus(for: .video)) }

    static func requestCamera() async -> PermStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .granted : .denied
    }

    // MARK: Speech recognition (on-device wake word)

    static func speechStatus() -> PermStatus { map(SFSpeechRecognizer.authorizationStatus()) }

    static func requestSpeech() async -> PermStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: map(status))
            }
        }
    }

    // MARK: Helpers

    private static func map(_ s: AVAuthorizationStatus) -> PermStatus {
        switch s {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    private static func map(_ s: SFSpeechRecognizerAuthorizationStatus) -> PermStatus {
        switch s {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
}
