import SwiftUI

/// A Host that stopped on a failure only the user can fix. The Console lists
/// these apart, below everything else, so the lists above stay about what is
/// running; each says why it stopped and offers a retry.
struct UnreachableHost: Identifiable, Equatable {
    let hostID: Host.ID
    let hostName: String
    /// The failure's Transport Error Presentation: whole while the Host
    /// waits on the user, without its Recovery Suggestion while a retry runs.
    let reason: String
    /// A retry is under way; the Host stays listed here until it connects,
    /// so a failing retry does not bounce it back into the list above.
    let isRetrying: Bool

    var id: Host.ID { hostID }

    init?(host: Host, status: EventsSessionStatus?, standingFailure: TransportError?) {
        let failure: TransportError
        switch status {
        case .failed(let stopped):
            failure = stopped
            isRetrying = false
        case .connecting:
            guard let standingFailure else { return nil }
            failure = standingFailure
            isRetrying = true
        default:
            return nil
        }
        hostID = host.id
        hostName = host.displayName
        reason = isRetrying ? failure.presentation.explanation : failure.presentation.message
    }

    /// Catalog order, narrowed to `filteredHostID` when the Console is
    /// filtered to one Host.
    static func list(
        hosts: [Host],
        statuses: [Host.ID: EventsSessionStatus],
        standingFailures: [Host.ID: TransportError],
        filteredHostID: Host.ID? = nil
    ) -> [UnreachableHost] {
        hosts.compactMap { host in
            guard filteredHostID == nil || host.id == filteredHostID else { return nil }
            return UnreachableHost(
                host: host, status: statuses[host.id],
                standingFailure: standingFailures[host.id])
        }
    }
}

/// The "Can't connect" section closing a Console list.
struct UnreachableHostsSection: View {
    let hosts: [UnreachableHost]
    /// Opens the Host in the Hosts tab.
    let onOpen: (Host.ID) -> Void
    let onRetry: (Host.ID) -> Void

    var body: some View {
        Section {
            ForEach(hosts) { host in
                HStack(spacing: 12) {
                    Button { onOpen(host.hostID) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.hostName)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(host.reason)
                                .font(.caption)
                                .foregroundStyle(Color.red.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this Host's settings.")
                    if host.isRetrying {
                        ProgressView()
                            .accessibilityLabel("Retrying")
                    } else {
                        Button("Retry") { onRetry(host.hostID) }
                            .buttonStyle(.borderless)
                            .hoverEffect(.highlight)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Can't Connect")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

/// A Host header's trailing status: nothing while healthy, else a short
/// gray word that lines up at the trailing edge whatever the name's length.
struct HostReadinessText: View {
    let readiness: HostReadiness

    var body: some View {
        if readiness.showsStatus {
            Text(readiness.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
