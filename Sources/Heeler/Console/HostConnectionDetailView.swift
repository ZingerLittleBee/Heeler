import SwiftUI

/// Why one Host cannot connect, for the Console's connection sheet. Exists
/// only while the Host is reconnecting, stopped on a failure, or dialing a
/// retry after one; its inventory is empty then, so the sheet replaces
/// expanding the Host.
struct HostConnectionDetailPresentation: Equatable {
    let hostID: Host.ID
    let hostName: String
    let address: String
    let title: String
    let tone: HostConnectionTone
    /// "Attempt 3" while automatic recovery runs.
    let attempt: String?
    /// The failure shown; while dialing, the one the retry answers.
    let failure: TransportError
    let summary: String
    let detail: String?
    /// Only once nothing but the user can change the outcome; see Transport
    /// Error Presentation in `CONTEXT.md`.
    let recoverySuggestion: String?
    /// A connection attempt is dialing right now. Automatic recovery instead
    /// spends most of its time waiting out a backoff, which Retry Now cuts
    /// short.
    let isDialing: Bool
    /// The Host is still trying (dialing, or reconnecting on its own), so
    /// the user can stop it instead of waiting for a timeout.
    let canStop: Bool

    /// `lastFailure` is what the sheet saw before its own Retry Now: a
    /// reconnecting Host's retry dials without a standing failure, and the
    /// sheet must stay to show it.
    init?(
        host: Host, status: EventsSessionStatus?, standingFailure: TransportError?,
        lastFailure: TransportError? = nil
    ) {
        let failure: TransportError
        switch status {
        case .reconnecting(let attempt, _, let retrying):
            failure = retrying
            title = "Reconnecting"
            tone = .reconnecting
            self.attempt = "Attempt \(attempt)"
            isDialing = false
            canStop = true
        case .failed(let stopped):
            failure = stopped
            title = "Can't Connect"
            tone = .unavailable
            attempt = nil
            isDialing = false
            canStop = false
        case .connecting:
            guard let previous = standingFailure ?? lastFailure else { return nil }
            failure = previous
            title = "Connecting…"
            tone = .pending
            attempt = nil
            isDialing = true
            canStop = true
        default:
            return nil
        }
        hostID = host.id
        hostName = host.displayName
        var address = "\(host.username)@\(host.address)"
        if host.port != 22 { address += ":\(host.port)" }
        self.address = address
        self.failure = failure
        let presentation = failure.presentation
        summary = presentation.summary
        detail = presentation.detail
        let isStopped = if case .failed = status { true } else { false }
        recoverySuggestion = isStopped ? presentation.recoverySuggestion : nil
    }
}

/// The sheet a failing Host opens instead of expanding.
struct HostConnectionDetailView: View {
    let presentation: HostConnectionDetailPresentation
    let host: Host
    let catalog: HostStore
    /// The presenting Console's: inside the sheet, the size class describes
    /// the sheet, not the screen.
    let sheetPresentation: ConsoleSheetPresentation
    let isRetryInFlight: Bool
    /// Stops the Host's attempt; nil where stopping is not offered.
    var onStop: (() -> Void)? = nil
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HostConnectionDetailContent(
                presentation: presentation, host: host, catalog: catalog,
                sheetPresentation: sheetPresentation,
                isRetryInFlight: isRetryInFlight, onStop: onStop, onRetry: onRetry
            )
            .toolbar {
                // A form sheet has no grabber to pull down.
                if sheetPresentation == .form {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .modifier(ConsoleStatusSheetPresentationModifier(presentation: sheetPresentation))
    }
}

/// One failing Host's failure and Retry Now, inside a navigation stack: its
/// own sheet's root, or pushed from the sheet listing several Hosts.
struct HostConnectionDetailContent: View {
    let presentation: HostConnectionDetailPresentation
    let host: Host
    let catalog: HostStore
    let sheetPresentation: ConsoleSheetPresentation
    let isRetryInFlight: Bool
    var onStop: (() -> Void)? = nil
    let onRetry: () -> Void

    @State private var isEditing = false

    var body: some View {
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
                Text(
                    presentation.isDialing
                        ? "Connecting to \(presentation.address)…" : presentation.address
                )
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 6) {
                    if presentation.isDialing {
                        Text("Previous attempt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                    }
                    Text(presentation.summary)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(presentation.isDialing ? .secondary : .primary)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .consoleSheetPage()
        // Pinned: however long the failure's detail, the one action
        // stays in reach.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                retryButton
                if presentation.canStop, let onStop {
                    Button("Stop Connecting", role: .cancel, action: onStop)
                        .controlSize(.large)
                        .accessibilityHint(
                            "Stops trying to connect without waiting for a timeout. "
                                + "The Host stays paused until you retry.")
                }
            }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                // A form has no home indicator below it: the button sits as
                // far from the sheet's bottom edge as from its sides.
                .padding(.bottom, sheetPresentation == .form ? 20 : 12)
        }
        .navigationTitle(presentation.hostName)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(StatusFormPageBackground(presentation: sheetPresentation))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            // A full form over the shorter one, so the stack reads as one
            // card rather than two sheet styles layered.
            HostFormView(store: catalog, editing: host)
                .modifier(ConsoleSheetPresentationModifier(presentation: sheetPresentation))
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        let busy = isRetryInFlight || presentation.isDialing
        Button(action: onRetry) {
            Text(busy ? "Connecting…" : "Retry Now")
                // An overlay, not a sibling: the spinner is taller than the
                // label and would grow the button.
                .overlay(alignment: .leading) {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .offset(x: -26)
                    }
                }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // Across a whole form the bar would outweigh the failure it answers.
        .frame(maxWidth: sheetPresentation == .form ? 360 : .infinity)
        // Busy keeps the prominent look rather than a disabled gray, so the
        // spinner reads as work under way.
        .allowsHitTesting(!busy)
        .accessibilityAddTraits(busy ? .updatesFrequently : [])
    }
}

/// A regular-width status sheet's page ground, the same whether the page is
/// the sheet's root or pushed from its list, where navigation would
/// otherwise back the pushed page with its own.
private struct StatusFormPageBackground: ViewModifier {
    let presentation: ConsoleSheetPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        switch presentation {
        case .form:
            content.containerBackground(
                ConsoleStatusSheetPresentationModifier.formBackground, for: .navigation)
        case .inheritedSheet:
            content
        }
    }
}
