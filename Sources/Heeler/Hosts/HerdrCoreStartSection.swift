import SwiftUI

/// What a herdr-core Host that reads not running offers (ADR 0031).
enum CoreStartOffer: Equatable, Sendable {
    /// A Linux Host: the user may start its core from the app.
    case start
    /// Any other Host: `command` is what to run in a terminal on that machine.
    case instructions(command: String)
    /// A native Windows Host: `command` is PowerShell, for its desktop session.
    case windowsInstructions(command: String)

    var explanation: String? {
        switch self {
        case .start:
            nil
        case .instructions:
            String(localized: "A core started over SSH would run outside the desktop login session, so Heeler does not start one here. In a terminal on that machine, run:")
        case .windowsInstructions:
            String(localized: "A core started over SSH would run outside your desktop session, so Heeler does not start one here. In a PowerShell window on that machine, not run as administrator, run:")
        }
    }
}

/// What the user reads before a Start. Nothing runs until they accept it.
struct CoreStartConfirmation: Equatable, Sendable {
    let session: String

    var message: String {
        String(localized: "This starts the Host's core session \"\(session)\" through your interactive login shell, so the core and every Terminal it starts get the environment of your own terminal. It also tries to turn on systemd linger for your user when it is off.")
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
            String(localized: "Started session \"\(session)\" with the environment of your own terminal.")
        case .alreadyRunning(let session):
            String(localized: "herdr-core was already running for session \"\(session)\", so Start changed nothing.")
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
                case .instructions(let command), .windowsInstructions(let command):
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
        if store.tmuxStartOffer != nil || store.tmuxStart.note != nil {
            Section {
                switch store.tmuxStartOffer {
                case .start:
                    tmuxStartButton
                case .instructions(let command):
                    tmuxInstructions(command)
                case nil:
                    EmptyView()
                }
            } footer: {
                if let note = store.tmuxStart.note {
                    Text(note)
                        .accessibilityIdentifier("hosts.detail.tmuxStart.note")
                }
            }
        }
    }

    private var startButton: some View {
        Button {
            store.requestCoreStart()
        } label: {
            HStack {
                Text(store.coreStart == .running ? String(localized: "Starting herdr-core…") : String(localized: "Start herdr-core"))
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

    private var tmuxStartButton: some View {
        Button {
            store.requestTmuxStart()
        } label: {
            HStack {
                Text(store.tmuxStart == .running ? String(localized: "Starting tmux…") : String(localized: "Start tmux"))
                if store.tmuxStart == .running {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(store.tmuxStart == .running)
        .accessibilityIdentifier("hosts.detail.tmuxStart")
        .alert(
            "Start tmux?",
            isPresented: tmuxConfirmationPresented,
            presenting: store.tmuxStartConfirmation
        ) { _ in
            Button("Start") { Task { await store.confirmTmuxStart() } }
            Button("Cancel", role: .cancel) { store.cancelTmuxStart() }
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

    private func tmuxInstructions(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let explanation = store.tmuxStartOffer?.explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("hosts.detail.tmuxStart.command")
        }
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { store.coreStartConfirmation != nil },
            set: { _ in })
    }

    private var tmuxConfirmationPresented: Binding<Bool> {
        Binding(
            get: { store.tmuxStartConfirmation != nil },
            set: { _ in })
    }
}

enum TmuxStartOffer: Equatable, Sendable {
    case start
    case instructions(command: String)

    static func manualCommand(socketName: String) -> String {
        let normalized = TmuxSocketName.normalized(socketName)
        return normalized == TmuxSocketName.defaultName ? "tmux" : "tmux -L \(normalized)"
    }

    var explanation: String? {
        switch self {
        case .start:
            nil
        case .instructions:
            String(localized: "A tmux server started over SSH would run outside the desktop login session, so Heeler does not start one here. In a terminal on that machine, run:")
        }
    }
}

struct TmuxStartConfirmation: Equatable, Sendable {
    let socket: String

    var message: String {
        if socket == TmuxSocketName.defaultName {
            return String(localized: "This starts a tmux server on the default socket through your interactive login shell, so the server and every Pane it starts get the environment of your own terminal.")
        }
        return String(localized: "This starts a tmux server on socket \"\(socket)\" through your interactive login shell, so the server and every Pane it starts get the environment of your own terminal.")
    }
}

enum TmuxStartState: Equatable, Sendable {
    case idle
    case running
    case started(socket: String)
    case alreadyRunning(socket: String)
    case failed(message: String)

    var note: String? {
        switch self {
        case .idle, .running:
            nil
        case .started(let socket):
            socket == TmuxSocketName.defaultName
                ? String(localized: "Started tmux with the environment of your own terminal.")
                : String(localized: "Started tmux on socket \"\(socket)\" with the environment of your own terminal.")
        case .alreadyRunning(let socket):
            socket == TmuxSocketName.defaultName
                ? String(localized: "tmux was already running, so Start changed nothing.")
                : String(localized: "tmux was already running on socket \"\(socket)\", so Start changed nothing.")
        case .failed(let message):
            message
        }
    }
}
