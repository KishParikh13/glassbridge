import Foundation
import MWDATCore
import MWDATCamera

/// The single user-facing description of where glasses pairing stands. Both the
/// Live source chip and the Setup glasses step render this — so the user always
/// sees the same plain-language status and (when stuck) a reason + next step.
enum ConnectionState: Equatable {
    case usingPhone                  // glasses unavailable; iPhone fallback is active
    case metaAINotInstalled          // Meta AI companion app missing
    case readyToConnect              // RegistrationState.available — can start registration
    case registering                 // registration handoff in flight
    case connecting                  // registered, waiting for a connected device
    case needsDeviceUpdate(String)   // compatibility .deviceUpdateRequired / .sdkUpdateRequired
    case needsCameraPermission       // device connected but camera permission not granted
    case connected                   // connected device + a session can start
    case streaming                   // stream is live; capture/preview available
    case problem(String)             // a typed error, already mapped to plain language

    var isGlassesLive: Bool { self == .streaming }

    /// Short text for the Live source chip.
    var shortLabel: String {
        switch self {
        case .usingPhone:           return "iPhone camera + mic"
        case .metaAINotInstalled:   return "Meta AI not installed"
        case .readyToConnect:       return "Glasses: tap to connect"
        case .registering:          return "Glasses: connecting…"
        case .connecting:           return "Glasses: waking up…"
        case .needsDeviceUpdate:    return "Glasses: update needed"
        case .needsCameraPermission:return "Glasses: allow camera"
        case .connected:            return "Glasses: connected"
        case .streaming:            return "Ray-Ban glasses · live"
        case .problem:              return "Glasses: needs attention"
        }
    }

    /// Whether this state means glasses are the active capture source.
    var usesGlasses: Bool { self == .streaming }

    /// Longer explanation + next step for the Setup glasses step.
    var detail: String {
        switch self {
        case .usingPhone:
            return "Glasses aren't connected. Glassbridge is using the iPhone camera and mic. Connect glasses below to upgrade."
        case .metaAINotInstalled:
            return "Install the Meta AI app and pair your Ray-Ban glasses, then come back and connect."
        case .readyToConnect:
            return "Ready to connect. Tap Connect to link Glassbridge with your glasses through Meta AI."
        case .registering:
            return "Finishing up in the Meta AI app… approve Glassbridge there if prompted."
        case .connecting:
            return "Connected to Meta AI, waiting for the glasses. Put them on or unfold them, and make sure Developer Mode is on."
        case .needsDeviceUpdate(let msg):
            return msg
        case .needsCameraPermission:
            return "Your glasses are connected. Allow camera access for Glassbridge in Meta AI to finish."
        case .connected:
            return "Glasses connected and ready. Tap Test to start the camera stream."
        case .streaming:
            return "Glasses are live. Camera, photo, video, live preview, and rolling context are all using the glasses."
        case .problem(let msg):
            return msg
        }
    }
}

/// Turns the DAT SDK's typed errors into plain-language sentences with an action,
/// instead of stringified enum cases. Falls back to `localizedDescription`.
enum DATErrorText {
    static func describe(_ error: Error) -> String {
        if let e = error as? RegistrationError { return registration(e) }
        if let e = error as? PermissionError { return permission(e) }
        if let e = error as? DeviceSessionError { return session(e) }
        if let e = error as? StreamError { return stream(e) }
        if let e = error as? NavigationError { return navigation(e) }
        if let e = error as? WearablesError { return "Glasses support couldn't start (\(e)). Restart the app." }
        return error.localizedDescription
    }

    private static func registration(_ e: RegistrationError) -> String {
        switch e {
        case .metaAINotInstalled: return "Install the Meta AI app to connect your glasses."
        case .networkUnavailable: return "Connecting needs internet. Check your connection and try again."
        case .alreadyRegistered:  return "Glassbridge is already connected to your glasses."
        case .configurationInvalid: return "App configuration issue — check the Meta App ID / Team ID in setup."
        case .unknown:            return "Couldn't connect to the glasses. Try again."
        @unknown default:         return "Couldn't connect to the glasses. Try again."
        }
    }

    private static func permission(_ e: PermissionError) -> String {
        switch e {
        case .noDevice, .noDeviceWithConnection:
            return "Put your glasses on (or unfold them) so we can request camera access."
        case .metaAINotInstalled: return "Install the Meta AI app to grant camera access."
        case .requestTimeout:     return "The camera permission request timed out. Try again."
        case .requestInProgress:  return "A permission request is already in progress — check Meta AI."
        case .connectionError:    return "Lost connection to the glasses while requesting permission. Reconnect and retry."
        case .internalError:      return "Something went wrong requesting camera permission. Try again."
        @unknown default:         return "Couldn't request camera permission. Try again."
        }
    }

    private static func session(_ e: DeviceSessionError) -> String {
        switch e {
        case .noEligibleDevice:   return "No glasses are available. Make sure they're on, unfolded, and connected in Meta AI."
        case .batteryCritical:    return "Glasses battery is too low to stream. Charge them and try again."
        case .thermalCritical, .thermalEmergency:
            return "Glasses are too warm to stream right now. Let them cool down."
        case .peakPowerShutdown:  return "Glasses shut down to protect power. Try again in a moment."
        case .datAppOnTheGlassesUpdateRequired:
            return "Your glasses need an app update. Open the update in Meta AI, then reconnect."
        case .dwaUnavailable:     return "The glasses companion service is unavailable. Reopen Meta AI and retry."
        case .sessionAlreadyExists, .sessionAlreadyStopped, .sessionIdle,
             .capabilityAlreadyActive, .capabilityNotFound:
            return "Glasses session hiccup — retrying should fix it."
        case .unexpectedError(let d): return "Glasses session error: \(d)"
        @unknown default:         return "Couldn't start the glasses session. Try again."
        }
    }

    private static func stream(_ e: StreamError) -> String {
        switch e {
        case .permissionDenied:   return "Camera access is off for Glassbridge. Enable it in Meta AI."
        case .hingesClosed:       return "Open your glasses — the camera is off while they're folded."
        case .deviceNotConnected: return "Glasses disconnected. Put them on or unfold them to reconnect."
        case .deviceNotFound:     return "Glasses not found. Check they're connected in Meta AI."
        case .timeout:            return "The camera stream timed out. Try again."
        case .batteryCritical:    return "Glasses battery is too low to stream. Charge them."
        case .thermalCritical, .thermalEmergency:
            return "Glasses are too warm to stream. Let them cool down."
        case .peakPowerShutdown:  return "Glasses shut down to protect power. Try again shortly."
        case .videoStreamingError, .internalError:
            return "The camera stream hit an error. Try again."
        @unknown default:         return "Camera stream error. Try again."
        }
    }

    private static func navigation(_ e: NavigationError) -> String {
        switch e {
        case .metaAINotInstalled: return "Install the Meta AI app first."
        case .notRegistered:      return "Connect your glasses before opening this."
        @unknown default:         return "Couldn't open Meta AI."
        }
    }
}
