import SwiftUI
import UIKit

/// On Device Voice Input in the Composer's input place (ADR 0043): what the
/// device hears, then the microphone's level and time, Stop, and Send. Stop
/// puts the text in the draft; Send puts it there and sends the draft once
/// the last words settle. A failure or a model download shows here too,
/// until it is dismissed.
struct ComposerLiveVoiceRecorder: View {
    let voice: ComposerVoiceInput
    /// The draft, shown ahead of what is heard, which joins its end.
    let draft: String
    let stop: () -> Void
    let send: () -> Void
    let downloadModel: () -> Void
    let restart: () -> Void
    let openVoiceInputSettings: () -> Void

    var body: some View {
        if let failure = voice.failure {
            ComposerLiveVoiceFailure(
                failure: failure, downloadModel: downloadModel, restart: restart,
                openVoiceInputSettings: openVoiceInputSettings,
                dismiss: { voice.dismissFailure() })
        } else if case .downloadingModel(let progress) = voice.phase {
            ComposerLiveVoiceDownload(progress: progress, cancel: { voice.cancel() })
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ComposerLiveVoiceText(
                    draft: draft, heard: voice.heard, placeholder: placeholder,
                    showsCaret: voice.phase != .transcribing)
                controls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            HStack(spacing: 8) {
                if let hint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ComposerVoiceWaveform(levels: voice.levels, isLive: voice.isRecording)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .accessibilityHidden(true)
                }
                if voice.isRecording {
                    ComposerRecordingDot()
                }
                ComposerVoiceElapsed(voice: voice)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Color(uiColor: .systemBackground).opacity(0.55), in: Capsule())
            stopButton
            sendButton
        }
    }

    private var stopButton: some View {
        Button(action: stop) {
            ZStack {
                Circle()
                    .strokeBorder(Color(uiColor: .systemRed), lineWidth: 2)
                if isSettling, !voice.sendsWhenSettled {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(uiColor: .systemRed))
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 32, height: 32)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!canStop)
        .opacity(canStop || (isSettling && !voice.sendsWhenSettled) ? 1 : 0.4)
        .accessibilityLabel("Stop Recording")
        .accessibilityHint("Puts the text in the draft")
        .accessibilityIdentifier("composer.voice-stop")
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if isSettling, voice.sendsWhenSettled {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(uiColor: .systemBackground))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(AgentComposerSendButtonStyle())
        .disabled(!canSend && !(isSettling && voice.sendsWhenSettled))
        .accessibilityLabel("Send")
        .accessibilityHint("Stops recording and sends the draft with its text")
        .accessibilityIdentifier("composer.voice-send")
    }

    private var isSettling: Bool { voice.phase == .transcribing }

    private var canStop: Bool {
        switch voice.phase {
        case .starting, .recording: true
        case .idle, .transcribing, .downloadingModel, .failed: false
        }
    }

    private var canSend: Bool {
        voice.isRecording
            && (!voice.heard.text.isEmpty || draft.contains(where: { !$0.isWhitespace }))
    }

    /// Shown only in an empty draft, so it never covers the user's text.
    private var placeholder: String? {
        voice.isRecording ? String(localized: "Start speaking") : nil
    }

    private var hint: String? {
        switch voice.phase {
        case .starting:
            String(localized: "Getting the microphone ready…")
        case .transcribing:
            voice.sendsWhenSettled
                ? String(localized: "Sending once the last words settle")
                : String(localized: "Settling the last words…")
        case .idle, .recording, .downloadingModel, .failed:
            nil
        }
    }
}

/// The draft, then what the device has heard joined to its end, as the draft
/// will read: the draft and settled words in full, words it may still revise
/// faint and underlined, and the caret after them. The box grows a line at a time up to three and
/// never shrinks while recording, so the terminal above resizes at most
/// twice; longer text keeps its newest lines and fades out at the top.
private struct ComposerLiveVoiceText: View {
    let draft: String
    let heard: VoiceHeard
    /// Shown only when there is neither draft nor heard text.
    let placeholder: String?
    let showsCaret: Bool
    @State private var peakHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    private static let maximumLines: CGFloat = 3

    var body: some View {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let cap = (lineHeight * Self.maximumLines).rounded(.up)
        content
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
                peakHeight = max(peakHeight, min(height, cap))
            }
            .frame(height: max(lineHeight, peakHeight), alignment: .bottom)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: contentHeight > cap ? .clear : .black, location: 0),
                        .init(color: .black, location: contentHeight > cap ? 0.35 : 0),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
            .accessibilityElement(children: .combine)
    }

    private var content: some View {
        // Blinks the caret by redrawing the text twice a second.
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let caretShows = showsCaret
                && Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            if draft.isEmpty, heard.text.isEmpty, let placeholder {
                Text(caret(shows: caretShows)) + Text(placeholder).foregroundStyle(.secondary)
            } else {
                Text(attributed + caret(shows: caretShows))
            }
        }
    }

    private var attributed: AttributedString {
        let joined = heard.text.isEmpty
            ? "" : VoiceInputSpacing.fitted(heard.text, after: draft.last, before: nil)
        let space = joined.hasPrefix(" ") ? " " : ""
        let draft = AttributedString(draft + space)
        let settled = AttributedString(heard.settled)
        var revising = AttributedString(heard.revising)
        revising.foregroundColor = .secondary
        revising.underlineStyle = Text.LineStyle(pattern: .dot)
        return draft + settled + revising
    }

    /// A thin bar in the tint, like the input's caret; clear while it blinks
    /// off, so the text never shifts.
    private func caret(shows: Bool) -> AttributedString {
        var caret = AttributedString("\u{258F}")
        caret.foregroundColor = shows ? Color.accentColor : .clear
        return caret
    }
}

/// Pulses beside the time while the microphone is open.
private struct ComposerRecordingDot: View {
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(Color(uiColor: .systemRed))
            .frame(width: 8, height: 8)
            .opacity(isDim ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
            .accessibilityHidden(true)
    }
}

/// Why On Device could not record, with what can fix it.
private struct ComposerLiveVoiceFailure: View {
    let failure: VoiceInputFailure
    let downloadModel: () -> Void
    let restart: () -> Void
    let openVoiceInputSettings: () -> Void
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Image(systemName: failure.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .systemBackground).opacity(0.55), in: Circle())
                    .accessibilityHidden(true)
                Text(failure.message)
                    .font(.headline)
                if let detail = failure.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.borderless)
                if failure.opensMicrophoneSettings,
                    let url = URL(string: UIApplication.openSettingsURLString)
                {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
                if failure.opensVoiceInputSettings {
                    Button("Voice Input Settings", action: openVoiceInputSettings)
                        .buttonStyle(.borderedProminent)
                }
                if failure.downloadsModel {
                    Button("Download", action: downloadModel)
                        .buttonStyle(.borderedProminent)
                }
                if failure.restarts {
                    Button("Try Again", action: restart)
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.voice-failure")
    }
}

/// The speech model on its way; recording starts once it is installed.
private struct ComposerLiveVoiceDownload: View {
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .systemBackground).opacity(0.55), in: Circle())
                    .accessibilityHidden(true)
                Text("Downloading Speech Model…")
                    .font(.headline)
                Text("Recording starts once it is installed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            HStack {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
