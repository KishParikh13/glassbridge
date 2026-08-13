import Foundation
import ActivityKit

/// Thin wrapper around ActivityKit for the assistant's Live Activity. All calls
/// are no-ops when Live Activities are disabled/unavailable, so callers don't
/// have to guard.
@MainActor
final class LiveActivityController {
    private var activity: Activity<GlassbridgeActivityAttributes>?

    var isActive: Bool { activity != nil }

    func start(status: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let attributes = GlassbridgeActivityAttributes(sessionName: "Glassbridge")
        let state = GlassbridgeActivityAttributes.ContentState(status: status, detail: detail)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            activity = nil
        }
    }

    func update(status: String, detail: String) {
        guard let activity else { return }
        let state = GlassbridgeActivityAttributes.ContentState(status: status, detail: detail)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
