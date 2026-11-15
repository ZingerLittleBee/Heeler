import SwiftUI

/// A changed host key, right under the status it left failed: the new key, the
/// command that prints it on the machine, then the trust.
struct HostKeyReplacementSection: View {
    let replacement: HostKeyReplacement
    /// Asks for the confirmation that replaces the trusted key.
    let onTrust: () -> Void

    @State private var didCopyCommand = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("New key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // One line: a wrapped fingerprint gains hyphens that are
                // not in it.
                Text(replacement.presented.displayString)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(replacement.checkPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(replacement.fingerprintCommand)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
            }
            Button {
                UIPasteboard.general.string = replacement.fingerprintCommand
                didCopyCommand = true
            } label: {
                Label {
                    Text(didCopyCommand ? "Copied" : "Copy Command")
                } icon: {
                    // The tall two-page glyph otherwise outgrows the text.
                    Image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
            }
            Button(replacement.trustActionTitle, systemImage: "key.horizontal", role: .destructive) {
                onTrust()
            }
            // A List row tints the icon with the accent color; the role
            // only reddens the title.
            .listItemTint(.red)
        } footer: {
            Text(replacement.verificationNote)
        }
        .onChange(of: replacement) { didCopyCommand = false }
    }
}

extension View {
    /// The confirmation before a changed key replaces the trusted one. An
    /// alert, which a page may also open on its own: iOS 26 shows a
    /// confirmation dialog as a popover without Cancel.
    func hostKeyReplacementAlert(
        _ replacement: HostKeyReplacement?, isPresented: Binding<Bool>, trust: @escaping @MainActor () -> Void
    ) -> some View {
        alert(replacement?.confirmationTitle ?? "", isPresented: isPresented, presenting: replacement) { _ in
            Button("Trust New Key", role: .destructive) { trust() }
            Button("Cancel", role: .cancel) {}
        } message: { replacement in
            Text(replacement.confirmationMessage)
        }
    }
}

/// The re-trust flow's words, naming whose key changed, and how to check
/// the new key on that machine before trusting it.
extension HostKeyReplacement {
    /// Prints the fingerprint of the macOS or Linux host key of the
    /// presented key's type, which sshd serves.
    var fingerprintCommand: String { presented.printCommand }

    var trustActionTitle: String {
        jumpHost == nil ? String(localized: "Trust New Host Key") : String(localized: "Trust New Jump Host Key")
    }

    var checkPrompt: String {
        jumpHost == nil ? String(localized: "On the Host, run") : String(localized: "On the Jump Host, run")
    }

    var verificationNote: String {
        // The folder goes in as an argument: a `%` in the catalog key would
        // read as a format specifier.
        let windowsFolder = #"%ProgramData%\ssh"#
        return String(
            localized: "Trust the new key only if this prints the same fingerprint. On Windows, the key is under \(windowsFolder).")
    }

    var confirmationTitle: String {
        jumpHost == nil ? String(localized: "Replace the trusted Host key?") : String(localized: "Replace the Jump Host's trusted key?")
    }

    /// Leaves the fingerprint to the page: an alert wraps it with hyphens
    /// that are not in it.
    var confirmationMessage: String {
        guard let jumpHost else {
            return String(localized: "Compare the new key with what the command prints on the Host first. A changed key can indicate a reinstalled Host or an attack.")
        }
        return String(localized: "Jump Host: \(jumpHost.endpointDescription)\n\nCompare the new key with what the command prints on the Jump Host first. A changed key can indicate a reinstalled Jump Host or an attack.")
    }
}
