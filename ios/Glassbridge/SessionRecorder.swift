import Foundation

/// Timestamped record of what one turn actually did.
///
/// This exists because most of what the app decides is inaudible. You can hear the
/// earcons on a video's audio track, but you cannot hear which commands were armed, when
/// the recording endpointed, or that the word "stop" was heard and deliberately ignored
/// because a reply had not started yet. Those are the decisions worth showing, and this is
/// the only place they leave a trace.
///
/// It is also the instrument for the hardware validation pass. "The wake word didn't fire"
/// has at least three causes that feel identical while you are wearing the glasses: the
/// mic never left the iPhone, the recognizer misheard, or it heard you correctly and the
/// scope said no. The log tells them apart.
@MainActor
final class SessionRecorder: ObservableObject {

    struct Event: Codable {
        /// Seconds since the turn began.
        var at: TimeInterval
        var kind: Kind
        var label: String
        /// Transcript, route description, error text.
        var detail: String?
        /// For a recognized phrase: whether the scope allowed it to fire.
        var armed: Bool?
        /// What the listener was armed for at that instant.
        var scope: String?

        enum Kind: String, Codable {
            case turn, phase, command, heard, earcon, capture, recording, backend, route
        }
    }

    struct Recording: Codable, Identifiable {
        var id: UUID
        var startedAt: Date
        var route: String
        var events: [Event]
        var transcript: String?
        var reply: String?
        var sttLatency: Double?
        var llmLatency: Double?
        var outcome: String?
    }

    @Published private(set) var isRecording = false
    /// Kept in memory for the diagnostics panel. The JSON on disk is the real artifact.
    @Published private(set) var lastRecording: Recording?
    /// Newest first, for the Recent list in Settings. The app records every turn and
    /// never showed any of it, which made "is this working" a question you could only
    /// answer by trying it again.
    @Published private(set) var recent: [Recording] = []

    private var current: Recording?
    private var startedAtUptime: TimeInterval = 0

    /// Where finished recordings land. Documents rather than temp so they survive, and so
    /// `UIFileSharingEnabled` surfaces them in Files.app for AirDrop off the device
    /// without needing to tether to Xcode mid-test.
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Lifecycle

    func begin(route: String) {
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        current = Recording(
            id: UUID(),
            startedAt: Date(),
            route: route,
            events: [],
            transcript: nil,
            reply: nil,
            sttLatency: nil,
            llmLatency: nil,
            outcome: nil
        )
        isRecording = true
        log(.turn, "turn started")
        log(.route, "route", detail: route)
    }

    func finish(outcome: String, transcript: String?, reply: String?, stt: Double?, llm: Double?) {
        guard current != nil else { return }
        log(.turn, "turn ended", detail: outcome)
        guard var recording = current else { return }
        recording.outcome = outcome
        recording.transcript = transcript
        recording.reply = reply
        recording.sttLatency = stt
        recording.llmLatency = llm

        current = nil
        isRecording = false
        lastRecording = recording
        write(recording)
    }

    // MARK: - Events

    func log(_ kind: Event.Kind,
             _ label: String,
             detail: String? = nil,
             armed: Bool? = nil,
             scope: String? = nil) {
        guard current != nil else { return }
        let event = Event(
            at: ProcessInfo.processInfo.systemUptime - startedAtUptime,
            kind: kind,
            label: label,
            detail: detail,
            armed: armed,
            scope: scope
        )
        current?.events.append(event)
        gblog(String(format: "[REC] %6.2fs %@ %@%@%@",
                     event.at,
                     kind.rawValue,
                     label,
                     detail.map { " · \($0)" } ?? "",
                     armed == false ? " [NOT ARMED, scope=\(scope ?? "?")]" : ""))
    }

    // MARK: - Export

    private func write(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let stamp = ISO8601DateFormatter().string(from: recording.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.directory.appendingPathComponent("turn-\(stamp).json")
        do {
            try encoder.encode(recording).write(to: url)
            gblog("[REC] wrote \(url.lastPathComponent) (\(recording.events.count) events)")
            loadRecent()
        } catch {
            gblog("[REC] write failed: \(error.localizedDescription)")
        }
    }

    /// Read the newest recordings back off disk. Cheap: these are a few KB each and the
    /// list is capped.
    func loadRecent(limit: Int = 6) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        recent = Self.saved().prefix(limit).compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Recording.self, from: data)
        }
    }

    /// Every recording on disk, newest first. The validation pass produces a folder of
    /// these and the case study timeline reads them straight.
    static func saved() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }
}
