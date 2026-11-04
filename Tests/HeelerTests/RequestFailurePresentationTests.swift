import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// The three one-off request consumers keep every context-specific arm they
/// already had. Only the branch that read `connectionGuidance` now reads
/// `presentation.message` (#163).
@MainActor
@Suite("Request failure presentation")
struct RequestFailurePresentationTests {
    @Test func notificationRegistrationKeepsItsContextSpecificArms() {
        #expect(
            NotificationPreferencesStore.message(
                for: NotificationRegistrationError.pluginNotInstalled)
                == "The Heeler plugin is missing or turned off on this Host. "
                + "See this Host's page in Hosts, then check again.")
        #expect(
            NotificationPreferencesStore.message(
                for: NotificationRegistrationError.pluginProbeFailed(detail: "boom"))
                == "Could not check the Heeler plugin on this Host. "
                + "Check the connection and try again.")
        #expect(
            NotificationPreferencesStore.message(
                for: NotificationRegistrationError.readFailed(detail: "io"))
                == "Could not read notification settings from this Host. "
                + "Check the connection and try again.")
        #expect(
            NotificationPreferencesStore.message(
                for: NotificationRegistrationError.writeFailed(detail: "disk full"))
                == "Could not update notification settings on this Host. "
                + "Check the connection and try again.")
        #expect(
            NotificationPreferencesStore.message(
                for: NotificationRegistrationError.unsupportedFileVersion(2))
                == "This Host was registered by a newer app version. Update the app.")
        #expect(
            NotificationPreferencesStore.message(
                for: NotificationRegistrationError.deviceNotRegistered)
                == "Register this device for notifications on this Host first.")
        #expect(
            NotificationPreferencesStore.message(
                for: TransportError.sshUnreachable(detail: "down"))
                == "The Host is not connected.")
        #expect(
            NotificationPreferencesStore.message(for: TransportError.timedOut)
                == "The Host did not answer in time.")
        #expect(
            NotificationPreferencesStore.message(for: TransportError.cancelled)
                == "The connection to the Host failed.")
        #expect(
            NotificationPreferencesStore.message(for: CancellationError())
                == "Could not update notification settings. Try again.")
    }

    @Test func notificationRegistrationReplacedBranchRendersTheSharedMessage() {
        #expect(
            NotificationPreferencesStore.message(for: TransportError.herdrBinaryNotFound)
                == TransportError.herdrBinaryNotFound.presentation.message)
        let launcher = TransportError.herdrLauncherNotFound(path: "/opt/example/bin/herdr")
        #expect(
            NotificationPreferencesStore.message(for: launcher)
                == launcher.presentation.message)
    }

    @Test func attachKeepsItsContextSpecificArms() {
        #expect(
            AttachTerminalStore.message(for: TransportError.sshUnreachable(detail: "down"))
                == "The Host is not connected.")
        #expect(
            AttachTerminalStore.message(for: TransportError.terminalChannelAlreadyOpen)
                == "Another terminal is already open on this Host.")
        #expect(
            AttachTerminalStore.message(for: TransportError.timedOut)
                == "The Host did not answer in time.")
        // Attach is cancelled under the user when the Host's connection is
        // replaced, so the copy names the reset rather than a user cancel.
        #expect(
            AttachTerminalStore.message(for: TransportError.cancelled)
                == "The Host's connection was reset.")
    }

    @Test func attachReplacedBranchRendersTheSharedMessage() {
        #expect(
            AttachTerminalStore.message(for: TransportError.herdrBinaryNotFound)
                == TransportError.herdrBinaryNotFound.presentation.message)
        let launcher = TransportError.herdrLauncherNotFound(path: "/opt/example/bin/herdr")
        #expect(AttachTerminalStore.message(for: launcher) == launcher.presentation.message)
        let dropped = TransportError.channelFailed(detail: "terminal controller: gone")
        #expect(
            AttachTerminalStore.message(for: dropped)
                == "Connection dropped: terminal controller: gone.")
        // An unclassified SSH read failure names the side, not its case.
        let readFailure = HeelerSSHTransport.attachFailure(
            HeelerSSHAttachPumpError.output(SSHError.channelFailed),
            attachCommand: "herdr agent attach")
        #expect(
            AttachTerminalStore.message(for: readFailure)
                == "Connection dropped: attach channel failed.")
    }

    /// An old herdr earlier on the SSH PATH exits 1 after losing the server;
    /// the message quotes it instead of only the status (#431).
    @Test func attachExitQuotesHerdrsOwnLine() {
        #expect(
            AttachTerminalStore.message(
                for: TransportError.attachExited(
                    status: 1,
                    output: "herdr: lost connection to server: server closed connection"))
                == "herdr exited with status 1: herdr: lost connection to server: "
                + "server closed connection.")
        #expect(
            AttachTerminalStore.message(
                for: TransportError.attachExited(status: 2, output: "Error: no such pane."))
                == "herdr exited with status 2: Error: no such pane.")
        #expect(
            AttachTerminalStore.message(for: TransportError.attachExited(status: 1, output: nil))
                == "herdr exited with status 1.")
    }

    @Test func attachNeverShowsADebugDescription() {
        #expect(AttachTerminalStore.message(for: CancellationError()) == "The session failed.")
    }

    @Test func composerKeepsItsContextSpecificArms() {
        #expect(
            AgentComposerStore.message(for: TransportError.sshUnreachable(detail: "down"))
                == "The Host is not connected. Check the connection and retry.")
        #expect(
            AgentComposerStore.message(for: TransportError.timedOut)
                == "The Host did not answer. Check the connection and retry.")
        #expect(
            AgentComposerStore.message(
                for: HerdrAPIError(code: "agent_busy", message: "still working"))
                == "herdr rejected the message: still working")
        #expect(
            AgentComposerStore.message(for: CancellationError())
                == "The message could not be sent. Check the connection and retry.")
    }

    @Test func composerReplacedBranchRendersTheSharedMessage() {
        let error = TransportError.channelFailed(detail: "reset")
        #expect(AgentComposerStore.message(for: error) == error.presentation.message)
        #expect(
            AgentComposerStore.message(for: TransportError.herdrBinaryNotFound)
                == TransportError.herdrBinaryNotFound.presentation.message)
        let launcher = TransportError.herdrLauncherNotFound(path: "/opt/example/bin/herdr")
        #expect(AgentComposerStore.message(for: launcher) == launcher.presentation.message)
    }
}
