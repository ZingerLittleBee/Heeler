import SwiftUI
import UIKit

/// The hold-to-talk microphone button on the Agent reply box (#36, #37): hold
/// to record, release to stop, slide the finger off to cancel and discard. It
/// sits left of the send button and stays visible at all times, even when the
/// mic is unusable (User Story 14). Transcription streams into the draft
/// through the `DictationStore`; this view only translates the gesture,
/// reflects the recording state, and presents the permission alert.
struct DictationMicButton: View {
    @Bindable var store: DictationStore
    @Environment(\.openURL) private var openURL

    /// Guards against `DragGesture.onChanged` firing repeatedly for one hold:
    /// only the first change of a press starts recording.
    @State private var isHolding = false
    /// True while the finger has slid off the button, so releasing now cancels
    /// and the button previews that it will discard.
    @State private var willCancel = false
    /// The button's own size, so a slide-off is measured against real bounds.
    @State private var buttonSize: CGSize = .zero

    var body: some View {
        Image(systemName: store.isRecording ? "mic.fill" : "mic")
            .font(.title2)
            .foregroundStyle(iconColor)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { buttonSize = $0 }
            .gesture(holdGesture)
            .alert("Microphone Access Needed", isPresented: permissionAlert) {
                Button("Open Settings") { openSystemSettings() }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Turn on microphone access for herdr in Settings to dictate replies.")
            }
            .accessibilityLabel("Dictate")
            .accessibilityHint("Hold to record, slide off to cancel, release to stop")
            .accessibilityValue(store.isRecording ? "Recording" : "")
            .accessibilityAddTraits(store.isRecording ? .isSelected : [])
    }

    private var iconColor: Color {
        if willCancel { return .secondary }
        return store.isRecording ? .red : .accentColor
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isHolding {
                    isHolding = true
                    store.startDictation()
                }
                willCancel = !isWithinButton(value.location)
            }
            .onEnded { value in
                isHolding = false
                let cancel = willCancel || !isWithinButton(value.location)
                willCancel = false
                if cancel {
                    store.cancelDictation()
                } else {
                    store.stopDictation()
                }
            }
    }

    /// A generous hit region so finger jitter during a hold does not read as a
    /// slide-off; the user must move clearly away from the button to cancel.
    private func isWithinButton(_ location: CGPoint) -> Bool {
        guard buttonSize != .zero else { return true }
        let slop: CGFloat = 44
        let region = CGRect(origin: .zero, size: buttonSize).insetBy(dx: -slop, dy: -slop)
        return region.contains(location)
    }

    private var permissionAlert: Binding<Bool> {
        Binding(
            get: { store.showsPermissionAlert },
            set: { presented in
                if !presented { store.dismissPermissionAlert() }
            })
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
