import SwiftUI

/// The Authentication section of a Host form: the method, then the public key
/// to register on the Host or the password field. Device Key and RSA Key show
/// a copyable line generated on this device, whose private half never leaves
/// it.
struct HostAuthenticationSection: View {
    @Binding var authMethod: Host.AuthMethod
    @Binding var password: String
    /// The password field's prompt, which says when a blank keeps the stored one.
    let passwordPrompt: String

    @State private var authorizedKeysLine: String?
    @State private var rsaPublicKeyLine: String?
    @State private var didCopyKeyLine = false
    @State private var deviceKeyIsCorrupt = false
    @State private var rsaKeyIsCorrupt = false
    @State private var isConfirmingDeviceKeyReplacement = false
    @State private var isConfirmingRSAKeyReplacement = false
    @State private var deviceKeyReplacementError: String?
    @State private var rsaKeyReplacementError: String?

    private let credentials = HostCredentialsProvider()

    var body: some View {
        Section {
            methodPicker
            switch authMethod {
            case .deviceKey:
                deviceKeyRows
            case .rsaKey:
                rsaKeyRows
            case .password:
                SecureField(passwordPrompt, text: $password)
            }
        } header: {
            Text("Authentication")
        } footer: {
            switch authMethod {
            case .deviceKey:
                Text(
                    String(localized: "Add this line to ~/.ssh/authorized_keys on the Host. For an administrator account on Windows, add it to C:\\ProgramData\\ssh\\administrators_authorized_keys instead, which only Administrators and SYSTEM may access. The private key never leaves this device."))
            case .rsaKey:
                Text(
                    String(localized: "Register this public key wherever the Host accepts SSH identities. The private key never leaves this device."))
            case .password:
                EmptyView()
            }
        }
    }

    /// The method row, which also carries the section's loading and dialogs: a
    /// row is one view, where the section is several.
    private var methodPicker: some View {
        Picker("Method", selection: $authMethod) {
            Text("Device Key").tag(Host.AuthMethod.deviceKey)
            Text("RSA Key").tag(Host.AuthMethod.rsaKey)
            Text("Password").tag(Host.AuthMethod.password)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: authMethod) {
            didCopyKeyLine = false
            if authMethod == .rsaKey, rsaPublicKeyLine == nil, !rsaKeyIsCorrupt {
                loadRSAKey()
            }
        }
        .task {
            loadDeviceKey()
            if authMethod == .rsaKey { loadRSAKey() }
        }
        .modifier(
            KeyReplacementDialogs(
                isConfirmingDeviceKey: $isConfirmingDeviceKeyReplacement,
                isConfirmingRSAKey: $isConfirmingRSAKeyReplacement,
                deviceKeyError: $deviceKeyReplacementError,
                rsaKeyError: $rsaKeyReplacementError,
                replaceDeviceKey: replaceDeviceKey,
                replaceRSAKey: replaceRSAKey))
    }

    @ViewBuilder
    private var deviceKeyRows: some View {
        if let authorizedKeysLine {
            Text(authorizedKeysLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = authorizedKeysLine
                didCopyKeyLine = true
            } label: {
                Label {
                    Text(didCopyKeyLine ? "Copied" : "Copy authorized_keys Line")
                } icon: {
                    // The tall two-page glyph otherwise outgrows the text.
                    Image(systemName: didCopyKeyLine ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
            }
        } else {
            Label(
                deviceKeyIsCorrupt ? "Device key is corrupted" : "Device key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.errorInk)
            if deviceKeyIsCorrupt {
                Button("Replace Device Key", role: .destructive) {
                    isConfirmingDeviceKeyReplacement = true
                }
            } else {
                Button("Try Again") { loadDeviceKey() }
            }
        }
    }

    @ViewBuilder
    private var rsaKeyRows: some View {
        if let rsaPublicKeyLine {
            Text(rsaPublicKeyLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = rsaPublicKeyLine
                didCopyKeyLine = true
            } label: {
                Label {
                    Text(didCopyKeyLine ? "Copied" : "Copy RSA Public Key")
                } icon: {
                    // The tall two-page glyph otherwise outgrows the text.
                    Image(systemName: didCopyKeyLine ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
            }
        } else {
            Label(
                rsaKeyIsCorrupt ? "RSA Key is corrupted" : "RSA Key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.errorInk)
            if !rsaKeyIsCorrupt {
                Button("Try Again") { loadRSAKey() }
            } else {
                Button("Replace RSA Key", role: .destructive) {
                    isConfirmingRSAKeyReplacement = true
                }
            }
        }
    }

    private func loadDeviceKey() {
        do {
            let key = try credentials.deviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeyIsCorrupt = false
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = true
        } catch {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = false
        }
    }

    private func loadRSAKey() {
        do {
            let key = try credentials.rsaKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "heeler rsa")
            rsaKeyIsCorrupt = false
        } catch RSAKeyStoreError.storedKeyCorrupt {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = true
        } catch {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = false
        }
    }

    private func replaceDeviceKey() {
        do {
            let key = try credentials.replaceDeviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            deviceKeyReplacementError = String(localized: "The replacement could not be saved to the Keychain.")
        }
    }

    private func replaceRSAKey() {
        do {
            let key = try credentials.replaceRSAKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "heeler rsa")
            rsaKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            rsaKeyReplacementError = String(localized: "The replacement could not be saved to the Keychain.")
        }
    }
}

/// The confirmations and failures of replacing a corrupt key, in a chain of
/// their own: joined to a form's, the chain exceeds Xcode 26.6's type-checking
/// limit.
private struct KeyReplacementDialogs: ViewModifier {
    @Binding var isConfirmingDeviceKey: Bool
    @Binding var isConfirmingRSAKey: Bool
    @Binding var deviceKeyError: String?
    @Binding var rsaKeyError: String?
    let replaceDeviceKey: () -> Void
    let replaceRSAKey: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Could not replace the Device Key",
                isPresented: Binding(
                    get: { deviceKeyError != nil },
                    set: { if !$0 { deviceKeyError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deviceKeyError ?? "")
            }
            .alert(
                "Could not replace the RSA Key",
                isPresented: Binding(
                    get: { rsaKeyError != nil },
                    set: { if !$0 { rsaKeyError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(rsaKeyError ?? "")
            }
            .confirmationDialog(
                String(localized: "Replace the Device Key?"),
                isPresented: $isConfirmingDeviceKey,
                titleVisibility: .visible
            ) {
                Button("Replace Device Key", role: .destructive) { replaceDeviceKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    String(localized: "Every Host using Device Key authentication will reject the replacement until you add its new public key to ~/.ssh/authorized_keys, or for an administrator account on Windows to C:\\ProgramData\\ssh\\administrators_authorized_keys."))
            }
            .confirmationDialog(
                String(localized: "Replace the RSA Key?"),
                isPresented: $isConfirmingRSAKey,
                titleVisibility: .visible
            ) {
                Button("Replace RSA Key", role: .destructive) { replaceRSAKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    String(localized: "Every Host using RSA Key authentication will reject the replacement until you register its new public key on that Host."))
            }
    }
}
