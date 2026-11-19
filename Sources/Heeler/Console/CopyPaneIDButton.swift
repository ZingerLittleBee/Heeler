import SwiftUI
import UIKit

/// Copy Pane ID, as an Agent's detail and the rows of both lists offer it: the
/// id the server's own command line takes for the Pane, so another Agent can
/// be told which Pane to read or type into.
enum PaneIDCopy {
    static let symbol = "number"

    static func copy(_ paneID: String) {
        UIPasteboard.general.string = paneID
    }
}

/// A menu's Copy Pane ID, with the id under the title.
struct CopyPaneIDButton: View {
    let paneID: String

    var body: some View {
        Button {
            PaneIDCopy.copy(paneID)
        } label: {
            Label("Copy Pane ID", systemImage: PaneIDCopy.symbol)
            Text(verbatim: paneID)
        }
    }
}
