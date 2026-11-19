import Foundation

/// Where Move to Workspace puts a Pane. herdr can also move one into an
/// existing Tab beside a Pane there; Heeler never asks for that, since it
/// draws no layout to choose a side in.
enum PaneMoveDestination: Equatable, Sendable {
    /// A new Tab of an existing Workspace.
    case workspace(id: String)
    /// A new Workspace, which the Pane has to itself.
    case newWorkspace
}

/// `pane.move`'s params, written by hand: the destination is a tagged union
/// the wire generator does not emit. `focus` is left at herdr's default,
/// false, so the move does not take a desktop client's focus to the Pane.
struct PaneMoveParams: Encodable, Equatable, Sendable {
    let paneID: String
    let destination: PaneMoveDestination

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case destination
    }

    private enum DestinationKeys: String, CodingKey {
        case type
        case workspaceID = "workspace_id"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneID, forKey: .paneID)
        var target = container.nestedContainer(keyedBy: DestinationKeys.self, forKey: .destination)
        switch destination {
        case .workspace(let id):
            try target.encode("new_tab", forKey: .type)
            try target.encode(id, forKey: .workspaceID)
        case .newWorkspace:
            try target.encode("new_workspace", forKey: .type)
        }
    }
}

/// `pane.move`'s `pane_move` result, as much of it as Heeler reads: the layout
/// snapshots it also carries are outside the wire generator's reach. A Pane
/// that changes Workspace gets a new id there, so `pane.paneID` differs from
/// `previousPaneID` (herdr 0.9.5: `w1:p1` moved into `w2` came back `w2:p2`,
/// its `terminal_id` unchanged).
struct PaneMoveResponse: Decodable, Equatable, Sendable {
    struct Result: Decodable, Equatable, Sendable {
        let pane: PaneInfo
        let previousPaneID: String

        private enum CodingKeys: String, CodingKey {
            case pane
            case previousPaneID = "previous_pane_id"
        }
    }

    let moveResult: Result

    private enum CodingKeys: String, CodingKey {
        case moveResult = "move_result"
    }
}
