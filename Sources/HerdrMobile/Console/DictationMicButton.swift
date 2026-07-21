import SwiftUI

/// The hold-to-talk microphone button on the Agent reply box (#36): hold to
/// record, release to stop. It sits left of the send button and stays visible
/// at all times (User Story 14). Transcription streams into the draft through
/// the `DictationStore`; this view only translates the press/release gesture
/// and reflects the recording state.
///
/// Slide-off-to-cancel and the richer failure routing are a later slice (#37).
struct DictationMicButton: View {
    @Bindable var store: DictationStore
    /// Guards against `DragGesture.onChanged` firing repeatedly for one hold:
    /// only the first change of a press starts recording.
    @State private var isHolding = false

    var body: some View {
        Image(systemName: store.isRecording ? "mic.fill" : "mic")
            .font(.title2)
            .foregroundStyle(store.isRecording ? .red : .accentColor)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        store.startDictation()
                    }
                    .onEnded { _ in
                        isHolding = false
                        store.stopDictation()
                    }
            )
            .accessibilityLabel("Dictate")
            .accessibilityHint("Hold to record, release to stop")
            .accessibilityValue(store.isRecording ? "Recording" : "")
            .accessibilityAddTraits(store.isRecording ? .isSelected : [])
    }
}
