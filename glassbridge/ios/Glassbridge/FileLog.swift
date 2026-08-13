import Foundation

/// Append-only log on the device, next to the turn recordings.
///
/// Console output is not good enough for this app. `print()` goes to stdout, which the
/// device syslog does not capture, and a stdout-attached launch dies the moment the app
/// goes to background. Field testing this thing means walking around with the phone in a
/// pocket, so anything worth knowing has to survive on disk and come off over the cable
/// afterward.
///
/// It also catches what the turn recordings structurally cannot: failures outside a turn,
/// like a direct photo capture that never got far enough to start one.
enum FileLog {
    private static let queue = DispatchQueue(label: "com.kish.glassbridge.filelog")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()

    static var url: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("glassbridge.log")
    }

    static func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}

/// Print and persist. Everything worth reading after the fact goes through here.
func gblog(_ line: String) {
    print(line)
    FileLog.write(line)
}
