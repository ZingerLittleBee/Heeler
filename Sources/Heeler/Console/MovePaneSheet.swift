import Observation
import SwiftUI

/// Move to Workspace, as an Agent's detail and the rows of both lists name it.
enum MovePaneCopy {
    static let action = String(localized: "Move to Workspace")
    /// Not a folder: Files has that one, and an Agent's menu tells its items
    /// apart by their symbols.
    static let symbol = "arrow.up.and.down.and.arrow.left.and.right"
}

/// What Move to Workspace moves: an Agent's or a Terminal's Pane on one Host.
struct MovePaneRequest: Identifiable, Equatable, Sendable {
    let hostID: Host.ID
    let paneID: String
    /// The Pane's own Workspace, which the sheet leaves out.
    let workspaceID: String

    var id: ConsoleAgent.ID { ConsoleAgent.ID(hostID: hostID, paneID: paneID) }

    init(agent: ConsoleAgent) {
        hostID = agent.hostID
        paneID = agent.agent.paneID
        workspaceID = agent.agent.workspaceID
    }

    init(terminal: ConsoleTerminal) {
        hostID = terminal.hostID
        paneID = terminal.paneID
        workspaceID = terminal.workspaceID
    }
}

/// Move to Workspace's one request. A Pane that changes Workspace gets a new
/// id there, which `moved` carries so whoever showed the Pane can follow it.
@MainActor
@Observable
final class MovePaneStore {
    enum State: Equatable {
        case choosing
        case moving(PaneMoveDestination)
        case failed(String)
        case moved(paneID: String)
    }

    let request: MovePaneRequest
    private(set) var state = State.choosing
    private let move: (PaneMoveDestination) async throws -> String

    /// - Parameter move: Moves the Pane and answers the id it has afterwards
    ///   (`ConsoleStore.movePane`).
    init(request: MovePaneRequest, move: @escaping (PaneMoveDestination) async throws -> String) {
        self.request = request
        self.move = move
    }

    var isMoving: Bool {
        if case .moving = state { true } else { false }
    }

    func isMoving(to destination: PaneMoveDestination) -> Bool {
        state == .moving(destination)
    }

    /// The Workspaces the sheet offers: the Host's other ones, by name.
    func destinations(among workspaces: [ConsoleWorkspace]) -> [ConsoleWorkspace] {
        workspaces
            .filter { $0.id != request.workspaceID }
            .sorted {
                let order = $0.label.localizedStandardCompare($1.label)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    func submit(_ destination: PaneMoveDestination) async {
        guard !isMoving else { return }
        if case .moved = state { return }
        state = .moving(destination)
        do {
            state = .moved(paneID: try await move(destination))
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            String(localized: "The Host is not connected.")
        case TransportError.timedOut:
            String(
                localized:
                    "The Host did not answer in time. The move may still have happened, so check the list before trying again."
            )
        case let apiError as HerdrAPIError:
            String(localized: "herdr rejected the move: \(apiError.message)")
        default:
            String(localized: "The move failed: \(String(describing: error))")
        }
    }
}

/// Move to Workspace: the Host's other Workspaces, and a new one. Picking one
/// moves the Pane at once, since nothing about a move needs a second look.
struct MovePaneSheet: View {
    @State private var store: MovePaneStore
    let workspaces: [ConsoleWorkspace]
    /// The id the Pane has after the move.
    let onMoved: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(store: MovePaneStore, workspaces: [ConsoleWorkspace], onMoved: @escaping (String) -> Void) {
        _store = State(initialValue: store)
        self.workspaces = workspaces
        self.onMoved = onMoved
    }

    var body: some View {
        let destinations = store.destinations(among: workspaces)
        NavigationStack {
            List {
                if !destinations.isEmpty {
                    Section {
                        ForEach(destinations) { @Sendable workspace in
                            MainActorContent {
                                row(
                                    workspace.label, systemImage: "folder",
                                    detail: workspace.checkoutPath, to: .workspace(id: workspace.id))
                            }
                        }
                    } footer: {
                        Text("It moves into a new Tab there. What runs in it keeps running.")
                    }
                }
                Section {
                    row(String(localized: "New Workspace"), systemImage: "plus", detail: nil, to: .newWorkspace)
                } footer: {
                    if destinations.isEmpty {
                        Text("This Host has no other Workspace.")
                    }
                }
                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.errorInk)
                    }
                }
            }
            .navigationTitle("Move to Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(store.isMoving)
                }
            }
            .onChange(of: store.state) {
                if case .moved(let paneID) = store.state {
                    onMoved(paneID)
                    dismiss()
                }
            }
            .interactiveDismissDisabled(store.isMoving)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(
        _ title: String, systemImage: String, detail: String?, to destination: PaneMoveDestination
    ) -> some View {
        Button {
            Task { await store.submit(destination) }
        } label: {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .foregroundStyle(Color(uiColor: .label))
                        if let detail {
                            // A Button's label tints `.secondary`, so name the color.
                            Text(verbatim: detail)
                                .font(.footnote)
                                .foregroundStyle(Color(uiColor: .secondaryLabel))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                Spacer(minLength: 0)
                if store.isMoving(to: destination) {
                    ProgressView()
                }
            }
            .contentShape(.rect)
        }
        .disabled(store.isMoving)
    }
}

/// Presents Move to Workspace for a request, from a list or an Agent's detail.
struct MovePaneSheetPresenter: ViewModifier {
    @Binding var request: MovePaneRequest?
    let console: ConsoleStore
    /// The request that moved and the id its Pane has now.
    let onMoved: (MovePaneRequest, String) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            MovePaneSheet(
                store: MovePaneStore(request: request) { [console] destination in
                    try await console.movePane(request.paneID, on: request.hostID, to: destination)
                },
                workspaces: console.workspaces(for: request.hostID),
                onMoved: { onMoved(request, $0) }
            )
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
        }
    }
}
