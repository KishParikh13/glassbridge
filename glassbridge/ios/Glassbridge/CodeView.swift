import SwiftUI

/// Voice control for Claude Code sessions: pick or start a session, then hold
/// the TALK button and speak. Commands ("new session", "list sessions",
/// "switch to the parser one") and plain requests are both routed by the
/// backend — you just talk.
struct CodeView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var showSessions = false

    var body: some View {
        VStack(spacing: 16) {
            header
            Spacer(minLength: 8)
            talkButton
            phaseLabel
            replyArea
            Spacer(minLength: 8)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .task { await coordinator.refreshCodeSessions() }
        .sheet(isPresented: $showSessions) { sessionsSheet }
    }

    // MARK: – Pieces

    private var header: some View {
        VStack(spacing: 6) {
            Text("Claude Code")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .padding(.top, 24)
            Button { showSessions = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text(coordinator.activeCodeSessionTitle ?? "No session — speak to start")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var talkButton: some View {
        Button(action: { Task { await coordinator.codeTalkPressed() } }) {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: 200, height: 200)
                    .shadow(color: buttonColor.opacity(0.4), radius: 14, y: 4)
                VStack(spacing: 4) {
                    Image(systemName: "mic.fill").font(.system(size: 36, weight: .bold))
                    Text("TALK").font(.system(size: 34, weight: .black, design: .rounded))
                }
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
            Text(phaseTitle).font(.title3.weight(.semibold))
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
        if coordinator.codeReply.isEmpty && coordinator.codeTranscript.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.tertiary)
                Text("Hold TALK and say what you want.\nTry “start a new session”, “list sessions”, or just describe a task.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !coordinator.codeTranscript.isEmpty {
                        bubble(label: "YOU", text: coordinator.codeTranscript, accent: .blue)
                    }
                    if !coordinator.codeAction.isEmpty {
                        Text(actionBadge(coordinator.codeAction))
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if !coordinator.codeReply.isEmpty {
                        bubble(label: "CLAUDE CODE", text: coordinator.codeReply, accent: .purple, markdown: true)
                    }
                    if !coordinator.codeLatencySummary.isEmpty {
                        Text(coordinator.codeLatencySummary)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bubble(label: String, text: String, accent: Color, markdown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(accent)
            Group {
                if markdown,
                   let attributed = try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed).font(.body)
                } else {
                    Text(text).font(.body)
                }
            }
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack {
            Button { Task { await coordinator.createCodeSession() } } label: {
                Label("New session", systemImage: "plus.circle")
                    .font(.caption)
            }
            Spacer()
            Button { Task { await coordinator.refreshCodeSessions() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .tint(.secondary)
        }
    }

    @ViewBuilder
    private var sessionsSheet: some View {
        NavigationStack {
            List {
                Section("Sessions") {
                    if coordinator.codeSessions.isEmpty {
                        Text("No sessions yet. Tap “New” or say “start a new session”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(coordinator.codeSessions) { s in
                        Button {
                            coordinator.selectCodeSession(s.id)
                            showSessions = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).foregroundStyle(.primary)
                                    if let n = s.turn_count {
                                        Text("\(n) turn\(n == 1 ? "" : "s")")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if s.id == coordinator.activeCodeSessionId {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                if let err = coordinator.codeError, !err.isEmpty {
                    Section { Text(err).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Claude Code sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSessions = false
                        Task { await coordinator.createCodeSession() }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSessions = false }
                }
            }
            .task { await coordinator.refreshCodeSessions() }
        }
    }

    // MARK: – Derived

    private func actionBadge(_ action: String) -> String {
        switch action {
        case "create": return "▸ STARTED NEW SESSION"
        case "list": return "▸ LISTED SESSIONS"
        case "switch": return "▸ SWITCHED SESSION"
        case "help": return "▸ HELP"
        case "chat": return "▸ SENT TO SESSION"
        default: return "▸ \(action.uppercased())"
        }
    }

    private var phaseTitle: String {
        switch coordinator.phase {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .thinking: return "Claude Code is working…"
        case .speaking: return "Speaking…"
        case .error: return "Something went wrong"
        }
    }

    private var phaseSubtitle: String {
        switch coordinator.phase {
        case .idle: return ""
        case .listening: return "Speak for up to 5 seconds"
        case .thinking: return "This can take a moment for real work"
        case .speaking: return "Playing the reply"
        case .error(let msg): return msg
        }
    }

    private var buttonColor: Color {
        switch coordinator.phase {
        case .idle: return .indigo
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
