import Foundation

/// One assistant the glasses can talk to, as described by the backend.
struct AgentInfo: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let wakePhrase: String
    let acceptsImages: Bool
    let description: String

    private enum CodingKeys: String, CodingKey {
        case id, label, wakePhrase, acceptsImages, description
    }
}

/// Which assistants exist and what phrase reaches each one.
///
/// Fetched from the backend rather than compiled in, so adding an agent is a config edit
/// on the server and a relaunch of the app. Nothing here knows what KishOS is, or that it
/// exists: it is just whatever the backend says is available.
@MainActor
final class AgentDirectory: ObservableObject {
    @Published private(set) var agents: [AgentInfo] = AgentDirectory.fallback
    @Published private(set) var defaultAgentId: String = "glass"
    @Published private(set) var lastError: String?

    /// Used before the first successful fetch and if the backend is unreachable. Without
    /// it a backend that is down at launch would leave the glasses deaf rather than merely
    /// limited to the built-in agent.
    static let fallback: [AgentInfo] = [
        AgentInfo(id: "glass",
                  label: "Glass",
                  wakePhrase: "hey glass",
                  acceptsImages: true,
                  description: "Claude with eyes and web search.")
    ]

    private struct Response: Codable {
        let `default`: String
        let agents: [AgentInfo]
    }

    func refresh(from endpoint: URL = AppConfig.backendURL) async {
        var request = URLRequest(url: endpoint.appendingPathComponent("agents"))
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard !decoded.agents.isEmpty else { throw URLError(.zeroByteResource) }
            agents = decoded.agents
            defaultAgentId = decoded.default
            lastError = nil
            gblog("[AGENTS] \(decoded.agents.map { "\($0.wakePhrase) → \($0.id)" }.joined(separator: ", "))")
        } catch {
            lastError = error.localizedDescription
            gblog("[AGENTS] fetch failed, keeping \(agents.count) known: \(error.localizedDescription)")
        }
    }

    func agent(id: String) -> AgentInfo? {
        agents.first { $0.id == id }
    }

    var wakePhrases: [WakeWordListener.WakePhrase] {
        agents.map { WakeWordListener.WakePhrase(agentId: $0.id, phrase: $0.wakePhrase) }
    }
}
