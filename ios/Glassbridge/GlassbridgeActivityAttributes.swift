import ActivityKit

/// Shared between the app and the widget extension. Describes the Live Activity
/// that shows assistant state on the lock screen / Dynamic Island while the
/// hands-free (wake-word) session is running.
struct GlassbridgeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String   // Ready / Listening / Thinking / Speaking / Error
        var detail: String
    }

    var sessionName: String
}
