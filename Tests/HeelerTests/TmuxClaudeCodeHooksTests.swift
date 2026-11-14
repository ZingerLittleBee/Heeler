import Foundation
import Testing

@testable import Heeler

/// Heeler's Claude Code hook files on a tmux Host (ADR 0046): the script, the
/// settings a launch passes, and the stored tmux paths the script runs, placed
/// by one script a real `/bin/sh` runs here.
@Suite struct TmuxClaudeCodeHooksTests {
    private static func paths() throws -> TmuxPaths {
        try #require(TmuxPaths(executable: "/opt/homebrew/bin/tmux", socket: "/private/tmp/tmux-501/work"))
    }

    @Test func theFilesAreTheScriptItsLaunchSettingsAndTheStoredPaths() throws {
        let data = "/Users/o'neil/Library/Application Support"
        let files = TmuxClaudeCodeHooks.files(script: Data("script\n".utf8), paths: try Self.paths(), dataHome: data)
        #expect(
            files.map(\.path) == [
                "\(data)/heeler/claude-code/hook.sh",
                "\(data)/heeler/claude-code/hooks.json",
                "\(data)/heeler/host-helper/tmux/work/paths.json",
            ])
        #expect(files[0].contents == Data("script\n".utf8))
        #expect(files[1].contents == ClaudeCodeHooks.launchSettings(script: "\(data)/heeler/claude-code/hook.sh"))
        #expect(
            String(decoding: files[2].contents, as: UTF8.self)
                == #"{"executable":"/opt/homebrew/bin/tmux","socket":"/private/tmp/tmux-501/work"}"# + "\n")
    }

    @Test func theAppCarriesTheScript() throws {
        let script = String(decoding: try TmuxClaudeCodeHooks.bundledScript(), as: UTF8.self)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.hasSuffix("\n"))
        #expect(script.contains("heeler/host-helper/tmux/"))
    }

    @Test func theRootIsTheLaunchsOwnOrTheDefault() {
        #expect(TmuxClaudeCodeHooks.root(environment: [:], home: "/Users/dev") == "/Users/dev/.claude")
        #expect(TmuxClaudeCodeHooks.root(environment: ["CLAUDE_CONFIG_DIR": ""], home: "/Users/dev") == "/Users/dev/.claude")
        #expect(TmuxClaudeCodeHooks.root(environment: ["CLAUDE_CONFIG_DIR": "/srv/work"], home: "/Users/dev") == "/srv/work")
        #expect(TmuxClaudeCodeHooks.root(environment: ["CLAUDE_CONFIG_DIR": "work"], home: "/Users/dev") == nil)
    }

    @Test func theHelpersOwnScriptSaysWhere() throws {
        let stdout = Data("motd\nn1 begin\nhome /home/ana\ndata /home/ana/.local/share\nconfig /home/ana/.config\nn1 end\n".utf8)
        let locations = try TmuxClaudeCodeHooks.locations(stdout: stdout, nonce: "n1")
        #expect(locations.home == "/home/ana")
        #expect(locations.dataHome == "/home/ana/.local/share")
        #expect(String(decoding: TmuxClaudeCodeHooks.locateScript(nonce: "n1"), as: UTF8.self).contains("printf 'data %s\\n'"))
    }

    // MARK: A real shell

    private struct Run {
        let root: URL
        let dataHome: String
    }

    /// A data home whose path has a space and a quote in it.
    private func withRoot(_ body: (Run) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heeler hooks o'neil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(Run(root: root, dataHome: root.appendingPathComponent("data home").path))
    }

    /// What the script printed, and how it ended.
    private func place(_ files: [TmuxClaudeCodeHooks.File], nonce: String, in run: Run) throws -> GitExecResult {
        let script = run.root.appendingPathComponent("place.sh")
        let output = run.root.appendingPathComponent("out")
        let errors = run.root.appendingPathComponent("err")
        try TmuxClaudeCodeHooks.placeScript(files, nonce: nonce).write(to: script)
        let status = try HostShell.run(
            "/bin/sh",
            arguments: ["-c", "/bin/sh \"$1\" > \"$2\" 2> \"$3\"", "sh", script.path, output.path, errors.path],
            // A Host's own PATH; the Simulator's has none of these.
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        return GitExecResult(
            stdout: try Data(contentsOf: output), stderr: try Data(contentsOf: errors), exitStatus: status)
    }

    @Test func placingWritesEachFileWholeAndPrivate() throws {
        try withRoot { run in
            let odd = Data("it's $HOME `date` \\n\n__HEELER_FILE_other\nEOF\nno newline".utf8)
            var files = TmuxClaudeCodeHooks.files(
                script: try TmuxClaudeCodeHooks.bundledScript(), paths: try Self.paths(), dataHome: run.dataHome)
            files.append(.init(path: "\(run.dataHome)/heeler/claude-code/odd", contents: odd))

            let result = try place(files, nonce: "0a1b2c", in: run)

            #expect(
                TmuxClaudeCodeHooks.isPlaced(result, nonce: "0a1b2c"),
                "\(result.exitStatus): \(String(decoding: result.stderr, as: UTF8.self))")
            for file in files.dropLast() {
                #expect(FileManager.default.contents(atPath: file.path) == file.contents, "\(file.path)")
                let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
                #expect(permissions == 0o600, "\(file.path)")
            }
            // A last line with no newline gets one.
            #expect(FileManager.default.contents(atPath: files[3].path) == odd + Data("\n".utf8))
            let folder = try FileManager.default.attributesOfItem(atPath: "\(run.dataHome)/heeler/claude-code")
            #expect(folder[.posixPermissions] as? Int == 0o700)

            // Placing again replaces each file and leaves nothing beside them.
            #expect(TmuxClaudeCodeHooks.isPlaced(try place(Array(files.prefix(2)), nonce: "3d4e5f", in: run), nonce: "3d4e5f"))
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: "\(run.dataHome)/heeler/claude-code").sorted()
                    == ["hook.sh", "hooks.json", "odd"])
        }
    }

    @Test func aFolderThatCanNotBeMadePlacesNothing() throws {
        try withRoot { run in
            try Data("a file\n".utf8).write(to: URL(fileURLWithPath: run.dataHome))
            let files = TmuxClaudeCodeHooks.files(
                script: Data("script\n".utf8), paths: try Self.paths(), dataHome: run.dataHome)

            let result = try place(files, nonce: "0a1b2c", in: run)

            #expect(!TmuxClaudeCodeHooks.isPlaced(result, nonce: "0a1b2c"))
            #expect(result.exitStatus != 0)
        }
    }
}
