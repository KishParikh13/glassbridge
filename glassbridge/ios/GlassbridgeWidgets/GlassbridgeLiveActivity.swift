import WidgetKit
import SwiftUI
import ActivityKit

/// Lock-screen + Dynamic Island presentation of the assistant's state.
struct GlassbridgeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlassbridgeActivityAttributes.self) { context in
            lockScreen(context.state)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(context.state.status))
                        .foregroundStyle(tint(context.state.status))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint(context.state.status))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.detail.isEmpty {
                        Text(context.state.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "eyeglasses")
            } compactTrailing: {
                Text(context.state.status)
                    .font(.caption2)
                    .foregroundStyle(tint(context.state.status))
            } minimal: {
                Image(systemName: icon(context.state.status))
                    .foregroundStyle(tint(context.state.status))
            }
        }
    }

    private func lockScreen(_ state: GlassbridgeActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(state.status))
                .font(.title2)
                .foregroundStyle(tint(state.status))
            VStack(alignment: .leading, spacing: 2) {
                Text("Glassbridge · \(state.status)")
                    .font(.headline)
                    .foregroundStyle(.white)
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
        }
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "Listening": return "mic.fill"
        case "Thinking": return "brain.head.profile"
        case "Speaking": return "speaker.wave.2.fill"
        case "Error": return "exclamationmark.triangle.fill"
        default: return "eyeglasses"
        }
    }

    private func tint(_ status: String) -> Color {
        switch status {
        case "Listening": return .red
        case "Thinking": return .orange
        case "Speaking": return .green
        case "Error": return .gray
        default: return .blue
        }
    }
}
