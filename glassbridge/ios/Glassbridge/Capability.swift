import SwiftUI

/// One row in the capability matrix: what it is, whether it works right now, and
/// which hardware/source it runs on.
struct Capability: Identifiable {
    enum Status {
        case ready          // works now
        case glassesOnly    // needs the glasses stream to be live
        case needsPermission// a permission/connection is missing
        case unavailable    // can't work right now

        var text: String {
            switch self {
            case .ready: return "Ready"
            case .glassesOnly: return "Glasses only"
            case .needsPermission: return "Needs setup"
            case .unavailable: return "Unavailable"
            }
        }
        var color: Color {
            switch self {
            case .ready: return .green
            case .glassesOnly: return .blue
            case .needsPermission: return .orange
            case .unavailable: return .secondary
            }
        }
        var symbol: String {
            switch self {
            case .ready: return "checkmark.circle.fill"
            case .glassesOnly: return "eyeglasses"
            case .needsPermission: return "exclamationmark.triangle.fill"
            case .unavailable: return "xmark.circle"
            }
        }
    }

    let icon: String
    let name: String
    let status: Status
    let source: String

    var id: String { name }

    /// Build the full matrix from current state. One place that decides "what
    /// works and what it's connected to," so Live and Setup never disagree.
    static func all(
        connection: ConnectionState,
        micGranted: Bool,
        cameraGranted: Bool,
        speechGranted: Bool,
        backendReachable: Bool
    ) -> [Capability] {
        let glassesLive = connection.isGlassesLive
        let captureSource = glassesLive ? "Ray-Ban glasses" : "iPhone"
        let micSource = glassesLive ? "Glasses mic" : "iPhone mic"

        let voiceStatus: Status = {
            if !backendReachable { return .unavailable }
            if !micGranted { return .needsPermission }
            return .ready
        }()

        return [
            Capability(
                icon: "sparkles",
                name: "Voice Q&A (ASK)",
                status: voiceStatus,
                source: "\(micSource) + \(captureSource) cam → Claude"
            ),
            Capability(
                icon: "camera.fill",
                name: "Photo & Video",
                status: cameraGranted || glassesLive ? .ready : .needsPermission,
                source: captureSource + (glassesLive ? "" : " (upgrades to glasses)")
            ),
            Capability(
                icon: "dot.radiowaves.left.and.right",
                name: "Live preview",
                status: glassesLive ? .ready : .glassesOnly,
                source: "Ray-Ban glasses stream"
            ),
            Capability(
                icon: "clock.arrow.circlepath",
                name: "Rolling context",
                status: glassesLive ? .ready : .glassesOnly,
                source: "Ray-Ban glasses stream"
            ),
            Capability(
                icon: "mic.fill",
                name: "Wake word “hey glass”",
                status: speechGranted ? .ready : .needsPermission,
                source: "On-device (iPhone)"
            ),
            Capability(
                icon: "server.rack",
                name: "Backend (Claude)",
                status: backendReachable ? .ready : .unavailable,
                source: AppConfig.backendURL.host.map { "Mac @ \($0)" } ?? "Mac"
            ),
        ]
    }
}

/// Compact table rendering of the capability matrix.
struct CapabilityMatrixView: View {
    let items: [Capability]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { cap in
                HStack(spacing: 12) {
                    Image(systemName: cap.icon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cap.name).font(.subheadline.weight(.medium))
                        Text(cap.source).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(cap.status.text, systemImage: cap.status.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(cap.status.color)
                }
                .padding(.vertical, 8)
                if cap.id != items.last?.id {
                    Divider()
                }
            }
        }
    }
}
