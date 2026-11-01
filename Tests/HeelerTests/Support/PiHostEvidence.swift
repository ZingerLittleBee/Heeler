import Foundation

@testable import Heeler

/// One recording under `ChatFixtures/host-evidence`: what a Host showed of Pi or
/// Oh My Pi in a core Terminal, scrubbed. The core's events came from the same run.
/// A throwaway VM with a fake model and no sign-in made them, and nothing in them
/// carries Heeler's extension (the fixtures README).
struct PiHostEvidence: Decodable {
    struct Process: Decodable {
        let pid: Int
        let parent: Int
        let name: String
        let start: String
        let environment: [String: String]
        let files: [String]
    }

    struct Scene: Decodable {
        let name: String
        let processes: [Process]
    }

    struct Breadcrumb: Decodable {
        let name: String
        let text: String
    }

    struct Breadcrumbs: Decodable {
        let terminal: String
        let states: [Breadcrumb]
    }

    let scenes: [Scene]
    let launchId: String?
    let breadcrumbs: Breadcrumbs?
    let sessionFiles: [String: SessionFile]

    struct SessionFile: Decodable {
        struct Header: Decodable {
            let id: String
            let cwd: String
        }

        let header: Header
    }

    /// `--session-id`'s file in a Pi recording, and each `/new` after it.
    func sessionFile(id: String) -> String? {
        sessionFiles.first { $0.value.header.id == id }?.key
    }

    static func load(_ path: String) throws -> PiHostEvidence {
        try JSONDecoder().decode(PiHostEvidence.self, from: ChatFixture.data("host-evidence/\(path)"))
    }

    func scene(_ name: String) throws -> Scene {
        guard let scene = scenes.first(where: { $0.name == name }) else {
            throw ChatFixture.Missing(path: "scene \(name)")
        }
        return scene
    }

    func breadcrumb(_ name: String) throws -> Data {
        guard let state = breadcrumbs?.states.first(where: { $0.name == name }) else {
            throw ChatFixture.Missing(path: "breadcrumb \(name)")
        }
        return Data(state.text.utf8)
    }

    /// The Terminal's own record as the core reports it. The recording's `created`
    /// event gives its fields and its `foreground` event the process. Its arguments
    /// and labels are the test's to give, since the first are scrubbed and the
    /// second never held anything of Heeler's.
    static func terminal(
        events path: String, foregroundPid pid: Int, argv: [String]? = nil, labels: [String: String] = [:]
    ) throws -> HerdrCoreTerminalRecord {
        let lines = try ChatFixture.text("host-evidence/\(path)").split(separator: "\n")
        let events = try lines.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        func data(ofType type: String, where matches: (JSONValue) -> Bool = { _ in true }) throws -> JSONValue {
            for event in events {
                guard event["params"]?["type"]?.stringValue == type, let data = event["params"]?["data"], matches(data)
                else { continue }
                return data
            }
            throw ChatFixture.Missing(path: "\(type) event in \(path)")
        }
        guard case .object(var fields) = try data(ofType: "created") else {
            throw ChatFixture.Missing(path: "created event's fields in \(path)")
        }
        fields["pid"] = .number(Double(pid))
        fields["labels"] = .object(labels.mapValues(JSONValue.string))
        if let argv { fields["argv"] = .array(argv.map(JSONValue.string)) }
        fields["foreground"] = try data(ofType: "foreground") { $0["pid"] == .number(Double(pid)) }
        return try JSONDecoder().decode(HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }
}
