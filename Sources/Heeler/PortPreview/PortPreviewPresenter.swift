import SwiftUI

/// What a detail's surfaces call to show a port preview over it. The detail
/// puts one in the environment. It is a reference that stays the same for
/// the detail's life, so a surface that reads it is never redrawn for it.
@MainActor
final class PortPreviewOpener {
    fileprivate var offers: () -> Bool = { false }
    fileprivate var present: (PortPreviewTarget?) -> Void = { _ in }

    /// Whether the detail's Host has port previews. Read while a menu is
    /// built, it follows the Console as any other offer does.
    var isOffered: Bool { offers() }

    /// Whether `link` names the Host's loopback interface, and so opens here
    /// rather than in the browser, where `localhost` is this device.
    func accepts(_ link: URL) -> Bool {
        isOffered && PortPreviewTarget(link: link) != nil
    }

    /// Shows the page `link` names on the Host. False when it names none,
    /// and the link is the system's to open.
    @discardableResult
    func open(_ link: URL) -> Bool {
        guard isOffered, let target = PortPreviewTarget(link: link) else { return false }
        present(target)
        return true
    }

    /// Shows what listens on the Host.
    func showPorts() {
        guard isOffered else { return }
        present(nil)
    }
}

extension EnvironmentValues {
    @Entry var portPreviewOpener: PortPreviewOpener? = nil
}

enum PortPreviewCopy {
    /// Ports, wherever a menu lists it.
    static let symbol = "network"
}

extension View {
    /// Presents port previews of `hostID` over this detail, and gives its
    /// surfaces the opener that asks for one. `directory` is where the
    /// detail's Agent or terminal works; `sendScreenshot` puts a picture of
    /// the page in the Agent's message where there is one to put it in.
    func portPreview(
        console: ConsoleStore, hostID: Host.ID, directory: String?,
        sendScreenshot: ((Data) -> Void)? = nil
    ) -> some View {
        modifier(PortPreviewPresentation(
            console: console, hostID: hostID, directory: directory, sendScreenshot: sendScreenshot))
    }

    /// Links under this view that name the Host's loopback interface open in
    /// the detail's port preview, once `lowerKeyboard` has run: a menu opened
    /// inside a sheet hands the keyboard back to whatever held it under the
    /// sheet. Every other link stays the system's.
    func portPreviewLinks(
        _ opener: PortPreviewOpener?, lowerKeyboard: @escaping @MainActor () -> Void
    ) -> some View {
        environment(\.openURL, OpenURLAction { link in
            guard let opener, opener.accepts(link) else { return .systemAction }
            lowerKeyboard()
            opener.open(link)
            return .handled
        })
    }
}

private struct PortPreviewPresentation: ViewModifier {
    let console: ConsoleStore
    let hostID: Host.ID
    let directory: String?
    let sendScreenshot: ((Data) -> Void)?
    @State private var opener = PortPreviewOpener()
    @State private var session: PortPreviewSession?

    func body(content: Content) -> some View {
        // On every pass: the opener outlives the values a pass was made with.
        let _ = bind()
        content
            .environment(\.portPreviewOpener, opener)
            .sheet(item: presented) { session in
                PortPreviewView(
                    session: session,
                    isHostConnected: console.hostStatuses[hostID] == .connected,
                    sendScreenshot: sendScreenshot.map { send in
                        { picture in
                            // The message under the sheet is where it went.
                            close()
                            send(picture)
                        }
                    }
                )
                .presentationSizing(.page)
            }
    }

    private func bind() {
        let console = console
        let hostID = hostID
        let directory = directory
        let session = $session
        opener.offers = { console.offersPortPreview(for: hostID) }
        opener.present = { target in
            if let open = session.wrappedValue {
                if let target { open.open(target) }
                return
            }
            session.wrappedValue = console.portPreviewSession(for: hostID, directory: directory, target: target)
        }
    }

    /// The sheet's binding. However the sheet goes, its connection goes too.
    private var presented: Binding<PortPreviewSession?> {
        Binding(
            get: { session },
            set: { next in
                if next == nil { close() } else { session = next }
            })
    }

    private func close() {
        session?.close()
        session = nil
    }
}
