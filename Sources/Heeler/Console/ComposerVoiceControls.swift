import SwiftUI
import UIKit

/// The Composer's mic, its own control beside Send so it stays reachable
/// while Stop shows or the draft has text. A tap starts and a second tap
/// stops; while the microphone is being asked for or the text is on its
/// way, a tap cancels.
struct ComposerVoiceButton: View {
    let voice: ComposerVoiceInput
    let tint: Color
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                case .idle, .failed:
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(isRecording ? Color(uiColor: .systemRed) : tint)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Voice Input")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("composer.voice")
    }

    private var isRecording: Bool {
        if case .recording = voice.phase { true } else { false }
    }

    private var accessibilityValue: String {
        switch voice.phase {
        case .starting: "Starting"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .idle, .failed: ""
        }
    }

    private var accessibilityHint: String {
        switch voice.phase {
        case .idle, .failed: "Records speech and adds its text to the draft"
        case .recording: "Stops recording and adds its text to the draft"
        case .starting, .transcribing: "Cancels Voice Input"
        }
    }
}

/// What Voice Input is doing, in the actions row's existing space so the
/// Composer keeps its height. The mic's value says the same to VoiceOver.
struct ComposerVoiceStatus: View {
    let phase: ComposerVoiceInput.Phase

    var body: some View {
        Group {
            switch phase {
            case .recording(let since):
                Label {
                    Text(
                        timerInterval: since...since.addingTimeInterval(VoiceInputSession.maximumDuration),
                        countsDown: false
                    )
                    .monospacedDigit()
                } icon: {
                    Image(systemName: "waveform")
                }
                .foregroundStyle(Color(uiColor: .systemRed))
            case .transcribing:
                Text("Transcribing…")
                    .foregroundStyle(.secondary)
            case .idle, .starting, .failed:
                EmptyView()
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .accessibilityHidden(true)
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
