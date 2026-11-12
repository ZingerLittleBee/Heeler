import Foundation
import Testing

@testable import Heeler

@Suite("Terminal password prompt")
struct TerminalPasswordPromptTests {
    @Test(arguments: [
        "[sudo] password for zeng: ",
        "Password:",
        "zeng@debian's password: ",
        "Enter passphrase for key '/home/zeng/.ssh/id_ed25519': ",
        "Enter passphrase (empty for no passphrase):",
        "Current password:",
        "Password for 'https://zeng@github.com':",
        "[sudo] zeng 的密码：",
        "Mot de passe :",
        "Enter PIN for ECDSA-SK key /home/zeng/.ssh/id_ecdsa_sk:",
    ])
    func aPromptOnTheLastLineIsRead(_ prompt: String) {
        let viewport = "zeng@debian:~$ sudo apt update\n\(prompt)\n\n   \n"

        #expect(TerminalPasswordPrompt(viewport: viewport)?.line == prompt.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: [
        "zeng@debian:~$ ",
        "passwd: password updated successfully",
        "Password: changed",
        "Spinning:",
    ])
    func otherLastLinesAreNotPrompts(_ line: String) {
        #expect(TerminalPasswordPrompt(viewport: "[sudo] password for zeng:\n\(line)") == nil)
    }

    @Test func aPromptAboveLaterOutputIsNotOnTheLastLine() {
        let viewport = """
            [sudo] password for zeng:
            Hit:1 http://deb.debian.org/debian trixie InRelease
            All packages are up to date.
            """

        #expect(TerminalPasswordPrompt(viewport: viewport) == nil)
    }

    @Test func aLongLineEndingInAColonIsOutputNotAPrompt() {
        let line = String(repeating: "x", count: TerminalPasswordPrompt.maximumLength) + " password:"

        #expect(TerminalPasswordPrompt(viewport: line) == nil)
    }
}

@MainActor
@Suite("Shell terminal password prompts")
struct ShellTerminalPasswordPromptsTests {
    private let prompt = "zeng@debian:~$ sudo true\n[sudo] password for zeng: "

    @Test func aPromptOnScreenIsOffered() {
        let prompts = ShellTerminalPasswordPrompts()

        prompts.viewportDidChange(prompt)

        #expect(prompts.offered?.line == "[sudo] password for zeng:")
        #expect(prompts.onScreen == prompts.offered)
    }

    @Test func aFilledPromptIsNotOfferedAgainUntilNewOutput() {
        let prompts = ShellTerminalPasswordPrompts()
        prompts.viewportDidChange(prompt + "\n\n\n\n")

        prompts.didFill()
        #expect(prompts.offered == nil)
        // The keyboard comes back and the pane redraws with fewer rows.
        prompts.viewportDidChange(prompt + "\n")
        #expect(prompts.offered == nil)
        // The sheet still quotes what is on screen.
        #expect(prompts.onScreen?.line == "[sudo] password for zeng:")
        // Return only moves the cursor down.
        prompts.viewportDidChange(prompt + "\n\n")
        #expect(prompts.offered == nil)

        prompts.viewportDidChange(prompt + "\nSorry, try again.\n[sudo] password for zeng: ")
        #expect(prompts.offered?.line == "[sudo] password for zeng:")
    }

    @Test func aRedrawThatScrollsTheTopOffIsTheSameScreen() {
        let prompts = ShellTerminalPasswordPrompts()
        prompts.viewportDidChange("Hit:1 http://deb.debian.org/debian trixie InRelease\n" + prompt)
        prompts.didFill()

        // An empty frame partway through the redraw, then fewer rows.
        prompts.viewportDidChange("\n\n")
        prompts.viewportDidChange(prompt)
        #expect(prompts.offered == nil)
        // More rows bring the top back.
        prompts.viewportDidChange("Hit:1 http://deb.debian.org/debian trixie InRelease\n" + prompt + "\n\n")
        #expect(prompts.offered == nil)
    }

    @Test func aRetryThatRepeatsTheLinesBeforeItIsOfferedAgain() {
        let retry = "\nSorry, try again.\n[sudo] password for zeng: "
        let prompts = ShellTerminalPasswordPrompts()
        prompts.viewportDidChange(prompt + retry)
        prompts.didFill()

        prompts.viewportDidChange(prompt + retry + retry)

        #expect(prompts.offered?.line == "[sudo] password for zeng:")
    }

    @Test func aFillWithNoPromptOnScreenHoldsNothingDown() {
        let prompts = ShellTerminalPasswordPrompts()
        prompts.viewportDidChange("\n\n")
        prompts.didFill()

        prompts.viewportDidChange("zeng@debian:~$ sudo true\n[sudo] password for zeng: ")

        #expect(prompts.offered?.line == "[sudo] password for zeng:")
    }

    @Test func theOfferGoesWhenThePromptLeavesTheLastLine() {
        let prompts = ShellTerminalPasswordPrompts()
        prompts.viewportDidChange(prompt)

        prompts.viewportDidChange(prompt + "\nAll packages are up to date.\nzeng@debian:~$ ")

        #expect(prompts.offered == nil)
        #expect(prompts.onScreen == nil)
    }

    @Test func aReplacementSurfaceStartsWithNothingOffered() {
        let prompts = ShellTerminalPasswordPrompts()
        prompts.viewportDidChange(prompt)

        prompts.reset()

        #expect(prompts.offered == nil)
        #expect(prompts.onScreen == nil)
    }
}
