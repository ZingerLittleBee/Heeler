import Foundation
import Testing

@testable import Heeler

/// The three one-off request consumers keep every context-specific arm they
/// already had. Only the branch that read `connectionGuidance` now reads
/// `presentation.message` (#163).
@Suite("Request failure presentation")
struct RequestFailurePresentationTests {
    @Test func notificationRegistrationKeepsItsContextSpecificArms() {
        #expect(
            NotificationPreferencesStore.message(
                for: NotificationRegistrationError.pluginNotInstalled)
                == "Install the Heeler plugin on this Host, then check again.")
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
        #expect(
            AttachTerminalStore.message(for: TransportError.cancelled)
                == "The session failed: \(TransportError.cancelled)")
    }

    @Test func attachReplacedBranchRendersTheSharedMessage() {
        #expect(
            AttachTerminalStore.message(for: TransportError.herdrBinaryNotFound)
                == TransportError.herdrBinaryNotFound.presentation.message)
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
    }
}
