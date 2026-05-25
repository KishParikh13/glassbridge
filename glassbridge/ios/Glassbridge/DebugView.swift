import SwiftUI

/// A developer console for exercising every glasses control the DAT SDK exposes
/// and observing how well each works: connection/registration, permissions,
/// camera metrics, audio route + mic/speaker tests, and a live event log.
struct DebugView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @ObservedObject var wake: WakeWordListener
    @State private var loopbackSeconds: Double = 3

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                handsFreeSection
                permissionsSection
                cameraSection
                audioSection
                logSection
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { coordinator.refreshAudioRoute() }
        }
    }

    // MARK: – Connection / registration

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Status", value: glasses.status.rawValue)
            if let id = glasses.deviceId {
                LabeledContent("Device", value: String(id.prefix(14)) + "…")
            }
            if let err = glasses.lastError, !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Button("Pair / register glasses") { glasses.register() }
            Button("Unregister") { glasses.unregister() }
                .foregroundStyle(.orange)
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
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            Text("Listens on-device and starts an ASK when it hears the phrase. Shows a Live Activity on the lock screen while on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: – Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent("Camera", value: glasses.cameraPermission)
            LabeledContent("Microphone", value: glasses.micPermission)
            Button("Refresh status") { glasses.refreshPermissions() }
            Button("Request camera") { glasses.requestCameraPermissionAgain() }
            Button("Request microphone") { glasses.requestMicPermission() }
        }
    }

    // MARK: – Camera

    private var cameraSection: some View {
        Section("Camera") {
            LabeledContent("Quality", value: glasses.quality.label)
            LabeledContent("Frame rate", value: "\(glasses.frameRate) fps")
            if glasses.status == .streaming {
                LabeledContent("Measured", value: String(format: "%.1f fps", glasses.measuredFPS))
                if !glasses.lastFrameSize.isEmpty {
                    LabeledContent("Frame size", value: glasses.lastFrameSize)
                }
            }
            if let ms = glasses.lastPhotoLatencyMs {
                LabeledContent("Last photo capture", value: "\(ms) ms")
            }
            Text("Adjust quality and capture from the Camera tab.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: – Audio

    private var audioSection: some View {
        Section("Audio route") {
            if coordinator.audioRoute.isEmpty {
                Text("Tap Refresh to read the current route.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(coordinator.audioRoute)
                    .font(.system(.caption, design: .monospaced))
            }
            if !coordinator.availableInputs.isEmpty {
                LabeledContent("Available inputs") {
                    Text(coordinator.availableInputs)
                        .font(.system(.caption2, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
            }
            HStack {
                Button("Refresh") { coordinator.refreshAudioRoute() }
                Spacer()
                Button("Activate") { Task { await coordinator.activateAudioRoute() } }
                Spacer()
                Button("Deactivate") { coordinator.deactivateAudioRoute() }
            }
            .buttonStyle(.bordered)
            .font(.caption)

            // Mic level meter
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(coordinator.micLevel))
                    .tint(coordinator.micLevel > 0.8 ? .red : .green)
                Button(coordinator.isMonitoringMic ? "Stop mic meter" : "Start mic meter") {
                    Task { await coordinator.toggleMicMeter() }
                }
                .disabled(coordinator.isAudioBusy)
            }

            // End-to-end tests
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Loopback")
                    Slider(value: $loopbackSeconds, in: 1...5, step: 1)
                    Text("\(Int(loopbackSeconds))s").monospacedDigit()
                }
                Button("Record → play back") {
                    Task { await coordinator.runMicLoopback(seconds: loopbackSeconds) }
                }
                .disabled(coordinator.isAudioBusy || coordinator.isMonitoringMic)
                Button("Play speaker test tone") {
                    Task { await coordinator.playSpeakerTone() }
                }
                .disabled(coordinator.isAudioBusy || coordinator.isMonitoringMic)
            }
            .font(.caption)
        }
    }

    // MARK: – Logs

    private var logSection: some View {
        Section {
            ForEach(combinedLog, id: \.self) { line in
                Text(line).font(.system(.caption2, design: .monospaced))
            }
        } header: {
            HStack {
                Text("Event log")
                Spacer()
                Button("Clear") {
                    coordinator.clearDiagLog()
                }
                .font(.caption2)
            }
        }
    }

    /// Glasses SDK log + audio diagnostics log, newest last.
    private var combinedLog: [String] {
        let merged = glasses.debugLog + coordinator.diagLog
        return Array(merged.suffix(60))
    }
}
