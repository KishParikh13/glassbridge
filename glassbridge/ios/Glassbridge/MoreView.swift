import SwiftUI

/// Connection details, hands-free, camera settings, and an Advanced (Developer)
/// disclosure that retains every diagnostic the old Debug tab had: glasses
/// permissions, audio route + mic meter + loopback + test tone, and the event log.
struct MoreView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @ObservedObject var wake: WakeWordListener
    @State private var loopbackSeconds: Double = 3
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                handsFreeSection
                cameraSection
                Section {
                    DisclosureGroup("Advanced (Developer)", isExpanded: $showAdvanced) {
                        permissionsGroup
                        audioGroup
                        logGroup
                    }
                }
                Section {
                    Button("Re-run setup") { coordinator.restartOnboarding() }
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { coordinator.refreshAudioRoute(); glasses.refreshPermissions() }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Status", value: glasses.connectionState.shortLabel)
            if let id = glasses.deviceId {
                LabeledContent("Device", value: String(id.prefix(14)) + "…")
            }
            if let err = glasses.lastError, !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            switch glasses.connectionState {
            case .streaming, .connected:
                Button("Disconnect glasses", role: .destructive) { glasses.unregister() }
            case .needsDeviceUpdate:
                Button("Open update in Meta AI") { glasses.openFirmwareUpdate() }
            default:
                Button("Connect glasses") { glasses.connect() }
            }
        }
    }

    // MARK: Hands-free

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
            Text("Listens on-device and starts an ASK when it hears the phrase. Shows a Live Activity on the lock screen while on.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Camera settings

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

    // MARK: Advanced — permissions

    @ViewBuilder
    private var permissionsGroup: some View {
        LabeledContent("Glasses camera", value: glasses.cameraPermission)
        LabeledContent("Glasses mic", value: glasses.micPermission)
        Button("Refresh permission status") { glasses.refreshPermissions() }
        Button("Request glasses mic") { glasses.requestMicPermission() }
        Text("Glasses camera permission is requested automatically when streaming starts.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Advanced — audio

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

    // MARK: Advanced — log

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
}
