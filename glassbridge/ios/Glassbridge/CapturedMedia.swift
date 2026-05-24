import Foundation

/// One item in the Camera tab's in-app gallery: a still photo (JPEG bytes) or a
/// recorded video (file URL on disk).
struct CapturedMedia: Identifiable {
    enum Kind {
        case photo(Data)
        case video(URL)
    }

    enum Source: String {
        case glasses = "Glasses"
        case iPhone = "iPhone"
    }

    let id = UUID()
    let kind: Kind
    let source: Source
    let date: Date

    var isVideo: Bool {
        if case .video = kind { return true }
        return false
    }

    /// Backing file URL for videos, so it can be cleaned up on clear.
    var videoURL: URL? {
        if case .video(let url) = kind { return url }
        return nil
    }
}
