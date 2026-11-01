import Foundation

@testable import Heeler

/// `ChatFixtures/host-evidence/<path>.json`, what a throwaway VM recorded of a
/// harness in a core Terminal (the README there says how, and
/// `docs/agents/herdr-compatibility.md` what a signed-in account could change).
struct HostEvidenceFixture: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        var pid: Int
        var parent: Int
        var name: String
        var start: String
        var argv: [String]
        var environment: [String: String]
        var files: [String]

        var process: ScriptedProcessTable.Process {
            ScriptedProcessTable.Process(
                pid: pid, parent: parent, name: name, start: start, environment: environment, argv: argv,
                files: files)
        }
    }

    struct Scene: Decodable, Sendable {
        var name: String
        var processes: [Row]?
        var secondTerminal: [Row]?
        var files: [String: String]?
        var agentProcess: Int?
        var heldByAgentProcess: [String]?
    }

    var version: String
    var scenes: [Scene]
    var files: [String: String]?
    var launchIds: [String: String]?

    static func named(_ path: String) throws -> HostEvidenceFixture {
        try JSONDecoder().decode(Self.self, from: ChatFixture.data("host-evidence/\(path).json"))
    }

    struct MissingScene: Error, CustomStringConvertible {
        let name: String
        var description: String { "No scene \(name) in the recording" }
    }

    func scene(_ name: String) throws -> Scene {
        guard let scene = scenes.first(where: { $0.name == name }) else { throw MissingScene(name: name) }
        return scene
    }
}
