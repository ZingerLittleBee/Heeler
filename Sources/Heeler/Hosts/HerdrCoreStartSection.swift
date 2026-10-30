import SwiftUI

/// What a herdr-core Host that reads not running offers (ADR 0031).
enum CoreStartOffer: Equatable, Sendable {
    /// A Linux Host: the user may start its core from the app.
    case start
    /// Any other Host: `command` is what to run in a terminal on that machine.
    case instructions(command: String)

    var explanation: String? {
        switch self {
        case .start:
            nil
        case .instructions:
            "A core started over SSH would run outside the desktop login session, so Heeler "
                + "does not start one here. In a terminal on that machine, run:"
        }
    }
}

/// What the user reads before a Start. Nothing runs until they accept it.
struct CoreStartConfirmation: Equatable, Sendable {
    let session: String

    var message: String {
        "This starts the Host's core session \"\(session)\" through your interactive login shell, "
            + "so the core and every Terminal it starts get the environment of your own terminal. "
            + "It also tries to turn on systemd linger for your user when it is off."
    }
}

/// The confirmed action, and what came of the last one.
enum CoreStartState: Equatable, Sendable {
    case idle
    case running
    case started(session: String)
    /// The core predates the Start, so its environment is not the one Start
    /// would have given it, and the note promises none.
    case alreadyRunning(session: String)
    case failed(message: String)

    var note: String? {
        switch self {
        case .idle, .running:
            nil
        case .started(let session):
            "Started session \"\(session)\" with the environment of your own terminal."
        case .alreadyRunning(let session):
            "herdr-core was already running for session \"\(session)\", so Start changed nothing."
        case .failed(let message):
            message
        }
    }
}

/// Below a core Host's checks: its Start or the instructions it has instead,
/// and what came of the last Start.
struct HerdrCoreStartSection: View {
    let store: HostOnboardingStore

    var body: some View {
        if store.coreStartOffer != nil || store.coreStart.note != nil {
            Section {
                switch store.coreStartOffer {
                case .start:
                    startButton
                case .instructions(let command):
                    instructions(command)
                case nil:
                    EmptyView()
                }
            } footer: {
                if let note = store.coreStart.note {
                    Text(note)
                        .accessibilityIdentifier("hosts.detail.coreStart.note")
                }
            }
        }
    }

    private var startButton: some View {
        Button {
            store.requestCoreStart()
        } label: {
            HStack {
                Text(store.coreStart == .running ? "Starting herdr-core…" : "Start herdr-core")
                if store.coreStart == .running {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(store.coreStart == .running)
        .accessibilityIdentifier("hosts.detail.coreStart")
        .alert(
            "Start herdr-core?",
            isPresented: confirmationPresented,
            presenting: store.coreStartConfirmation
        ) { _ in
            Button("Start") { Task { await store.confirmCoreStart() } }
            Button("Cancel", role: .cancel) { store.cancelCoreStart() }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private func instructions(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let explanation = store.coreStartOffer?.explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("hosts.detail.coreStart.command")
        }
    }

    /// The buttons answer it, so a dismissal cannot run anything.
    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { store.coreStartConfirmation != nil },
            set: { _ in })
    }
}
