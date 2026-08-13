import Foundation

enum AppConfig {
    /// Change this to your MacBook's LAN IP printed by `./run.sh`.
    /// Example: "http://192.168.1.42:8082"
    static let backendURL: URL = {
        // Simulator reaches the host Mac's loopback via 127.0.0.1. A real iPhone
        // needs the Mac's LAN IP since they're separate devices on the network.
        // run.sh prints the right value as "iOS BACKEND_URL = http://…:8082".
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8082")!
        #else
        return URL(string: "http://192.168.4.43:8082")! // Mac's current LAN IP (en0)
        #endif
    }()

    /// Stable per-launch session id so the backend can keep multi-turn memory.
    static let sessionId: String = UUID().uuidString
}
