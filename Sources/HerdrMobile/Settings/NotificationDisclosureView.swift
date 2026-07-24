import SwiftUI

/// The shared trust-story body (#76): the summary, what the push relay sees,
/// what it cannot, and the custom-relay caveat. One layout drives both the
/// pre-permission explainer and the persistent settings disclosure so the two
/// can never drift. Copy lives in `NotificationPrivacyCopy`.
struct NotificationDisclosureContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(NotificationPrivacyCopy.summary)

            disclosureList(
                title: NotificationPrivacyCopy.relaySeesTitle,
                systemImage: "eye",
                items: NotificationPrivacyCopy.relaySees)

            disclosureList(
                title: NotificationPrivacyCopy.relayCannotSeeTitle,
                systemImage: "eye.slash",
                items: NotificationPrivacyCopy.relayCannotSee)

            Text(NotificationPrivacyCopy.customRelayCaveat)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func disclosureList(
        title: String, systemImage: String, items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item)
                }
                .font(.subheadline)
            }
        }
    }
}

/// The pre-permission explainer (#76, acceptance criterion 1): shown before the
/// iOS system prompt so the user understands the pipeline they are opting into.
/// `onContinue` triggers the real permission request
/// (`PushRegistrationStore.enable()`); dismissing without it leaves the
/// permission state untouched.
struct NotificationExplainerSheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                NotificationDisclosureContent()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Link(
                        "Read the privacy details",
                        destination: NotificationPrivacyCopy.privacyPolicyURL)
                        .font(.footnote)
                    Button {
                        onContinue()
                        dismiss()
                    } label: {
                        Text(NotificationPrivacyCopy.explainerConfirm)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(NotificationPrivacyCopy.explainerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NotificationPrivacyCopy.explainerCancel) { dismiss() }
                }
            }
        }
    }
}

/// The persistent settings disclosure (#76, acceptance criterion 2): the same
/// story, reachable any time, with the link out to `PRIVACY.md`.
struct NotificationPrivacyDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                NotificationDisclosureContent()
                Link(
                    "Read PRIVACY.md",
                    destination: NotificationPrivacyCopy.privacyPolicyURL)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Notification Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
