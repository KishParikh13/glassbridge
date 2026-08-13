import SwiftUI
import UIKit

/// Combined setup + settings page. Uses the guided-setup structure (permissions,
/// backend, glasses, capability matrix) and folds in the ongoing settings that
/// used to live in a separate More tab: hands-free, camera, and developer tools.
struct SetupView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @ObservedObject var wake: WakeWordListener
    @Environment(\.dismiss) private var dismiss
    @State private var loopbackSeconds: Double = 3
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                introSection
                permissionsSection
                backendSection
                glassesSection
                handsFreeSection
                cameraSection

                Section("What works now") {
                    CapabilityMatrixView(items: coordinator.capabilities())
                        .padding(.vertical, 4)
                }

                Section {
                    DisclosureGroup("Advanced (Developer)", isExpanded: $showAdvanced) {
                        permissionsGroup
                        audioGroup
                        logGroup
                    }
                }

                if !coordinator.hasCompletedOnboarding {
                    Section {
                        Button {
                            coordinator.completeOnboarding()
                            dismiss()
                        } label: {
                            Text("Finish setup")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        coordinator.completeOnboarding()
                        dismiss()
                    }
                }
            }
            .onAppear {
                coordinator.refreshPermissionStatuses()
                coordinator.refreshAudioRoute()
                glasses.refreshPermissions()
                Task { await coordinator.checkBackend() }
            }
        }
    }

    // MARK: – Intro

    private var introSection: some View {
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
                Image(systemName: "eyeglasses")
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
            Button("Allow camera & test") { Task { await glasses.testCameraOnce() } }
                .buttonStyle(.borderedProminent).font(.subheadline.weight(.semibold))
        case .connected:
            Button("Test camera") { Task { await glasses.testCameraOnce() } }
                .buttonStyle(.borderedProminent).font(.subheadline.weight(.semibold))
        case .streaming:
            Button("Disconnect glasses", role: .destructive) { glasses.unregister() }
                .font(.subheadline)
        }
    }

    // MARK: – Hands-free

    private var handsFreeSection: some View {
        Section("Hands-free") {
            Toggle(isOn: Binding(
                get: { coordinator.wakeWordEnabled },
                set: { coordinator.setWakeWord($0) }
            )) {
                Text("Wake word \u{201C}\(wake.triggerPhrase)\u{201D}")
            }
            LabeledContent("Listener", value: wake.state.rawValue)
            if coordinator.wakeWordEnabled && !wake.lastHeard.isEmpty {
                LabeledContent("Heard") {
                    Text(wake.lastHeard)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
            Text("Listens on-device and starts an ASK when it hears the phrase. While one is running, say \u{201C}never mind\u{201D} to drop it or \u{201C}stop\u{201D} to cut a reply short. \u{201C}Go to sleep\u{201D} switches this off without touching the phone, and it stays how you left it after a restart. Shows a Live Activity on the lock screen while on.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: – Camera settings

    private var cameraSection: some View {
        Section("Camera") {
            Menu {
                ForEach(GlassesController.Quality.allCases, id: \.self) { q in
                    Button(q.label) { glasses.applyStreamSettings(quality: q, frameRate: glasses.frameRate) }
                }
            } label: {
                LabeledContent("Quality", value: glasses.quality.label)
            }
            Menu {
                ForEach(GlassesController.frameRateOptions, id: \.self) { f in
                    Button("\(f) fps") { glasses.applyStreamSettings(quality: glasses.quality, frameRate: f) }
                }
            } label: {
                LabeledContent("Frame rate", value: "\(glasses.frameRate) fps")
            }
            if glasses.isStreaming {
                LabeledContent("Measured", value: String(format: "%.1f fps", glasses.measuredFPS))
                if !glasses.lastFrameSize.isEmpty {
                    LabeledContent("Frame size", value: glasses.lastFrameSize)
                }
            }
            if let ms = glasses.lastPhotoLatencyMs {
                LabeledContent("Last photo capture", value: "\(ms) ms")
            }
        }
    }

    // MARK: – Advanced: glasses permissions detail

    @ViewBuilder
    private var permissionsGroup: some View {
        LabeledContent("Glasses camera", value: glasses.cameraPermission)
        LabeledContent("Glasses mic", value: glasses.micPermission)
        Button("Refresh permission status") { glasses.refreshPermissions() }
        Button("Request glasses mic") { glasses.requestMicPermission() }
        Text("Glasses camera permission is requested automatically when streaming starts.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: – Advanced: audio diagnostics

    @ViewBuilder
    private var audioGroup: some View {
        if coordinator.audioRoute.isEmpty {
            Text("Tap Refresh to read the current route.").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(coordinator.audioRoute).font(.system(.caption, design: .monospaced))
        }
        if !coordinator.availableInputs.isEmpty {
            LabeledContent("Inputs") {
                Text(coordinator.availableInputs)
                    .font(.system(.caption2, design: .monospaced)).multilineTextAlignment(.trailing)
            }
        }
        HStack {
            Button("Refresh") { coordinator.refreshAudioRoute() }
            Spacer()
            Button("Activate") { Task { await coordinator.activateAudioRoute() } }
            Spacer()
            Button("Deactivate") { coordinator.deactivateAudioRoute() }
        }
        .buttonStyle(.bordered).font(.caption)

        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(coordinator.micLevel))
                .tint(coordinator.micLevel > 0.8 ? .red : .green)
            Button(coordinator.isMonitoringMic ? "Stop mic meter" : "Start mic meter") {
                Task { await coordinator.toggleMicMeter() }
            }
            .disabled(coordinator.isAudioBusy)
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Loopback")
                Slider(value: $loopbackSeconds, in: 1...5, step: 1)
                Text("\(Int(loopbackSeconds))s").monospacedDigit()
            }
            Button("Record → play back") { Task { await coordinator.runMicLoopback(seconds: loopbackSeconds) } }
                .disabled(coordinator.isAudioBusy || coordinator.isMonitoringMic)
            Button("Play speaker test tone") { Task { await coordinator.playSpeakerTone() } }
                .disabled(coordinator.isAudioBusy || coordinator.isMonitoringMic)
        }
        .font(.caption)
    }

    // MARK: – Advanced: event log

    @ViewBuilder
    private var logGroup: some View {
        HStack {
            Text("Event log").font(.caption.weight(.semibold))
            Spacer()
            Button("Clear") { coordinator.clearDiagLog() }.font(.caption2)
        }
        ForEach(combinedLog, id: \.self) { line in
            Text(line).font(.system(.caption2, design: .monospaced))
        }
    }

    private var combinedLog: [String] {
        Array((glasses.debugLog + coordinator.diagLog).suffix(60))
    }

    // MARK: – Helpers

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
