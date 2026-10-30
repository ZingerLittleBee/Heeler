import Foundation
import Testing

@testable import Heeler

/// Conforms to the seam alone, so every call lands on the seam's own default
/// and proves herdr-core code can adopt it without the Herdr TUI `Transport`.
private struct BareHostServices: HostServices {}
private struct BareNotificationFiles: HostNotificationFiles {}

@Suite("Host services seam")
struct HostServicesSeamTests {
    private let services = BareHostServices()
    private let range = RemoteFileRange(path: "/home/dev/transcript.jsonl", offset: 0, maxBytes: 16)
    private let topLevel = Data("/home/dev/src/app".utf8)

    @Test func stagingStatesThatSFTPIsUnavailable() async {
        let image = PreparedImage(
            fileURL: URL(fileURLWithPath: "/tmp/image.jpg"), format: .jpeg,
            pixelWidth: 1, pixelHeight: 1, byteCount: 1)
        let file = PreparedFile(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"), fileExtension: "txt", byteCount: 1)

        await #expect(throws: AttachmentStagingError.sftpUnavailable) {
            _ = try await services.stageImage(image, progress: { _ in })
        }
        await #expect(throws: AttachmentStagingError.sftpUnavailable) {
            _ = try await services.stageFile(file, progress: { _ in })
        }
    }

    @Test func skillsListEmptyAndRefuseToReadAFile() async throws {
        #expect(try await services.listSkills(SkillListQuery(kind: .claude)).isEmpty)
        await #expect(
            throws: TransportError.channelFailed(detail: "This transport cannot read skill files.")
        ) {
            _ = try await services.readSkillFile(atPath: "/home/dev/.claude/skills/a/SKILL.md")
        }
    }

    @Test func aFileSliceFailsAsAChannelFailure() async {
        await #expect(
            throws: TransportError.channelFailed(detail: "This transport cannot read Host files.")
        ) {
            _ = try await services.readFileSlice(range)
        }
    }

    @Test func chatFileReadsDeclineWithoutALinkFailure() async throws {
        let chat = TransportError.hostFeatureUnavailable(feature: "Chat")
        let session = try #require(OpenCodeSessionID("ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9"))

        await #expect(throws: chat) { _ = try await services.readHostFileRange(range) }
        await #expect(throws: chat) { _ = try await services.fileStatus(atPath: "/home/dev") }
        await #expect(throws: chat) {
            _ = try await services.listFiles(RemoteFileListingRequest(directory: "/home/dev"))
        }
        await #expect(throws: chat) { _ = try await services.hostHomeDirectory() }
        await #expect(throws: chat) {
            _ = try await services.queryOpenCode(
                OpenCodeQuery(session: session, kind: .tail(budget: 1)))
        }
    }

    @Test func thePlatformDefaultsToPOSIX() async throws {
        #expect(try await services.hostPlatform() == .posix)
    }

    @Test func changesStateThatGitIsUnavailable() async {
        await #expect(throws: ChangesReadError.unavailable) {
            _ = try await services.listUntrackedDirectory(
                UntrackedDirectoryRequest(topLevel: topLevel, directory: Data("new/".utf8)))
        }
        await #expect(throws: ChangesReadError.unavailable) {
            _ = try await services.readChanges(ChangesReadRequest(directory: "/home/dev/src/app"))
        }
        await #expect(throws: ChangesReadError.unavailable) {
            _ = try await services.readFilePatch(
                FilePatchRequest(topLevel: topLevel, path: Data("a.swift".utf8), isUntracked: false))
        }
    }

    @Test func aTransportAnswersThroughTheSeamWithItsOwnImplementation() async throws {
        let transport = FakeTransport(
            pingResult: .success(ServerInfo(version: "0.9.0", protocolVersion: 22)))
        await transport.setFileSlices([RemoteFileSlice(data: Data("tail".utf8), length: 4)])
        let services: any HostServices = transport

        let slice = try await services.readFileSlice(range)

        #expect(slice.data == Data("tail".utf8))
        #expect(await transport.fileRanges == [range])
    }
}

@Suite("Host notification files seam")
struct HostNotificationFilesSeamTests {
    private let files = BareNotificationFiles()
    private let contents = Data("{}".utf8)

    @Test func notificationFilesReportThePluginAbsent() async {
        let absent = NotificationRegistrationError.pluginNotInstalled

        await #expect(throws: absent) { _ = try await files.readNotificationRegistration() }
        await #expect(throws: absent) { try await files.replaceNotificationRegistration(contents) }
        await #expect(throws: absent) { _ = try await files.readNotificationConfig() }
        await #expect(throws: absent) { try await files.replaceNotificationConfig(contents) }
    }

    @Test func usageAccountFilesReportThePluginAbsent() async {
        let absent = NotificationRegistrationError.pluginNotInstalled

        await #expect(throws: absent) { _ = try await files.readUsageAccountFile() }
        await #expect(throws: absent) { try await files.replaceUsageAccountFile(contents) }
    }

    @Test func agentUsageDeclinesAsAnUnavailableFeature() async {
        await #expect(throws: TransportError.hostFeatureUnavailable(feature: "Usage")) {
            _ = try await files.readAgentUsage(
                timeZone: "UTC", claudeLimits: false, pluginRoot: "/home/dev/plugin")
        }
    }

    @Test func aTransportKeepsThePluginAbsentDefault() async {
        let files: any HostNotificationFiles = FakeTransport(
            pingResult: .success(ServerInfo(version: "0.9.0", protocolVersion: 22)))

        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            _ = try await files.readNotificationRegistration()
        }
    }
}
