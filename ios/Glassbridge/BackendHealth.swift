import Foundation

/// Checks whether the Glassbridge backend is reachable. The request also doubles
/// as the Local Network "prime" — the first connection to a LAN host triggers
/// iOS's local-network permission prompt.
enum BackendHealth {
    struct Result: Equatable {
        let reachable: Bool
        let latencyMs: Int?
        let detail: String
    }

    static func check(url: URL = AppConfig.backendURL) async -> Result {
        let healthz = url.appendingPathComponent("healthz")
        var request = URLRequest(url: healthz)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let t0 = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return Result(reachable: true, latencyMs: ms, detail: "Reachable · \(ms) ms")
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Result(reachable: false, latencyMs: ms, detail: "Unexpected HTTP \(code)")
        } catch {
            return Result(reachable: false, latencyMs: nil, detail: error.localizedDescription)
        }
    }
}
