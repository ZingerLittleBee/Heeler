import SwiftUI

/// Ports: what programs on the Host listen on, and a field for an address the
/// list does not have. Choosing either opens it in the preview.
struct PortsListView: View {
    let session: PortPreviewSession
    let close: () -> Void
    let open: (PortPreviewTarget) -> Void
    @State private var typed = ""

    private var ports: HostPortsList { session.ports }

    private var typedTarget: PortPreviewTarget? {
        PortPreviewTarget(typed: typed)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    TextField("Port or localhost URL", text: $typed)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(openTyped)
                        .accessibilityIdentifier("ports-field")
                    Button("Open", action: openTyped)
                        .buttonStyle(.borderless)
                        .disabled(typedTarget == nil)
                        .accessibilityIdentifier("ports-open")
                }
            }
            listed
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await ports.refresh() }
        .navigationTitle("Ports")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Ports")
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: session.hostName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { ports.read() }
                    .disabled(ports.phase == .reading)
                    .accessibilityIdentifier("ports-refresh")
                Button("Close", systemImage: "xmark", action: close)
                    .accessibilityIdentifier("ports-close")
            }
        }
        .task { ports.readIfNeeded() }
        .accessibilityIdentifier("ports-list")
    }

    @ViewBuilder
    private var listed: some View {
        switch ports.phase {
        case .idle, .reading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading ports on \(session.hostName)…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can't Read Ports")
                        .font(.body.weight(.semibold))
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("ports-failure")
                Button("Try Again") { ports.read() }
            } footer: {
                Text("A port or address typed above still opens.")
            }
        case .read:
            if ports.nearby.isEmpty, ports.others.isEmpty {
                Section {
                    Text("No Listening Ports")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ports-empty")
                } footer: {
                    Text(
                        "Nothing on \(session.hostName) is listening on a port this account can see. A server that has just started appears after a refresh.")
                }
            } else {
                if !ports.nearby.isEmpty {
                    Section {
                        rows(ports.nearby)
                    } header: {
                        Text(
                            "In \(directoryName)",
                            comment: "Header over the ports of programs working in one folder; the placeholder is the folder's name.")
                    } footer: {
                        if ports.others.isEmpty { explanation }
                    }
                }
                if !ports.others.isEmpty {
                    Section {
                        rows(ports.others)
                    } header: {
                        if ports.nearby.isEmpty {
                            Text("On \(session.hostName)", comment: "Header over the ports a Host's programs listen on.")
                        } else {
                            Text("Other Ports")
                        }
                    } footer: {
                        explanation
                    }
                }
            }
        }
    }

    private var explanation: some View {
        Text(
            "Ports that programs on \(session.hostName) are listening on. Pages open through the Host's SSH connection.")
    }

    /// The folder the preview opened from, as its section names it.
    private var directoryName: String {
        guard let directory = session.directory else { return "" }
        let name = RemoteHostPath.lastComponent(of: directory)
        return name.isEmpty ? directory : name
    }

    private func rows(_ ports: [HostListeningPort]) -> some View {
        ForEach(ports) { port in
            Button {
                if let target = PortPreviewTarget(port: port.port) { open(target) }
            } label: {
                HostPortRow(port: port)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ports-row-\(port.port)")
        }
    }

    private func openTyped() {
        guard let target = typedTarget else { return }
        typed = ""
        open(target)
    }
}

private struct HostPortRow: View {
    let port: HostListeningPort

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: String(port.port))
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let command = port.command {
                    Text(verbatim: command)
                } else {
                    Text("Unknown Program")
                        .foregroundStyle(.secondary)
                }
                if let directory = port.directory, directory != "/" {
                    Text(verbatim: directory)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
