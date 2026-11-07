import Testing

@testable import Heeler

/// Settings copy that names a harness, a variable or a Host is one whole
/// localized sentence per case, never sentences joined after localizing.
/// These pin the English each case reads as.
@MainActor
@Suite("Settings localization")
struct SettingsLocalizationTests {
    @Test func theAccountsFooterIsOneParagraphPerCase() {
        #expect(
            AccountsListing.footer(for: .claude, variable: "CLAUDE_CONFIG_DIR")
                == "Default is the folder Claude Code uses in herdr’s environment. It can be renamed, not removed. A Launch Preset with an Account sets CLAUDE_CONFIG_DIR to its folder."
        )
        #expect(
            AccountsListing.footer(for: .codex, variable: nil)
                == "Default is the folder Codex uses in herdr’s environment. It can be renamed, not removed. Name the variable Codex reads its folder from to launch an Account."
        )
        #expect(
            AccountsListing.footer(for: .grok, variable: "GROK_HOME")
                == "Default is the folder Grok Build picks itself. A Launch Preset with an Account sets GROK_HOME to its folder."
        )
        #expect(
            AccountsListing.footer(for: .amp, variable: nil)
                == "Default is the folder Amp picks itself. Name the variable Amp reads its folder from to launch an Account."
        )
    }

    @Test func theFolderVariableMessageNamesTheFallbackOnlyWhenThereIsOne() {
        #expect(
            AccountsListing.variableMessage(for: .claude)
                == "The environment variable Claude Code reads its settings folder from. Left empty, Heeler uses CLAUDE_CONFIG_DIR."
        )
        #expect(
            AccountsListing.variableMessage(for: .amp)
                == "The environment variable Amp reads its settings folder from. Launch Presets set it to an Account’s folder."
        )
    }

    @Test func applyingToOtherHostsCountsThemInOneSentence() {
        #expect(
            AgentListFieldsCopy.applyConfirmation(hostName: "Studio", otherHosts: 1)
                == "The other Host's rows, right sides included, are replaced with Studio's and saved right away. Changes you make here later stay on Studio."
        )
        #expect(
            AgentListFieldsCopy.applyConfirmation(hostName: "Studio", otherHosts: 3)
                == "The other 3 Hosts' rows, right sides included, are replaced with Studio's and saved right away. Changes you make here later stay on Studio."
        )
    }
}
