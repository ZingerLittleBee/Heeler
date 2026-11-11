import Foundation

/// The spaces and tabs the Herdr desktop app keeps in the core document
/// `herdr-app`, in the order it shows them. Heeler only reads this document:
/// the desktop app answers a conflicting write by replacing its own layout
/// (ADR 0032). Every field may be missing, as the app itself reads them, and
/// anything else in the document is ignored.
struct HerdrCoreDesktopDocument: Equatable, Sendable {
    static let name = "herdr-app"

    struct Tab: Equatable, Sendable {
        let id: String
        /// Empty: the desktop app calls it by its place in the space.
        let name: String
        /// Its Terminals in the tree's order. Labels, not this, place a Terminal.
        let terminals: [String]
    }

    struct Space: Equatable, Sendable {
        let id: String
        /// Empty: the desktop app names it after its first Terminal's checkout.
        let name: String
        let folder: String
        let tabs: [Tab]
    }

    let spaces: [Space]

    /// Nil for a document nobody wrote, or one the desktop app could not read either.
    init?(value: JSONValue) {
        guard case .object = value else { return nil }
        guard let listed = value["spaces"] else {
            spaces = []
            return
        }
        guard case .array(let spaces) = listed else { return nil }
        self.spaces = spaces.map { space in
            Space(
                id: space["id"]?.stringValue ?? "", name: space["name"]?.stringValue ?? "",
                folder: space["folder"]?.stringValue ?? "",
                tabs: Self.elements(space["tabs"]).map { tab in
                    Tab(
                        id: tab["id"]?.stringValue ?? "", name: tab["name"]?.stringValue ?? "",
                        terminals: tab["root"].map(Self.terminals) ?? [])
                })
        }
    }

    private static func elements(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let elements)? = value else { return [] }
        return elements
    }

    private static func terminals(in node: JSONValue) -> [String] {
        if let terminal = node["content"]?["terminal"]?.stringValue { return [terminal] }
        return elements(node["children"]).flatMap(terminals)
    }
}

/// What `doc.get` answers. A name never written reads as version 0 and a null
/// value, and a deleted document keeps its version.
struct HerdrCoreDesktopDocumentRead: Equatable, Sendable {
    let document: HerdrCoreDesktopDocument?
    let version: Int
}

extension HerdrCoreTransport {
    /// One read of the desktop app's document from this core. No code path
    /// writes it.
    func readDesktopDocument() async throws -> HerdrCoreDesktopDocumentRead {
        let result = try await call(
            "doc.get", params: .object(["name": .string(HerdrCoreDesktopDocument.name)]),
            isMutation: false)
        guard let version = HerdrCoreWire.integer(result["version"]) else {
            throw TransportError.malformedResponse(String(localized: "herdr-core: A document read has no version."))
        }
        return HerdrCoreDesktopDocumentRead(
            document: result["value"].flatMap(HerdrCoreDesktopDocument.init(value:)),
            version: version)
    }
}
