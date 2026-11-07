import SwiftUI
import UIKit

/// The Composer's mic, its own control beside Send so it keeps its place
/// while Stop shows, the draft has text, or a recording runs. A tap starts
/// and a second tap stops. While the microphone is being asked for or the
/// text is on its way it waits; the recording bar's Cancel ends those.
struct ComposerVoiceButton: View {
    let voice: ComposerVoiceInput
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                switch voice.phase {
                case .starting, .transcribing:
                    ProgressView()
                        .controlSize(.small)
                case .recording:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                case .idle, .failed:
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(voice.isRecording ? Color(uiColor: .systemRed) : tint)
        // Not `disabled`: that repaints the circle, near black in Dark Mode,
        // and the mic should only gain its spinner.
        .allowsHitTesting(!isWaiting)
        .accessibilityRespondsToUserInteraction(!isWaiting)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Voice Input")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("composer.voice")
    }

    private var isWaiting: Bool {
        switch voice.phase {
        case .starting, .transcribing: true
        case .idle, .recording, .failed: false
        }
    }

    private var accessibilityValue: String {
        switch voice.phase {
        case .starting: String(localized: "Starting")
        case .recording: String(localized: "Recording")
        case .transcribing: String(localized: "Transcribing")
        case .idle, .failed: ""
        }
    }

    private var accessibilityHint: String {
        switch voice.phase {
        case .idle, .failed: String(localized: "Records speech and adds its text to the draft")
        case .recording: String(localized: "Stops recording and adds its text to the draft")
        case .starting, .transcribing: ""
        }
    }
}

/// Voice Input's place in the Composer while it runs: Cancel, the
/// microphone's recent loudness, and the time. It covers the controls
/// before the mic, which keeps its place, and holds one size from the
/// first tap until the text lands. The mic's value says the phase to
/// VoiceOver.
struct ComposerVoiceBar: View {
    let voice: ComposerVoiceInput
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Voice Input")
            .accessibilityIdentifier("composer.voice-cancel")
            ComposerVoiceWaveform(levels: voice.levels, isLive: voice.isRecording)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .accessibilityHidden(true)
            elapsed
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .padding(.trailing, 12)
        .frame(height: 36)
        .background(Color(uiColor: .systemBackground).opacity(0.55), in: Capsule())
    }

    /// The time, in a slot sized for "0:00" so the waveform keeps its width
    /// as the phase changes. Transcribing holds the recording's length.
    private var elapsed: some View {
        Text(verbatim: Self.format(0))
            .hidden()
            .overlay(alignment: .trailing) {
                switch voice.phase {
                case .recording(let since):
                    Text(
                        timerInterval: since...since.addingTimeInterval(VoiceInputSession.maximumDuration),
                        countsDown: false)
                case .transcribing:
                    Text(verbatim: Self.format(voice.recordedDuration ?? 0))
                case .idle, .starting, .failed:
                    Text(verbatim: Self.format(0))
                }
            }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }
}

/// Bars for the microphone's recent loudness, newest at the trailing end,
/// centered in their space. Quiet samples sit as dots, and the bars dim once
/// the recording ends.
struct ComposerVoiceWaveform: View {
    let levels: [Double]
    let isLive: Bool

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 2
            let quietHeight: CGFloat = 3
            let pitch = barWidth + spacing
            let count = Int((size.width + spacing) / pitch)
            guard count > 0 else { return }
            let leading = (size.width - (CGFloat(count) * pitch - spacing)) / 2
            let shading = GraphicsContext.Shading.color(
                Color(uiColor: .label).opacity(isLive ? 0.38 : 0.16))
            for slot in 0..<count {
                let index = levels.count - count + slot
                let level = index >= 0 ? CGFloat(levels[index]) : 0
                let height = quietHeight + (size.height - quietHeight) * level
                let rect = CGRect(
                    x: leading + CGFloat(slot) * pitch,
                    y: (size.height - height) / 2,
                    width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: shading)
            }
        }
        .flipsForRightToLeftLayoutDirection(true)
    }
}

/// Why a recording produced no text, with what can fix it. A kept recording
/// can be sent again.
struct ComposerVoiceFailureRow: View {
    let failure: VoiceInputFailure
    let retry: () -> Void
    let openVoiceInputSettings: () -> Void
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.message, systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            HStack(spacing: 8) {
                if failure.canRetry {
                    Button("Retry", action: retry)
                }
                if failure.opensVoiceInputSettings {
                    Button("Voice Input Settings", action: openVoiceInputSettings)
                }
                if failure.opensMicrophoneSettings,
                    let url = URL(string: UIApplication.openSettingsURLString)
                {
                    Button("Open Settings") { openURL(url) }
                }
                Button("Dismiss", action: dismiss)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.voice-failure")
    }
}
