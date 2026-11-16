import SwiftUI

/// Talk to Pi (`Route.voice`, `pidurable://voice`): starts listening when it opens, shows what was heard and said, and
/// links to the Pi conversation the requests went to. Approvals come up as the root's approval sheet, over this screen.
struct VoiceView: View {
    @Bindable var store: ChatStore
    @Binding var path: [Route]
    /// The conversation to talk in; nil starts a new one with the first thing said.
    var continuing: Int?
    private var voice: RealtimeVoice { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VoiceOrb(activity: voice.phase == .live ? voice.activity : nil, level: voice.level, reduceMotion: reduceMotion)
                .frame(height: 220)
                .padding(.top, 12)
            Text(status)
                .font(.headline)
                .foregroundStyle(voice.phase == .ended && voice.endReason != nil ? .red : .primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .contentTransition(.opacity)
                .animation(.snappy, value: status)
                .accessibilityIdentifier("voice.status")
            transcript
            controls
        }
        .navigationTitle("Talk to Pi")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if voice.phase == .off || voice.phase == .ended { await voice.start(conversationId: continuing) }
        }
        .sensoryFeedback(trigger: voice.phase) { _, new in
            new == .live ? .start : new == .ended ? .stop : nil
        }
    }

    private var status: String {
        switch voice.phase {
        case .off, .connecting: return "Connecting…"
        case .ended: return voice.endReason ?? "Ended"
        case .live:
            switch voice.activity {
            case .listening: return "Listening"
            case .hearing: return "Listening…"
            case .working: return voice.waitingForApproval ? "Waiting for your approval" : "Pi is working…"
            case .speaking: return "Speaking"
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(voice.turns) { turn in
                        VoiceTurnRow(turn: turn).id(turn.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: voice.turns.last?.id) {
                guard let last = voice.turns.last?.id else { return }
                withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if let conversationId = voice.conversationId {
                Button("Conversation", systemImage: "bubble.left.and.text.bubble.right") {
                    path.append(.conversation(conversationId))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("voice.conversation")
            }
            Spacer()
            switch voice.phase {
            case .connecting, .live:
                Button("End", systemImage: "xmark") { voice.end() }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .accessibilityIdentifier("voice.end")
            case .off, .ended:
                Button("Talk", systemImage: "waveform") {
                    Task { await voice.start(conversationId: voice.conversationId) }
                }
                .buttonStyle(.glassProminent)
                .accessibilityHint(voice.conversationId == nil ? "Starts listening" : "Continues the same Pi conversation")
                .accessibilityIdentifier("voice.talk")
            }
        }
        .controlSize(.large)
        .padding()
    }
}

private struct VoiceTurnRow: View {
    let turn: RealtimeVoice.Turn

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(turn.text.isEmpty ? "…" : turn.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 18))
            }
        case .pi:
            Text(turn.text)
                .foregroundStyle(turn.pending ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            Label {
                Text(turn.text).lineLimit(3)
            } icon: {
                if turn.pending { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkle") }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

/// A circle that breathes with the microphone while listening, spins while Pi works, and pulses while it speaks.
private struct VoiceOrb: View {
    /// Nil while connecting or ended.
    let activity: RealtimeVoice.Mode?
    let level: Float
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: activity == nil || reduceMotion)) { context in
            orb(at: context.date.timeIntervalSinceReferenceDate)
        }
        .animation(.smooth(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    private func orb(at time: TimeInterval) -> some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(activity == nil ? 0.08 : 0.15))
                .scaleEffect(halo(time))
            Circle()
                .fill(Color.accentColor.gradient)
                .opacity(activity == nil ? 0.35 : 1)
                .scaleEffect(core(time))
            if activity == .working {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(spin(time)))
                    .padding(-18)
            }
        }
        .frame(width: 140, height: 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func spin(_ time: TimeInterval) -> Double {
        reduceMotion ? 0 : time.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
    }

    private func core(_ time: TimeInterval) -> CGFloat {
        switch activity {
        case .hearing, .listening: 0.85 + CGFloat(level) * 0.25
        case .speaking: reduceMotion ? 1 : 0.95 + 0.05 * sin(time * 6)
        case .working, nil: 0.85
        }
    }

    private func halo(_ time: TimeInterval) -> CGFloat {
        switch activity {
        case .hearing, .listening: 1 + CGFloat(level) * 0.45
        case .speaking: reduceMotion ? 1.15 : 1.1 + 0.08 * sin(time * 3)
        case .working, nil: 1
        }
    }
}
