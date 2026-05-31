import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = SessionCoordinator()

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            AssistantView(coordinator: coordinator)
                .tabItem { Label("Assistant", systemImage: "sparkles") }
                .tag(SessionCoordinator.Tab.assistant)
            CodeView(coordinator: coordinator)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(SessionCoordinator.Tab.code)
            CameraView(coordinator: coordinator, glasses: coordinator.glasses)
                .tabItem { Label("Camera", systemImage: "camera") }
                .tag(SessionCoordinator.Tab.camera)
            DebugView(coordinator: coordinator, glasses: coordinator.glasses, wake: coordinator.wake)
                .tabItem { Label("Debug", systemImage: "ladybug") }
                .tag(SessionCoordinator.Tab.debug)
        }
    }
}

struct AssistantView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 16) {
            header
            Spacer(minLength: 8)
            askButton
            phaseLabel
            replyArea
            Spacer(minLength: 8)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .sheet(isPresented: $showAdvanced) {
            advancedSheet
        }
    }

    // MARK: – Pieces

    private var header: some View {
        VStack(spacing: 6) {
            Text("Glassbridge")
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .padding(.top, 24)
            Text(captureModeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var askButton: some View {
        Button(action: { Task { await coordinator.askPressed() } }) {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: 200, height: 200)
                    .shadow(color: buttonColor.opacity(0.4), radius: 14, y: 4)
                Text("ASK")
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(buttonDisabled ? 0.98 : 1.0)
        .animation(.easeOut(duration: 0.15), value: coordinator.phase)
        .disabled(buttonDisabled)
        .opacity(buttonDisabled ? 0.85 : 1.0)
    }

    private var phaseLabel: some View {
        VStack(spacing: 4) {
            Text(phaseTitle)
                .font(.title3.weight(.semibold))
            if !phaseSubtitle.isEmpty {
                Text(phaseSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var replyArea: some View {
        if coordinator.reply.isEmpty && coordinator.transcript.isEmpty
            && coordinator.phase == .idle {
            // No prior ASK yet: friendly empty state.
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("Point your camera at something and tap ASK.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !coordinator.transcript.isEmpty {
                    bubble(label: "YOU", text: coordinator.transcript, accent: .blue)
                } else if !coordinator.reply.isEmpty {
                    bubble(label: "YOU", text: "(I didn't catch what you said)", accent: .gray, italic: true)
                }
                if !coordinator.reply.isEmpty {
                    bubble(label: "CLAUDE", text: coordinator.reply, accent: .purple, markdown: true)
                }
                if !coordinator.latencySummary.isEmpty {
                    Text(coordinator.latencySummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bubble(label: String, text: String,
                        accent: Color, italic: Bool = false, markdown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(accent)
            Group {
                if markdown,
                   let attributed = try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                   ) {
                    Text(attributed).font(.body)
                } else {
                    Text(text)
                        .font(.body)
                        .italic(italic)
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { coordinator.wakeWordEnabled },
                set: { coordinator.setWakeWord($0) }
            )) {
                Label("Hands-free", systemImage: coordinator.wakeWordEnabled ? "mic.fill" : "mic")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .tint(coordinator.wakeWordEnabled ? .red : .secondary)
            Spacer()
            Button {
                showAdvanced = true
            } label: {
                Label("Advanced", systemImage: "gearshape")
                    .font(.caption)
            }
            .tint(.secondary)
        }
    }

    @ViewBuilder
    private var advancedSheet: some View {
        NavigationStack {
            Form {
                Section("Capture mode") {
                    LabeledContent("Active source", value: captureModeText)
                    LabeledContent("Glasses status", value: coordinator.glasses.status.rawValue)
                    if let id = coordinator.glasses.deviceId {
                        LabeledContent("Device ID", value: String(id.prefix(12)) + "…")
                    }
                    LabeledContent("Camera permission", value: coordinator.glasses.cameraPermission)
                }
                Section("Pair Ray-Ban glasses (optional)") {
                    Button("Pair / register glasses") { coordinator.glasses.register() }
                    if coordinator.glasses.status == .registered {
                        Button("Re-request camera permission") {
                            coordinator.glasses.requestCameraPermissionAgain()
                        }
                    }
                    if let err = coordinator.glasses.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("If pairing works, the app will switch from iPhone camera + mic to your glasses automatically.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !coordinator.glasses.debugLog.isEmpty {
                    Section("Debug log") {
                        ForEach(coordinator.glasses.debugLog, id: \.self) { line in
                            Text(line).font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAdvanced = false }
                }
            }
        }
    }

    // MARK: – Derived

    private var captureModeText: String {
        if coordinator.glasses.status == .streaming {
            return "Ray-Ban glasses"
        }
        return "iPhone camera + iPhone mic"
    }

    private var phaseTitle: String {
        switch coordinator.phase {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        case .error: return "Something went wrong"
        }
    }

    private var phaseSubtitle: String {
        switch coordinator.phase {
        case .idle: return ""
        case .listening: return "Speak for up to 5 seconds"
        case .thinking: return "Sending to Claude with what your camera sees"
        case .speaking: return "Playing Claude's reply"
        case .error(let msg): return msg
        }
    }

    private var buttonColor: Color {
        switch coordinator.phase {
        case .idle: return .blue
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .green
        case .error: return .gray
        }
    }

    private var buttonDisabled: Bool {
        switch coordinator.phase {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }
}

#Preview { ContentView() }
