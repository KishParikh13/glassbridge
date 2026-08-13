import SwiftUI
import UIKit

// Stock SwiftUI `Form` throughout: system grouped background, system colours, standard
// row metrics, automatic light/dark. The redesign here is structural, not visual — what
// changed is which screen each thing lives on, not how it's painted.

// MARK: - Settings (top level)

/// State and proof. Everything configurable lives one level down, on the screen for the
/// thing it configures.
struct SetupView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @ObservedObject var wake: WakeWordListener
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !coordinator.hasCompletedOnboarding {
                    Section {
                        Text("Glassbridge works with just your iPhone. Connect Ray-Ban glasses to use them as the camera and mic instead.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                statusSection
                agentsSection
                handsFreeSection
                if !coordinator.recorder.recent.isEmpty { recentSection }
                selfTestSection

                Section {
                    NavigationLink("Advanced") {
                        AdvancedView(coordinator: coordinator, glasses: glasses, wake: wake)
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
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                coordinator.refreshPermissionStatuses()
                coordinator.refreshAudioRoute()
                glasses.refreshPermissions()
                coordinator.recorder.loadRecent()
                Task {
                    await coordinator.checkBackend()
                    await coordinator.refreshAgents()
                }
            }
        }
    }

    // MARK: Status

    /// Three rows, each the single source of truth for one thing, each pushing to its own
    /// screen. Replaces the old Phone permissions + Backend + Ray-Ban glasses sections and
    /// the capability matrix, which were four renderings of the same five facts.
    private var statusSection: some View {
        Section("Status") {
            NavigationLink {
                GlassesDetailView(coordinator: coordinator, glasses: glasses)
            } label: {
                LabeledContent("Ray-Ban glasses") {
                    Text(glassesStatus.0).foregroundStyle(glassesStatus.1)
                }
            }

            NavigationLink {
                PhoneDetailView(coordinator: coordinator)
            } label: {
                LabeledContent("iPhone") {
                    Text(phoneStatus.0).foregroundStyle(phoneStatus.1)
                }
            }

            NavigationLink {
                AgentDetailView(coordinator: coordinator)
            } label: {
                LabeledContent("Agent") {
                    Text(agentStatus.0).foregroundStyle(agentStatus.1)
                }
            }

            if !backendReachable {
                Button {
                    Task { await coordinator.checkBackend() }
                } label: {
                    if coordinator.isCheckingBackend {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Checking…")
                        }
                    } else {
                        Text("Check agent again")
                    }
                }
                .disabled(coordinator.isCheckingBackend)
            }
        }
    }

    private var backendReachable: Bool { coordinator.backendHealth?.reachable ?? false }

    private var glassesStatus: (String, Color) {
        switch glasses.connectionState {
        case .connected, .streaming: return ("Connected", .secondary)
        case .registering, .connecting: return ("Connecting…", .secondary)
        case .usingPhone, .readyToConnect: return ("Not connected", .secondary)
        default: return ("Needs setup", .orange)
        }
    }

    private var phoneStatus: (String, Color) {
        let all = coordinator.micPermission.isGranted
            && coordinator.cameraPermission.isGranted
            && coordinator.speechPermission.isGranted
        return all ? ("Allowed", .secondary) : ("Needs setup", .orange)
    }

    private var agentStatus: (String, Color) {
        backendReachable
            ? (coordinator.selectedModel.label, .secondary)
            : ("Unreachable", .orange)
    }

    // MARK: Agents

    /// Who you can talk to and the phrase that reaches each one.
    ///
    /// The list comes from the backend, so this is a view of configuration rather than of
    /// anything compiled into the app. Adding an assistant makes it appear here.
    @ViewBuilder
    private var agentsSection: some View {
        Section {
            ForEach(coordinator.agentDirectory.agents) { agent in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\u{201C}\(agent.wakePhrase)\u{201D}")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(agent.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if agent.acceptsImages {
                            Image(systemName: "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Agents")
        } footer: {
            if let error = coordinator.agentDirectory.lastError {
                Text("Couldn't reach the backend for the agent list, so only the built-in phrase is armed. \(error)")
            } else {
                Text("Configured on the backend in agents.json. An eye means that agent can see what you're looking at when you say \u{201C}look\u{201D}.")
            }
        }
    }

    // MARK: Hands-free

    private var handsFreeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { coordinator.wakeWordEnabled },
                set: { coordinator.setWakeWord($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake word")
                    Text("Say \u{201C}\(wake.triggerPhrase)\u{201D} to start, anytime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Three rows rather than the three-sentence paragraph this replaces.
            LabeledContent("\u{201C}look\u{201D}", value: "Attach what you see")
            LabeledContent("\u{201C}never mind\u{201D}", value: "Drop the turn")
            LabeledContent("\u{201C}stop\u{201D}", value: "Cut the reply short")
            LabeledContent("\u{201C}go to sleep\u{201D}", value: "Switch this off")
        } header: {
            Text("Hands-free")
        } footer: {
            Text("Listens on-device. Stays how you left it after a restart.")
        }
    }

    // MARK: Recent

    /// Every turn has been recorded with transcript, latency, and outcome since the
    /// recorder landed, and none of it was ever shown anywhere.
    private var recentSection: some View {
        Section("Recent") {
            ForEach(coordinator.recorder.recent.prefix(3)) { turn in
                VStack(alignment: .leading, spacing: 3) {
                    Text(turn.transcript.map { "\u{201C}\($0)\u{201D}" } ?? "Untranscribed ask")
                        .font(.callout)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(turn.startedAt, format: .relative(presentation: .numeric))
                        Text("·")
                        outcomeText(turn)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func outcomeText(_ turn: SessionRecorder.Recording) -> some View {
        if let outcome = turn.outcome, outcome.hasPrefix("error") {
            Text("failed").foregroundStyle(.orange)
        } else if turn.outcome == "cancelled" {
            Text("cancelled")
        } else if let stt = turn.sttLatency, let llm = turn.llmLatency {
            Text(String(format: "%.1fs", stt + llm))
        } else {
            Text("done")
        }
    }

    // MARK: Self test

    private var selfTestSection: some View {
        Section {
            Button("Run a test ask") {
                Task { await coordinator.runSelfTest() }
            }
        } footer: {
            Text("Proves capture, agent, and voice work together in one tap.")
        }
    }
}

// MARK: - Glasses detail

/// Connection, then what you can set, then what it's doing. Those were one section before,
/// which is why frame rate sat next to measured frame rate.
private struct GlassesDetailView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: glasses.connectionState.shortLabel)
                LabeledContent("Camera", value: glasses.cameraPermission)
                LabeledContent("Microphone", value: glasses.micPermission)
                actions
                if let err = glasses.lastError, !err.isEmpty {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(glasses.connectionState.detail + "\n\nEnable Developer Mode in the Meta AI app (Settings → your glasses), and wear them so they stay connected.")
            }

            Section("Camera") {
                Picker("Quality", selection: Binding(
                    get: { glasses.quality },
                    set: { glasses.applyStreamSettings(quality: $0, frameRate: glasses.frameRate) }
                )) {
                    ForEach(GlassesController.Quality.allCases, id: \.self) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                Picker("Frame rate", selection: Binding(
                    get: { glasses.frameRate },
                    set: { glasses.applyStreamSettings(quality: glasses.quality, frameRate: $0) }
                )) {
                    ForEach(GlassesController.frameRateOptions, id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
            }

            if glasses.isStreaming || glasses.lastPhotoLatencyMs != nil {
                Section("Live") {
                    if glasses.isStreaming {
                        LabeledContent("Measured", value: String(format: "%.1f fps", glasses.measuredFPS))
                        if !glasses.lastFrameSize.isEmpty {
                            LabeledContent("Frame size", value: glasses.lastFrameSize)
                        }
                    }
                    if let ms = glasses.lastPhotoLatencyMs {
                        LabeledContent("Last photo", value: "\(ms) ms")
                    }
                }
            }
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var actions: some View {
        switch glasses.connectionState {
        case .usingPhone, .readyToConnect, .metaAINotInstalled, .problem:
            Button("Connect glasses") { glasses.connect() }
        case .registering, .connecting:
            HStack(spacing: 8) {
                ProgressView()
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .needsDeviceUpdate:
            Button("Open update in Meta AI") { glasses.openFirmwareUpdate() }
        case .needsCameraPermission:
            Button("Allow camera & test") { Task { await glasses.testCameraOnce() } }
        case .connected:
            Button("Test camera") { Task { await glasses.testCameraOnce() } }
        case .streaming:
            Button("Disconnect glasses", role: .destructive) { glasses.unregister() }
        }
    }
}

// MARK: - Agent detail

/// What you're talking to, and what it can do. Capability rows are display-only for now;
/// each maps to something that already exists in the backend.
private struct AgentDetailView: View {
    @ObservedObject var coordinator: SessionCoordinator

    private struct Capability: Identifiable {
        let id = UUID()
        let icon: String
        let name: String
        let detail: String
        let on: Bool
    }

    private let capabilities: [Capability] = [
        .init(icon: "eye", name: "See",
              detail: "Reads the frame from your camera", on: true),
        .init(icon: "magnifyingglass", name: "Search the web",
              detail: "Looks things up mid-answer", on: true),
        .init(icon: "clock.arrow.circlepath", name: "Remember",
              detail: "Last 3 turns of this session", on: true),
        .init(icon: "speaker.wave.2", name: "Speak",
              detail: "Replies aloud through the glasses", on: true),
        .init(icon: "note.text", name: "Take notes",
              detail: "Files what you capture, no reply", on: false),
    ]

    var body: some View {
        Form {
            Section("Identity") {
                Picker("Model", selection: $coordinator.selectedModel) {
                    ForEach(SessionCoordinator.ClaudeModel.allCases) { model in
                        Text(model.menuLabel).tag(model)
                    }
                }
                LabeledContent("Runs on", value: AppConfig.backendURL.host ?? "unknown")
                LabeledContent("Status") {
                    Text(coordinator.backendHealth?.detail ?? "Not checked")
                        .foregroundStyle((coordinator.backendHealth?.reachable ?? false)
                                         ? Color.secondary : Color.orange)
                }
            }

            Section {
                ForEach(capabilities) { capability in
                    HStack(spacing: 12) {
                        Image(systemName: capability.icon)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capability.name)
                            Text(capability.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(capability.on ? "On" : "Off")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Can do")
            } footer: {
                Text("Sample list for now. Each maps to something the backend already does.")
            }
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - iPhone detail

private struct PhoneDetailView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(icon: "mic.fill", title: "Microphone",
                              subtitle: "Records your voice for an ask",
                              status: coordinator.micPermission) {
                    Task { await coordinator.requestMic() }
                }
                permissionRow(icon: "camera.fill", title: "Camera",
                              subtitle: "Used when the glasses aren't connected",
                              status: coordinator.cameraPermission) {
                    Task { await coordinator.requestCamera() }
                }
                permissionRow(icon: "waveform", title: "Speech recognition",
                              subtitle: "On-device wake word",
                              status: coordinator.speechPermission) {
                    Task { await coordinator.requestSpeech() }
                }
            }
        }
        .navigationTitle("iPhone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func permissionRow(icon: String, title: String, subtitle: String,
                               status: PermStatus, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(status == .denied ? "Settings" : "Allow") {
                    if status == .denied {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        request()
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
            }
        }
    }
}

// MARK: - Advanced (developer)

/// Everything that's a number rather than a decision. Unchanged in content; it just has
/// its own screen now instead of a disclosure group two thirds of the way down Settings.
private struct AdvancedView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @ObservedObject var wake: WakeWordListener
    @State private var loopbackSeconds: Double = 3

    var body: some View {
        Form {
            Section("Listener") {
                LabeledContent("State", value: wake.state.rawValue)
                if !wake.lastHeard.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last heard")
                        Text(wake.lastHeard)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Glasses camera", value: glasses.cameraPermission)
                LabeledContent("Glasses mic", value: glasses.micPermission)
                Button("Refresh permission status") { glasses.refreshPermissions() }
                Button("Request glasses mic") { glasses.requestMicPermission() }
            } header: {
                Text("Glasses permissions")
            } footer: {
                Text("Glasses camera permission is requested automatically when streaming starts.")
            }

            Section("Audio route") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Route")
                    Text(coordinator.audioRoute.isEmpty ? "Tap Refresh to read the current route." : coordinator.audioRoute)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !coordinator.availableInputs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inputs")
                        Text(coordinator.availableInputs)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Refresh") { coordinator.refreshAudioRoute() }
                Button("Activate") { Task { await coordinator.activateAudioRoute() } }
                Button("Deactivate") { coordinator.deactivateAudioRoute() }
            }

            Section("Microphone") {
                ProgressView(value: Double(coordinator.micLevel))
                    .tint(coordinator.micLevel > 0.8 ? .red : .green)
                Button(coordinator.isMonitoringMic ? "Stop mic meter" : "Start mic meter") {
                    Task { await coordinator.toggleMicMeter() }
                }
                .disabled(coordinator.isAudioBusy)
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

            Section {
                ForEach(combinedLog, id: \.self) { line in
                    Text(line).font(.system(.caption2, design: .monospaced))
                }
            } header: {
                HStack {
                    Text("Event log")
                    Spacer()
                    Button("Clear") { coordinator.clearDiagLog() }
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var combinedLog: [String] {
        Array((glasses.debugLog + coordinator.diagLog).suffix(60))
    }
}
