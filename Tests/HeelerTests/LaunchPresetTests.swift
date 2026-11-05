import Foundation
import Testing

@testable import Heeler

/// Launch Presets (#622): a named harness, an optional Account, arguments
/// and any environment, saved on the device and picked in New Agent.
@Suite("Launch Presets")
struct LaunchPresetTests {
    private static let home = "/Users/dev"

    private static func preset(
        kind: SupportedAgentKind = .claude, account: String? = nil, arguments: String = "",
        environment: [LaunchPreset.Variable] = []
    ) -> LaunchPreset {
        LaunchPreset(
            name: "Work", kind: kind, accountDirectory: account, arguments: arguments, environment: environment)
    }

    /// The preset's arguments come before the form's; its Account sets the
    /// harness's folder variable; `~` and `$HOME` are the Host's home.
    @Test func aPresetBecomesTheLaunchsArgumentsAndEnvironment() throws {
        let preset = Self.preset(
            account: "~/.claude-work", arguments: "--dangerously-skip-permissions --chrome",
            environment: [
                .init(name: "ANTHROPIC_LOG", value: "debug"),
                .init(name: "NOTES", value: "$HOME/notes:${HOME}/more"),
            ])

        let launch = try preset.launch(formArguments: ["--resume"], home: Self.home, accountVariable: "CLAUDE_CONFIG_DIR")

        #expect(launch.arguments == ["--dangerously-skip-permissions", "--chrome", "--resume"])
        #expect(
            launch.environment == [
                "CLAUDE_CONFIG_DIR": "/Users/dev/.claude-work", "ANTHROPIC_LOG": "debug",
                "NOTES": "/Users/dev/notes:/Users/dev/more",
            ])
    }

    /// A variable named in the preset wins over its Account's.
    @Test func thePresetsOwnVariableWinsOverItsAccounts() throws {
        let preset = Self.preset(
            account: "/srv/.claude-a", environment: [.init(name: "CLAUDE_CONFIG_DIR", value: "~/.claude-b")])
        let launch = try preset.launch(formArguments: [], home: Self.home, accountVariable: "CLAUDE_CONFIG_DIR")
        #expect(launch.environment == ["CLAUDE_CONFIG_DIR": "/Users/dev/.claude-b"])
    }

    @Test func whatStopsAPresetFromLaunching() {
        #expect(throws: LaunchPreset.Problem.noFolderVariable(.amp)) {
            try Self.preset(kind: .amp, account: "~/.amp-work").launch(formArguments: [], home: Self.home, accountVariable: nil)
        }
        #expect(throws: LaunchPreset.Problem.arguments(.unclosedDoubleQuote)) {
            try Self.preset(arguments: #"--name "half"#).launch(formArguments: [], home: Self.home, accountVariable: nil)
        }
        #expect(throws: LaunchPreset.Problem.invalidVariableName("1BAD")) {
            try Self.preset(environment: [.init(name: "1BAD", value: "x")])
                .launch(formArguments: [], home: Self.home, accountVariable: nil)
        }
        #expect(throws: LaunchPreset.Problem.homeUnknown) {
            try Self.preset(account: "~/.claude-work").launch(formArguments: [], home: nil, accountVariable: "CLAUDE_CONFIG_DIR")
        }
    }

    /// Only a value that names the home folder costs a home lookup.
    @Test func onlyAValueNamingTheHomeNeedsIt() throws {
        #expect(!Self.preset(account: "/srv/.claude-a", environment: [.init(name: "A", value: "$HOMER")]).needsHome)
        #expect(Self.preset(environment: [.init(name: "A", value: "${HOME}/x")]).needsHome)
        #expect(Self.preset(account: "~").needsHome)
        let launch = try Self.preset(environment: [.init(name: "A", value: "$HOMER:$HOME")])
            .launch(formArguments: [], home: "/Users/dev/", accountVariable: nil)
        #expect(launch.environment == ["A": "$HOMER:/Users/dev"])
    }

    // MARK: Saved presets

    @MainActor
    @Test func presetsAreSavedOnTheDeviceInTheirOrder() throws {
        let name = "launch-presets-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LaunchPresetStore(defaults: defaults)
        #expect(store.presets.isEmpty)
        var yolo = LaunchPreset(name: "YOLO", kind: .codex, arguments: "--yolo")
        try store.save(yolo)
        try store.save(LaunchPreset(name: "Work", kind: .claude, accountDirectory: "~/.claude-work"))
        yolo.arguments = "--yolo --search"
        try store.save(yolo)

        let reopened = LaunchPresetStore(defaults: defaults)
        #expect(reopened.presets.map(\.name) == ["YOLO", "Work"])
        #expect(reopened.presets.first?.arguments == "--yolo --search")
        reopened.delete(yolo.id)
        #expect(LaunchPresetStore(defaults: defaults).presets.map(\.name) == ["Work"])
    }

    @MainActor
    @Test func aPresetNeedsAUniqueNameAndValidFields() throws {
        let name = "launch-presets-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LaunchPresetStore(defaults: defaults)
        try store.save(LaunchPreset(name: "Work", kind: .claude))
        #expect(store.problem(with: LaunchPreset(name: "  ", kind: .claude)) == "Enter a name for this preset.")
        #expect(store.problem(with: LaunchPreset(name: " work ", kind: .codex)) == "Another preset is named work.")
        #expect(
            store.problem(with: LaunchPreset(name: "B", kind: .claude, arguments: "'open"))
                == StartAgentStore.ArgumentError.unclosedSingleQuote.message)
        #expect(
            store.problem(with: LaunchPreset(name: "B", kind: .claude, environment: [.init(name: "A B", value: "")]))
                == "A B is not a variable name.")
        #expect(
            store.problem(
                with: LaunchPreset(
                    name: "B", kind: .claude, environment: [.init(name: "A", value: "1"), .init(name: "A", value: "2")]))
                == "A is set twice.")
        #expect(throws: LaunchPresetStore.SaveError.self) { try store.save(LaunchPreset(name: "work", kind: .claude)) }
        #expect(store.problem(with: LaunchPreset(name: "Other", kind: .claude)) == nil)
    }
}
