import UIKit
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// A terminal must never autocorrect: with suggestions on, Space accepts
// the suggestion AND sends the raw key — the PTY gets double input.
// These tests pin every correction trait to `.no` in both text-input
// styles, plus Composer/terminal parity (see AgentComposerUITextView).

@MainActor
@Suite("Terminal input traits")
struct TerminalInputTraitsTests {
    /// The surface the Agent terminal mounts: the natural-language style
    /// must not buy back the correction stack.
    @Test func directInputTerminalKeepsEveryCorrectionTraitOff() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.setTextInputStyle(.naturalLanguage)

        #expect(terminal.autocorrectionType == .no)
        #expect(terminal.spellCheckingType == .no)
        #expect(terminal.smartQuotesType == .no)
        #expect(terminal.smartDashesType == .no)
        #expect(terminal.smartInsertDeleteType == .no)
        #expect(terminal.inlinePredictionType == .no)
        // The one trait the natural-language style still varies:
        // sentence case matches the Composer so the responder transfer
        // keeps one keyboard context.
        #expect(terminal.autocapitalizationType == .sentences)
    }

    /// The Shell default surface, the one every non-Agent terminal uses.
    @Test func shellTerminalKeepsEveryCorrectionTraitOff() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()

        #expect(terminal.autocorrectionType == .no)
        #expect(terminal.spellCheckingType == .no)
        #expect(terminal.smartQuotesType == .no)
        #expect(terminal.smartDashesType == .no)
        #expect(terminal.smartInsertDeleteType == .no)
        #expect(terminal.inlinePredictionType == .no)
        #expect(terminal.autocapitalizationType == .none)
    }

    /// The trait overrides are setter-proof upstream, but a subclass
    /// override with a non-empty setter could flip them again; the
    /// setter must stay inert so a stray assignment (SwiftUI hosting
    /// machinery, keyboard controllers) cannot re-enable suggestions.
    @Test func correctionTraitsIgnoreAssignment() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.setTextInputStyle(.naturalLanguage)

        terminal.autocorrectionType = .default
        terminal.spellCheckingType = .yes
        terminal.smartQuotesType = .default
        terminal.smartDashesType = .default
        terminal.smartInsertDeleteType = .default
        terminal.inlinePredictionType = .default

        #expect(terminal.autocorrectionType == .no)
        #expect(terminal.spellCheckingType == .no)
        #expect(terminal.smartQuotesType == .no)
        #expect(terminal.smartDashesType == .no)
        #expect(terminal.smartInsertDeleteType == .no)
        #expect(terminal.inlinePredictionType == .no)
    }

    /// The Composer shares first responder with the terminal across the
    /// Direct Input handoff; both sides must carry the same no-correction
    /// traits or UIKit rebuilds the keyboard mid-transfer. This is the
    /// parity AgentDirectInputTests asserts from the outside; pinned
    /// here at the trait level so a future Composer change cannot
    /// silently re-open the QuickType gap on one side only.
    @Test func composerInputMatchesTerminalCorrectionTraits() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.setTextInputStyle(.naturalLanguage)
        let composer = AgentComposerUITextView()

        #expect(composer.autocorrectionType == terminal.autocorrectionType)
        #expect(composer.spellCheckingType == terminal.spellCheckingType)
        #expect(composer.smartQuotesType == terminal.smartQuotesType)
        #expect(composer.smartDashesType == terminal.smartDashesType)
        #expect(
            composer.smartInsertDeleteType == terminal.smartInsertDeleteType)
        #expect(
            composer.inlinePredictionType == terminal.inlinePredictionType)
        #expect(
            composer.autocapitalizationType == terminal.autocapitalizationType)
    }
}
