import SwiftUI
import UIKit

/// Guided setup: walks every permission and the glasses connection, each with live
/// status and a fix action, then shows the capability matrix. Skippable — the
/// iPhone path works without finishing it.
struct SetupView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set up Glassbridge")
                            .font(.title2.weight(.bold))
                        Text("Glassbridge works with just your iPhone. Connect Ray-Ban glasses to use them as the camera and mic instead. Grant the permissions below, then connect your glasses.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                permissionsSection
                backendSection
                glassesSection

                Section("What works now") {
                    CapabilityMatrixView(items: coordinator.capabilities())
                        .padding(.vertical, 4)
                }

                Section {
                    Button {
                        coordinator.completeOnboarding()
                    } label: {
                        Text(coordinator.hasCompletedOnboarding ? "Done" : "Finish setup")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                coordinator.refreshPermissionStatuses()
                Task { await coordinator.checkBackend() }
            }
        }
    }

    // MARK: – Phone permissions

    private var permissionsSection: some View {
        Section("Phone permissions") {
            permissionRow(
                icon: "mic.fill", title: "Microphone",
                subtitle: "Record your voice for ASK", status: coordinator.micPermission
            ) { Task { await coordinator.requestMic() } }

            permissionRow(
                icon: "camera.fill", title: "Camera",
                subtitle: "iPhone camera when glasses aren't connected", status: coordinator.cameraPermission
            ) { Task { await coordinator.requestCamera() } }

            permissionRow(
                icon: "waveform", title: "Speech recognition",
                subtitle: "On-device wake word (optional)", status: coordinator.speechPermission
            ) { Task { await coordinator.requestSpeech() } }
        }
    }

    private func permissionRow(icon: String, title: String, subtitle: String,
                               status: PermStatus, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if status.isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green).labelStyle(.iconOnly)
            } else {
                Button(status == .denied ? "Settings" : "Allow") {
                    if status == .denied { openSettings() } else { request() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: – Backend

    private var backendSection: some View {
        Section("Backend (Claude)") {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").frame(width: 24).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppConfig.backendURL.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    if let r = coordinator.backendHealth {
                        Text(r.detail).font(.caption2)
                            .foregroundStyle(r.reachable ? .green : .red)
                    } else {
                        Text("Not checked yet").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if coordinator.isCheckingBackend {
                    ProgressView()
                } else {
                    Button("Check") { Task { await coordinator.checkBackend() } }
                        .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: – Glasses

    private var glassesSection: some View {
        Section("Ray-Ban glasses") {
            HStack(spacing: 12) {
                Image(systemName: glasses.connectionState.isGlassesLive ? "eyeglasses" : "eyeglasses")
                    .frame(width: 24).foregroundStyle(glasses.connectionState.isGlassesLive ? .green : .secondary)
                Text(glasses.connectionState.shortLabel).font(.subheadline.weight(.medium))
                Spacer()
                if glasses.connectionState.isGlassesLive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Text(glasses.connectionState.detail)
                .font(.caption).foregroundStyle(.secondary)

            glassesActions

            if let err = glasses.lastError, !err.isEmpty {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
            Text("Tip: enable Developer Mode in the Meta AI app (Settings → your glasses), and put the glasses on so they're connected.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var glassesActions: some View {
        switch glasses.connectionState {
        case .usingPhone, .readyToConnect, .metaAINotInstalled, .problem:
            Button("Connect glasses") { glasses.connect() }
                .buttonStyle(.borderedProminent).font(.subheadline.weight(.semibold))
        case .registering, .connecting:
            HStack { ProgressView(); Text("Connecting…").font(.caption).foregroundStyle(.secondary) }
        case .needsDeviceUpdate:
            Button("Open update in Meta AI") { glasses.openFirmwareUpdate() }
                .buttonStyle(.borderedProminent).tint(.orange).font(.subheadline.weight(.semibold))
        case .needsCameraPermission:
            Button("Allow camera & test") { Task { await glasses.startStreaming() } }
                .buttonStyle(.borderedProminent).font(.subheadline.weight(.semibold))
        case .connected:
            Button("Test connection") { Task { await glasses.startStreaming() } }
                .buttonStyle(.borderedProminent).font(.subheadline.weight(.semibold))
        case .streaming:
            Button("Disconnect glasses", role: .destructive) { glasses.unregister() }
                .font(.subheadline)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
