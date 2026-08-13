import SwiftUI
import UIKit

// MARK: - Shared visual language
//
// The app's only custom palette lives on the LiveView camera stage. Settings used to be a
// stock light Form presented as a sheet from that near-black screen, which read as leaving
// the app and arriving in iOS Settings. These pull the same gradient and glow so it looks
// like one product.

enum GB {
    /// Identical to LiveView.cameraStage. If that changes, change this.
    static let stage = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.07, blue: 0.08),
            Color(red: 0.08, green: 0.13, blue: 0.14),
            Color(red: 0.01, green: 0.02, blue: 0.025),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accent = Color.cyan
    static let cardFill = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.14)
    static let heroStroke = Color.white.opacity(0.26)
    static let label2 = Color(white: 0.92).opacity(0.60)
    static let label3 = Color(white: 0.92).opacity(0.30)
}

/// The dark stage behind every settings screen.
private struct StageBackground: View {
    var body: some View {
        ZStack {
            GB.stage
            Circle()
                .fill(GB.accent.opacity(0.15))
                .frame(width: 340, height: 340)
                .blur(radius: 72)
                .offset(x: 130, y: -260)
        }
        .ignoresSafeArea()
    }
}

/// A titled group of cards. Replaces `Section` now that we are not in a Form.
private struct GBGroup<Content: View>: View {
    let title: String
    var action: (label: String, run: () -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(GB.label3)
                Spacer()
                if let action {
                    Button(action.label, action: action.run)
                        .font(.subheadline)
                        .foregroundStyle(GB.accent)
                }
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

/// Translucent card, matching the chrome already on the camera stage.
private struct GBCard<Content: View>: View {
    var attention = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(attention ? Color.orange.opacity(0.055) : GB.cardFill,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(attention ? Color.orange.opacity(0.42) : GB.cardStroke,
                                  lineWidth: 0.7)
            )
    }
}

/// Grouped rows inside one rounded container, the dark equivalent of an inset list.
private struct GBList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(GB.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(GB.cardStroke, lineWidth: 0.7)
            )
    }
}

/// A 44pt row. `value` is trailing text, `chevron` marks it as pushing somewhere.
private struct GBRow: View {
    let key: String
    var value: String = ""
    var valueColor: Color = GB.label2
    var monospaced = false
    var chevron = false
    var divider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(key).font(.body).foregroundStyle(.white)
                Spacer(minLength: 12)
                Text(value)
                    .font(monospaced ? .system(.subheadline, design: .monospaced) : .body)
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GB.label3)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            if divider {
                Divider().overlay(Color.white.opacity(0.10)).padding(.leading, 14)
            }
        }
    }
}

private struct StatusPill: View {
    enum Tone { case ready, attention, off
        var color: Color {
            switch self {
            case .ready: return Color(red: 0.19, green: 0.82, blue: 0.35)      // systemGreen
            case .attention: return Color(red: 1.0, green: 0.62, blue: 0.04)   // systemOrange
            case .off: return GB.label3
            }
        }
    }
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle().frame(width: 7, height: 7)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(tone.color)
    }
}

/// One source of truth about one thing, tappable into its own screen.
private struct StatusCardContent: View {
    let glyph: String
    let name: String
    let source: String
    let pill: (String, StatusPill.Tone)
    var pushes = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.085),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(GB.cardStroke, lineWidth: 0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).foregroundStyle(.white)
                Text(source).font(.subheadline).foregroundStyle(GB.label2).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(text: pill.0, tone: pill.1)
            if pushes {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GB.label3)
            }
        }
    }
}

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
            ZStack {
                StageBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if !coordinator.hasCompletedOnboarding { intro }
                        status
                        handsFree
                        if !coordinator.recorder.recent.isEmpty { recent }
                        selfTest
                        advanced
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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
                Task { await coordinator.checkBackend() }
            }
        }
        .preferredColorScheme(.dark)
        .tint(GB.accent)
    }

    // MARK: First run only

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Glassbridge works with just your iPhone. Connect Ray-Ban glasses to use them as the camera and mic instead.")
                .font(.callout)
                .foregroundStyle(GB.label2)
        }
        .padding(.horizontal, 4)
    }

    // MARK: 1 · Status

    private var status: some View {
        GBGroup(title: "Status") {
            VStack(spacing: 9) {
                NavigationLink {
                    GlassesDetailView(coordinator: coordinator, glasses: glasses)
                } label: {
                    GBCard {
                        StatusCardContent(
                            glyph: "eyeglasses",
                            name: "Ray-Ban glasses",
                            source: glassesSource,
                            pill: glassesPill
                        )
                    }
                }
                .buttonStyle(.plain)

                NavigationLink {
                    PhoneDetailView(coordinator: coordinator)
                } label: {
                    GBCard {
                        StatusCardContent(
                            glyph: "iphone",
                            name: "iPhone",
                            source: "Mic, camera, speech recognition",
                            pill: phonePill
                        )
                    }
                }
                .buttonStyle(.plain)

                GBCard(attention: !backendReachable) {
                    VStack(spacing: 11) {
                        NavigationLink {
                            AgentDetailView(coordinator: coordinator)
                        } label: {
                            StatusCardContent(
                                glyph: "sparkles",
                                name: "Agent",
                                source: "\(coordinator.selectedModel.label) · 5 capabilities",
                                pill: backendReachable ? ("Reachable", .ready) : ("Unreachable", .attention)
                            )
                        }
                        .buttonStyle(.plain)

                        // Only a card that needs something shows an action.
                        if !backendReachable {
                            Button {
                                Task { await coordinator.checkBackend() }
                            } label: {
                                Group {
                                    if coordinator.isCheckingBackend {
                                        ProgressView().tint(.black)
                                    } else {
                                        Text("Check again").fontWeight(.semibold)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .padding(.vertical, 7)
                                .background(Color.orange, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var backendReachable: Bool { coordinator.backendHealth?.reachable ?? false }

    private var glassesSource: String {
        glasses.connectionState.isGlassesLive ? "Connected · mic + camera" : glasses.connectionState.detail
    }

    private var glassesPill: (String, StatusPill.Tone) {
        switch glasses.connectionState {
        case .connected, .streaming: return ("Connected", .ready)
        case .registering, .connecting: return ("Connecting", .attention)
        case .usingPhone, .readyToConnect: return ("Not connected", .off)
        default: return ("Needs setup", .attention)
        }
    }

    private var phonePill: (String, StatusPill.Tone) {
        let all = coordinator.micPermission.isGranted
            && coordinator.cameraPermission.isGranted
            && coordinator.speechPermission.isGranted
        return all ? ("Allowed", .ready) : ("Needs setup", .attention)
    }

    // MARK: 2 · Hands-free

    private var handsFree: some View {
        GBGroup(title: "Hands-free") {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 13) {
                    Image(systemName: "waveform")
                        .font(.system(size: 17))
                        .foregroundStyle(GB.accent)
                        .frame(width: 38, height: 38)
                        .background(GB.accent.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(GB.accent.opacity(0.35), lineWidth: 0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake word").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        Text("Say \u{201C}\(wake.triggerPhrase)\u{201D} to start, anytime")
                            .font(.subheadline).foregroundStyle(GB.label2)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { coordinator.wakeWordEnabled },
                        set: { coordinator.setWakeWord($0) }
                    ))
                    .labelsHidden()
                }
                .padding(15)
                .background(GB.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(GB.heroStroke, lineWidth: 0.7))

                // The three-sentence paragraph this replaces was unreadable at caption size.
                FlowChips(items: [
                    ("never mind", "drop it"),
                    ("stop", "cut the reply"),
                    ("go to sleep", "switch off"),
                ])
            }
        }
    }

    // MARK: 3 · Recent

    private var recent: some View {
        GBGroup(title: "Recent") {
            GBList {
                let items = Array(coordinator.recorder.recent.prefix(3))
                ForEach(Array(items.enumerated()), id: \.element.id) { index, turn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.transcript.map { "\u{201C}\($0)\u{201D}" } ?? "Untranscribed ask")
                            .font(.callout).foregroundStyle(.white).lineLimit(2)
                        HStack(spacing: 7) {
                            Text(turn.startedAt, format: .relative(presentation: .numeric))
                            Text("·").foregroundStyle(GB.label3.opacity(0.6))
                            outcomeText(turn)
                        }
                        .font(.subheadline)
                        .foregroundStyle(GB.label3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    if index != items.count - 1 {
                        Divider().overlay(Color.white.opacity(0.10)).padding(.leading, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeText(_ turn: SessionRecorder.Recording) -> some View {
        if let outcome = turn.outcome, outcome.hasPrefix("error") {
            Text("failed").foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
        } else if turn.outcome == "cancelled" {
            Text("cancelled")
        } else if let stt = turn.sttLatency, let llm = turn.llmLatency {
            Text(String(format: "%.1fs", stt + llm))
                .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
        } else {
            Text("done")
        }
    }

    // MARK: Self test

    private var selfTest: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                Task { await coordinator.runSelfTest() }
            } label: {
                Text("Run a test ask")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.02, green: 0.15, blue: 0.18))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .padding(.vertical, 12)
                    .background(GB.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
            Text("Proves capture, agent, and voice in one tap.")
                .font(.subheadline).foregroundStyle(GB.label3)
                .padding(.horizontal, 4)
        }
    }

    // MARK: 4 · Advanced

    private var advanced: some View {
        NavigationLink {
            AdvancedView(coordinator: coordinator, glasses: glasses, wake: wake)
        } label: {
            GBList { GBRow(key: "Advanced", chevron: true, divider: false) }
        }
        .buttonStyle(.plain)
    }
}

/// Wrapping chips. The voice vocabulary reads as a set of things you can say, which a
/// paragraph never did.
private struct FlowChips: View {
    let items: [(String, String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    Text("\u{201C}\(item.0)\u{201D}").foregroundStyle(.white).fontWeight(.semibold)
                    Text(item.1).foregroundStyle(GB.label2)
                }
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(GB.cardFill, in: Capsule())
                .overlay(Capsule().strokeBorder(GB.cardStroke, lineWidth: 0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Glasses detail

/// Connection, then what you can set, then what it is doing. Those were one section
/// before, which is why frame rate sat next to measured frame rate.
private struct GlassesDetailView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController

    var body: some View {
        ZStack {
            StageBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    GBGroup(title: "Connection") {
                        VStack(spacing: 9) {
                            GBCard {
                                StatusCardContent(
                                    glyph: "eyeglasses",
                                    name: glasses.connectionState.shortLabel,
                                    source: glasses.connectionState.detail,
                                    pill: glasses.connectionState.isGlassesLive
                                        ? ("Connected", .ready) : ("Offline", .off),
                                    pushes: false
                                )
                            }
                            GBList {
                                GBRow(key: "Camera", value: glasses.cameraPermission)
                                GBRow(key: "Microphone", value: glasses.micPermission, divider: false)
                            }
                            actions
                            if let err = glasses.lastError, !err.isEmpty {
                                Text(err).font(.footnote)
                                    .foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
                                    .padding(.horizontal, 4)
                            }
                            Text("Enable Developer Mode in the Meta AI app (Settings → your glasses), and wear them so they stay connected.")
                                .font(.footnote).foregroundStyle(GB.label3)
                                .padding(.horizontal, 4)
                        }
                    }

                    GBGroup(title: "Camera") {
                        GBList {
                            Menu {
                                ForEach(GlassesController.Quality.allCases, id: \.self) { q in
                                    Button(q.label) {
                                        glasses.applyStreamSettings(quality: q, frameRate: glasses.frameRate)
                                    }
                                }
                            } label: {
                                GBRow(key: "Quality", value: glasses.quality.label, chevron: true)
                            }
                            Menu {
                                ForEach(GlassesController.frameRateOptions, id: \.self) { f in
                                    Button("\(f) fps") {
                                        glasses.applyStreamSettings(quality: glasses.quality, frameRate: f)
                                    }
                                }
                            } label: {
                                GBRow(key: "Frame rate", value: "\(glasses.frameRate) fps",
                                      chevron: true, divider: false)
                            }
                        }
                    }

                    if glasses.isStreaming || glasses.lastPhotoLatencyMs != nil {
                        GBGroup(title: "Live") {
                            GBList {
                                if glasses.isStreaming {
                                    GBRow(key: "Measured",
                                          value: String(format: "%.1f fps", glasses.measuredFPS),
                                          monospaced: true)
                                    if !glasses.lastFrameSize.isEmpty {
                                        GBRow(key: "Frame size", value: glasses.lastFrameSize, monospaced: true)
                                    }
                                }
                                if let ms = glasses.lastPhotoLatencyMs {
                                    GBRow(key: "Last photo", value: "\(ms) ms",
                                          monospaced: true, divider: false)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var actions: some View {
        switch glasses.connectionState {
        case .usingPhone, .readyToConnect, .metaAINotInstalled, .problem:
            wideButton("Connect glasses") { glasses.connect() }
        case .registering, .connecting:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Connecting…").font(.subheadline).foregroundStyle(GB.label2)
            }
            .frame(maxWidth: .infinity)
        case .needsDeviceUpdate:
            wideButton("Open update in Meta AI", tint: .orange) { glasses.openFirmwareUpdate() }
        case .needsCameraPermission:
            wideButton("Allow camera & test") { Task { await glasses.testCameraOnce() } }
        case .connected:
            wideButton("Test camera") { Task { await glasses.testCameraOnce() } }
        case .streaming:
            wideButton("Disconnect glasses", tint: Color(red: 1.0, green: 0.27, blue: 0.23)) {
                glasses.unregister()
            }
        }
    }

    private func wideButton(_ title: String, tint: Color = GB.accent,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(red: 0.02, green: 0.15, blue: 0.18))
                .frame(maxWidth: .infinity, minHeight: 26)
                .padding(.vertical, 11)
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Agent detail

/// What you are talking to, and what it can do. The capability rows are display-only for
/// now; each maps to something that already exists in the backend.
private struct AgentDetailView: View {
    @ObservedObject var coordinator: SessionCoordinator

    private struct Capability: Identifiable {
        let id = UUID()
        let glyph: String
        let name: String
        let detail: String
        let on: Bool
    }

    private var capabilities: [Capability] {
        [
            .init(glyph: "eye", name: "See",
                  detail: "Reads the frame from your camera", on: true),
            .init(glyph: "magnifyingglass", name: "Search the web",
                  detail: "Looks things up mid-answer", on: true),
            .init(glyph: "clock.arrow.circlepath", name: "Remember",
                  detail: "Last 3 turns of this session", on: true),
            .init(glyph: "speaker.wave.2", name: "Speak",
                  detail: "Replies aloud through the glasses", on: true),
            .init(glyph: "note.text", name: "Take notes",
                  detail: "Files what you capture, no reply", on: false),
        ]
    }

    var body: some View {
        ZStack {
            StageBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    GBGroup(title: "Identity") {
                        GBList {
                            Menu {
                                ForEach(SessionCoordinator.ClaudeModel.allCases) { model in
                                    Button(model.menuLabel) { coordinator.selectedModel = model }
                                }
                            } label: {
                                GBRow(key: "Model", value: coordinator.selectedModel.label, chevron: true)
                            }
                            GBRow(key: "Runs on",
                                  value: AppConfig.backendURL.host ?? "unknown",
                                  monospaced: true)
                            GBRow(key: "Status",
                                  value: coordinator.backendHealth?.detail ?? "Not checked",
                                  valueColor: (coordinator.backendHealth?.reachable ?? false)
                                      ? Color(red: 0.19, green: 0.82, blue: 0.35)
                                      : Color(red: 1.0, green: 0.62, blue: 0.04),
                                  divider: false)
                        }
                    }

                    GBGroup(title: "Can do") {
                        VStack(spacing: 9) {
                            ForEach(capabilities) { capability in
                                GBCard {
                                    StatusCardContent(
                                        glyph: capability.glyph,
                                        name: capability.name,
                                        source: capability.detail,
                                        pill: capability.on ? ("On", .ready) : ("Off", .off),
                                        pushes: false
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// MARK: - iPhone detail

private struct PhoneDetailView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        ZStack {
            StageBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    GBGroup(title: "Permissions") {
                        VStack(spacing: 9) {
                            permissionCard(glyph: "mic.fill", title: "Microphone",
                                           detail: "Records your voice for an ask",
                                           status: coordinator.micPermission) {
                                Task { await coordinator.requestMic() }
                            }
                            permissionCard(glyph: "camera.fill", title: "Camera",
                                           detail: "Used when the glasses aren't connected",
                                           status: coordinator.cameraPermission) {
                                Task { await coordinator.requestCamera() }
                            }
                            permissionCard(glyph: "waveform", title: "Speech recognition",
                                           detail: "On-device wake word",
                                           status: coordinator.speechPermission) {
                                Task { await coordinator.requestSpeech() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func permissionCard(glyph: String, title: String, detail: String,
                                status: PermStatus, request: @escaping () -> Void) -> some View {
        GBCard(attention: !status.isGranted) {
            VStack(spacing: 11) {
                StatusCardContent(
                    glyph: glyph, name: title, source: detail,
                    pill: status.isGranted ? ("Allowed", .ready) : ("Not allowed", .attention),
                    pushes: false
                )
                if !status.isGranted {
                    Button {
                        if status == .denied {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } else {
                            request()
                        }
                    } label: {
                        Text(status == .denied ? "Open Settings" : "Allow")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .padding(.vertical, 7)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Advanced (developer)

/// Everything that is a number rather than a decision. Nothing here changed except that it
/// now has its own screen instead of a disclosure group two thirds of the way down.
private struct AdvancedView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @ObservedObject var glasses: GlassesController
    @ObservedObject var wake: WakeWordListener
    @State private var loopbackSeconds: Double = 3

    var body: some View {
        ZStack {
            StageBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    GBGroup(title: "Listener") {
                        GBList {
                            GBRow(key: "State", value: wake.state.rawValue, monospaced: true)
                            GBRow(key: "Last heard",
                                  value: wake.lastHeard.isEmpty ? "—" : wake.lastHeard,
                                  monospaced: true, divider: false)
                        }
                    }

                    GBGroup(title: "Glasses permissions") {
                        GBList {
                            GBRow(key: "Camera", value: glasses.cameraPermission, monospaced: true)
                            GBRow(key: "Microphone", value: glasses.micPermission, monospaced: true)
                            Button { glasses.refreshPermissions() } label: {
                                GBRow(key: "Refresh status", value: "")
                            }
                            .buttonStyle(.plain)
                            Button { glasses.requestMicPermission() } label: {
                                GBRow(key: "Request glasses mic", value: "", divider: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    GBGroup(title: "Audio route") {
                        VStack(alignment: .leading, spacing: 9) {
                            GBList {
                                GBRow(key: "Route",
                                      value: coordinator.audioRoute.isEmpty ? "—" : coordinator.audioRoute,
                                      monospaced: true)
                                GBRow(key: "Inputs",
                                      value: coordinator.availableInputs.isEmpty ? "—" : coordinator.availableInputs,
                                      monospaced: true, divider: false)
                            }
                            HStack(spacing: 8) {
                                smallButton("Refresh") { coordinator.refreshAudioRoute() }
                                smallButton("Activate") { Task { await coordinator.activateAudioRoute() } }
                                smallButton("Deactivate") { coordinator.deactivateAudioRoute() }
                            }
                        }
                    }

                    GBGroup(title: "Microphone") {
                        VStack(alignment: .leading, spacing: 9) {
                            ProgressView(value: Double(coordinator.micLevel))
                                .tint(coordinator.micLevel > 0.8
                                      ? Color(red: 1.0, green: 0.27, blue: 0.23)
                                      : Color(red: 0.19, green: 0.82, blue: 0.35))
                            smallButton(coordinator.isMonitoringMic ? "Stop mic meter" : "Start mic meter") {
                                Task { await coordinator.toggleMicMeter() }
                            }
                            HStack {
                                Text("Loopback").font(.subheadline).foregroundStyle(GB.label2)
                                Slider(value: $loopbackSeconds, in: 1...5, step: 1)
                                Text("\(Int(loopbackSeconds))s")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(GB.label2)
                            }
                            smallButton("Record → play back") {
                                Task { await coordinator.runMicLoopback(seconds: loopbackSeconds) }
                            }
                            smallButton("Play speaker test tone") {
                                Task { await coordinator.playSpeakerTone() }
                            }
                        }
                    }

                    GBGroup(title: "Event log",
                            action: ("Clear", { coordinator.clearDiagLog() })) {
                        GBList {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(combinedLog, id: \.self) { line in
                                    Text(line)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(GB.label2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(14)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var combinedLog: [String] {
        Array((glasses.debugLog + coordinator.diagLog).suffix(60))
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(GB.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(GB.cardStroke, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}
