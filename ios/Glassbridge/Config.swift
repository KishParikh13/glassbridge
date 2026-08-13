import Foundation

enum AppConfig {
    /// The backend runs on the always-on Mac mini and is reached over Tailscale.
    ///
    /// This is a Tailscale IP, not a LAN address, and that is the point: it works from
    /// any network. A LAN address meant the phone and the Mac had to be on the same
    /// Wi-Fi, which broke the moment the network isolated clients from each other, and
    /// it went stale every time the Mac's DHCP lease changed.
    ///
    /// Requires Tailscale installed and signed in on the iPhone. Without it, every
    /// request times out silently, exactly like a denied Local Network permission.
    static let backendURL: URL = {
        // The simulator runs on the host Mac, so it can reach the mini over Tailscale
        // too; there is no loopback special case any more.
        URL(string: "http://100.96.61.83:8082")!   // kishs-mac-mini-1
    }()

    /// Stable per-launch session id so the backend can keep multi-turn memory.
    static let sessionId: String = UUID().uuidString
}
