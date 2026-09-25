import SwiftUI

/// Why one Host cannot connect, for the Console's connection sheet. Exists
/// only while the Host is reconnecting or stopped on a failure; its
/// inventory is empty then, so the sheet replaces expanding the Host.
struct HostConnectionDetailPresentation: Equatable {
    let hostID: Host.ID
    let hostName: String
    let address: String
    let title: String
    let tone: HostConnectionTone
    /// "Attempt 3" while automatic recovery runs.
    let attempt: String?
    let summary: String
    let detail: String?
    /// Only once nothing but the user can change the outcome; see Transport
    /// Error Presentation in `CONTEXT.md`.
    let recoverySuggestion: String?
    /// Automatic recovery or a requested retry is under way.
    let isRetrying: Bool
    /// A requested retry after a stop is dialing right now; automatic
    /// recovery instead spends most of its time waiting out a backoff, which
    /// Retry Now cuts short.
    let isDialing: Bool

    init?(host: Host, status: EventsSessionStatus?, standingFailure: TransportError?) {
        let failure: TransportError
        switch status {
        case .reconnecting(let attempt, _, let retrying):
            failure = retrying
            title = "Reconnecting"
            tone = .reconnecting
            self.attempt = "Attempt \(attempt)"
            isRetrying = true
            isDialing = false
        case .failed(let stopped):
            failure = stopped
            title = "Can't Connect"
            tone = .unavailable
            attempt = nil
            isRetrying = false
            isDialing = false
        case .connecting:
            guard let standingFailure else { return nil }
            failure = standingFailure
            title = "Can't Connect"
            tone = .unavailable
            attempt = nil
            isRetrying = true
            isDialing = true
        default:
            return nil
        }
        hostID = host.id
        hostName = host.displayName
        var address = "\(host.username)@\(host.address)"
        if host.port != 22 { address += ":\(host.port)" }
        self.address = address
        let presentation = failure.presentation
        summary = presentation.summary
        detail = presentation.detail
        recoverySuggestion = isRetrying ? nil : presentation.recoverySuggestion
    }
}

/// The bottom sheet a failing Host opens instead of expanding.
struct HostConnectionDetailView: View {
    let presentation: HostConnectionDetailPresentation
    let host: Host
    let catalog: HostStore
    let isRetryInFlight: Bool
    let onRetry: () -> Void

    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        HostStatusGlyph(tone: presentation.tone)
                        Text(presentation.title)
                            .font(.headline)
                        if let attempt = presentation.attempt {
                            Text(attempt)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(presentation.address)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(presentation.summary)
                            .font(.body.weight(.semibold))
                        if let detail = presentation.detail {
                            Text(detail)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let suggestion = presentation.recoverySuggestion {
                            Text(suggestion)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    retryButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .navigationTitle(presentation.hostName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { isEditing = true }
                }
            }
            .sheet(isPresented: $isEditing) {
                HostFormView(store: catalog, editing: host)
            }
        }
        .presentationDetents([.fraction(0.45), .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var retryButton: some View {
        let busy = isRetryInFlight || presentation.isDialing
        Button(action: onRetry) {
            HStack(spacing: 8) {
                if busy { ProgressView() }
                Text(busy ? "Connecting…" : "Retry Now")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isRetryInFlight)
    }
}
