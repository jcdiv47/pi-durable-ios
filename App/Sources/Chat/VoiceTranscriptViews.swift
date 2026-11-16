import SwiftUI

/// Where a Talk to Pi session starts in a conversation, as a call reads in the Phone app: when, how long it takes to
/// play, and Play for all its lines in turn. A rule across the transcript, so the spoken part reads apart from the typed
/// one.
struct VoiceSessionHeader: View {
    let session: String
    let date: Date?
    let lines: [DisplayVoice]
    private var playback: VoicePlayback { .shared }
    private var live: Bool { RealtimeVoice.shared.liveSession == session || RealtimeVoice.shared.recordingSession == session }
    private var key: VoicePlayback.Key { .init(session: session) }

    var body: some View {
        let playable = lines.filter(VoicePlayback.playable)
        let playing = playback.isPlaying(key)
        HStack(spacing: 8) {
            rule
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: playing || live)
                Text(title(playable))
                    .monospacedDigit()
                if !playable.isEmpty && !live {
                    Button {
                        playback.toggle(key, lines: playable)
                    } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 26, height: 26)
                            .background(.tint.opacity(0.15), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(playing ? "Stop" : "Play the conversation")
                    .accessibilityIdentifier("voice.session.play")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            rule
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle().fill(.separator).frame(height: 1)
    }

    private func title(_ playable: [DisplayVoice]) -> String {
        var parts = [live ? "Talking to Pi" : "Voice"]
        if let date { parts.append(date.formatted(date: .omitted, time: .shortened)) }
        // How long Play takes: the lines, without the waits between them.
        let ms = playable.reduce(0) { $0 + max(0, ($1.endMs ?? 0) - ($1.startMs ?? 0)) }
        if ms > 0, !live { parts.append(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))) }
        return parts.joined(separator: " · ")
    }
}

/// A line said in a voice session. The user's sits on the right, where their messages go, but outlined, as it was
/// spoken, not typed; the voice's is small and grey on the left, as Pi's written answer, when there is one, says more.
/// With a recording, tapping either plays it.
struct VoiceLineView: View {
    let text: String
    let voice: DisplayVoice
    private var playback: VoicePlayback { .shared }
    private var key: VoicePlayback.Key { .init(session: voice.session, line: voice) }
    private var playable: Bool { VoicePlayback.playable(voice) }
    private var playing: Bool { playback.isPlaying(key) }

    var body: some View {
        if voice.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Button(action: play) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        icon(idle: "waveform")
                        Text(text).multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.tint.opacity(0.08), in: .rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.tint.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!playable)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(text)")
            .accessibilityHint(playable ? "Plays what you said" : "")
        } else {
            Button(action: play) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    icon(idle: "speaker.wave.2")
                    Text(text).multilineTextAlignment(.leading)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!playable)
            .accessibilityLabel("Pi said: \(text)")
            .accessibilityHint(playable ? "Plays what Pi said" : "")
        }
    }

    private func icon(idle: String) -> some View {
        Image(systemName: playing ? "stop.fill" : playable ? "play.fill" : idle)
            .font(.caption)
            .foregroundStyle(.tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 14)
    }

    private func play() {
        playback.toggle(key, lines: [voice])
    }
}

/// A request the voice handed to Pi: the voice model's wording, not the user's, so not a bubble, but small, under what
/// the user said, with Pi's work and answer after it.
struct VoiceHandoffView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.tint)
            Text("\(Text("Asked Pi:").fontWeight(.semibold)) \(text)")
                .textSelection(.enabled)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice.handoff")
    }
}

/// Stops recording playback the moment a back swipe starts, edge or content, even one the user then lets go of: the
/// voice should not carry on over the screen being left. Put in a screen's background; it finds the navigation
/// controller and adds one shared target to its pop gestures (UIKit ignores a pair added twice).
struct BackSwipeStopsPlayback: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let next = responder?.next, !(next is UIViewController) { responder = next }
            guard let navigation = (responder?.next as? UIViewController)?.navigationController else { return }
            for gesture in [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer].compactMap({ $0 }) {
                gesture.addTarget(Target.shared, action: #selector(Target.swiped(_:)))
            }
        }
    }

    @MainActor
    final class Target: NSObject {
        static let shared = Target()

        @objc func swiped(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began { VoicePlayback.shared.stop() }
        }
    }
}
