import Foundation

struct BackendReply {
    let mp3: Data
    let transcript: String?
    let reply: String?
    let language: String?
    let sttLatency: Double?
    let llmLatency: Double?
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
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 90
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    /// Multipart POST: audio (wav) + image (jpeg). Returns the full MP3 + headers.
    /// `textOverride` skips backend STT when non-nil — used by the simulator E2E test.
    func ask(
        audioURL: URL? = nil,
        audioData: Data? = nil,
        imageJPEG: Data,
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
            llmLatency: h("X-Glassbridge-Latency-Llm").flatMap(Double.init)
        )
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
