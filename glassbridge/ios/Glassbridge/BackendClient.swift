import Foundation

struct BackendReply {
    let mp3: Data
    let transcript: String?
    let reply: String?
    let language: String?
    let sttLatency: Double?
    let llmLatency: Double?
    let tools: String?
}

// MARK: – Claude Code voice control

/// One Claude Code session the user can pick by voice or tap.
struct CodeSessionSummary: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    var driver: String? = nil
    var turn_count: Int? = nil
}

/// Result of one /code/voice turn: the agent's spoken reply (mp3) plus the
/// action taken, the now-active session, and a fresh session list.
struct CodeVoiceReply {
    let mp3: Data
    let action: String?
    let transcript: String?
    let reply: String?
    let activeSessionId: String?
    let sessions: [CodeSessionSummary]
    let tools: String?
    let sttLatency: Double?
    let agentLatency: Double?
}

enum BackendError: LocalizedError {
    case http(Int, String)
    case transport(Error)
    case malformed

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Backend HTTP \(code): \(body.prefix(180))"
        case .transport(let err): return "Backend transport: \(err.localizedDescription)"
        case .malformed: return "Backend returned malformed response."
        }
    }
}

final class BackendClient {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = AppConfig.backendURL) {
        self.endpoint = endpoint
        let cfg = URLSessionConfiguration.ephemeral
        // Generous: a Claude Code agent turn can run for a while before it replies.
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    /// Multipart POST: audio (wav) + image (jpeg). Returns the full MP3 + headers.
    /// `textOverride` skips backend STT when non-nil — used by the simulator E2E test.
    func ask(
        audioURL: URL? = nil,
        audioData: Data? = nil,
        imageJPEG: Data,
        contextFramesJPEG: [Data] = [],
        sessionId: String,
        textOverride: String? = nil
    ) async throws -> BackendReply {
        let askURL = endpoint.appendingPathComponent("ask")
        let boundary = "----glassbridge-\(UUID().uuidString)"

        var request = URLRequest(url: askURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let finalAudio: Data
        if let audioData {
            finalAudio = audioData
        } else if let audioURL {
            finalAudio = try Data(contentsOf: audioURL)
        } else {
            throw BackendError.malformed
        }
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "session_id", value: sessionId)
        if let textOverride {
            body.appendMultipart(boundary: boundary, name: "text_override", value: textOverride)
        }
        body.appendMultipartFile(
            boundary: boundary,
            name: "audio",
            filename: "capture.wav",
            contentType: "audio/wav",
            data: finalAudio
        )
        body.appendMultipartFile(
            boundary: boundary,
            name: "image",
            filename: "frame.jpg",
            contentType: "image/jpeg",
            data: imageJPEG
        )
        for (i, frame) in contextFramesJPEG.enumerated() {
            body.appendMultipartFile(
                boundary: boundary,
                name: "context_frames",
                filename: "context-\(i).jpg",
                contentType: "image/jpeg",
                data: frame
            )
        }
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.malformed }
        if http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw BackendError.http(http.statusCode, body)
        }
        // HTTPURLResponse.allHeaderFields casing is undefined across iOS versions.
        // value(forHTTPHeaderField:) is the case-insensitive accessor.
        func h(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        func hDecoded(_ name: String) -> String? {
            h(name).flatMap { $0.removingPercentEncoding ?? $0 }
        }
        return BackendReply(
            mp3: data,
            transcript: hDecoded("X-Glassbridge-Transcript"),
            reply: hDecoded("X-Glassbridge-Reply"),
            language: h("X-Glassbridge-Lang"),
            sttLatency: h("X-Glassbridge-Latency-Stt").flatMap(Double.init),
            llmLatency: h("X-Glassbridge-Latency-Llm").flatMap(Double.init),
            tools: hDecoded("X-Glassbridge-Tools")
        )
    }

    // MARK: – Claude Code session endpoints

    /// GET /code/sessions — the active Claude Code sessions.
    func listCodeSessions() async throws -> [CodeSessionSummary] {
        let url = endpoint.appendingPathComponent("code/sessions")
        let (data, response) = try await send(URLRequest(url: url))
        try Self.checkStatus(response, data)
        struct Wrapper: Codable { let sessions: [CodeSessionSummary] }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else {
            throw BackendError.malformed
        }
        return w.sessions
    }

    /// POST /code/sessions — start a new session, optionally titled.
    @discardableResult
    func createCodeSession(title: String? = nil) async throws -> CodeSessionSummary {
        let url = endpoint.appendingPathComponent("code/sessions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = title.map { ["title": $0] } ?? [:]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await send(request)
        try Self.checkStatus(response, data)
        guard let s = try? JSONDecoder().decode(CodeSessionSummary.self, from: data) else {
            throw BackendError.malformed
        }
        return s
    }

    /// POST /code/voice — multipart audio (wav). Backend transcribes, routes the
    /// command or forwards to the active session, and streams back the spoken reply.
    func codeVoice(
        audioURL: URL? = nil,
        audioData: Data? = nil,
        sessionId: String?,
        textOverride: String? = nil
    ) async throws -> CodeVoiceReply {
        let url = endpoint.appendingPathComponent("code/voice")
        let boundary = "----glassbridge-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let finalAudio: Data
        if let audioData {
            finalAudio = audioData
        } else if let audioURL {
            finalAudio = try Data(contentsOf: audioURL)
        } else {
            finalAudio = Data()  // text_override path doesn't need real audio
        }

        var body = Data()
        if let sessionId { body.appendMultipart(boundary: boundary, name: "session_id", value: sessionId) }
        if let textOverride { body.appendMultipart(boundary: boundary, name: "text_override", value: textOverride) }
        body.appendMultipartFile(
            boundary: boundary, name: "audio", filename: "capture.wav",
            contentType: "audio/wav", data: finalAudio
        )
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await send(request)
        try Self.checkStatus(response, data)
        guard let http = response as? HTTPURLResponse else { throw BackendError.malformed }
        func h(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        func hDecoded(_ name: String) -> String? { h(name).flatMap { $0.removingPercentEncoding ?? $0 } }

        var sessions: [CodeSessionSummary] = []
        if let raw = hDecoded("X-Code-Sessions"), let d = raw.data(using: .utf8) {
            struct Lite: Codable { let id: String; let title: String }
            if let lite = try? JSONDecoder().decode([Lite].self, from: d) {
                sessions = lite.map { CodeSessionSummary(id: $0.id, title: $0.title) }
            }
        }
        return CodeVoiceReply(
            mp3: data,
            action: h("X-Code-Action"),
            transcript: hDecoded("X-Code-Transcript"),
            reply: hDecoded("X-Code-Reply"),
            activeSessionId: h("X-Code-Active").flatMap { $0.isEmpty ? nil : $0 },
            sessions: sessions,
            tools: hDecoded("X-Code-Tools"),
            sttLatency: h("X-Code-Latency-Stt").flatMap(Double.init),
            agentLatency: h("X-Code-Latency-Agent").flatMap(Double.init)
        )
    }

    // MARK: – Shared transport

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw BackendError.transport(error)
        }
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError.malformed }
        if http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw BackendError.http(http.statusCode, body)
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }
    mutating func appendMultipartFile(
        boundary: String, name: String, filename: String, contentType: String, data: Data
    ) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        append(data)
        append("\r\n")
    }
}

private extension Dictionary where Key == String, Value == String {
    func glassbridgeHeader(_ name: String) -> String? {
        guard let raw = self[name] else { return nil }
        return raw.removingPercentEncoding ?? raw
    }
}
