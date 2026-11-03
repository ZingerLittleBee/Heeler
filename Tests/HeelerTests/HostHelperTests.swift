import CryptoKit
import Foundation
import Testing
import os

@testable import Heeler

@Suite("Host Helper version and bundle")
struct HostHelperBundleTests {
    private final class BundleLocator {}

    /// The Node tests pin `plugin/helper` to the same vector.
    @Test func bundledVersionMatchesTheSharedVector() throws {
        struct Vector: Decodable { let version: String }
        let url = try #require(
            Bundle(for: BundleLocator.self).url(forResource: "host-helper-version-v1", withExtension: "json"))
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        #expect(HostHelperCompatibility.bundled.description == vector.version)
    }

    /// The real resource: every file the committed manifest names is in the app
    /// and hashes as it says, with the version the app expects.
    @Test func theAppCarriesTheHelperItsManifestDescribes() throws {
        let bundle = try HostHelperBundle.load()
        #expect(bundle.manifest.version == HostHelperCompatibility.bundled.description)
        #expect(bundle.files.keys.contains("main.js"))
        #expect(bundle.files.keys.contains("package.json"))
        #expect(bundle.files.keys.contains(HostHelperScript.extensionPath))
        #expect(bundle.files.keys.contains(HostHelperScript.extensionFoldersPath))
        for file in bundle.manifest.files {
            let contents = try #require(bundle.files[file.path])
            let sum = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            #expect(sum == file.sha256, "\(file.path)")
        }
    }

    @Test func aBuildWithoutTheResourceSaysSo() {
        #expect(throws: HostHelperBundle.LoadError.missing) {
            try HostHelperBundle.load(from: Bundle(for: BundleLocator.self))
        }
    }
}

@Suite("Host Helper install")
struct HostHelperInstallTests {
    private let host = ScriptedHelperHost()
    private let bundle = HostHelperFixture.bundle()
    private let app = "\(ScriptedHelperHost.helperDirectory)/app"
    private var installer: HostHelperInstaller { HostHelperInstaller(host: host) }

    private func install() async throws -> HostHelperReading {
        try await installer.install(over: try await installer.read(), bundle: bundle)
    }

    /// Installs, for a test that starts from a Host with the Helper.
    private func installed() async throws {
        _ = try await install()
        await host.configure { $0.clearLog() }
    }

    @Test func uploadsIntoStagingThenRenamesIntoPlaceAfterTheManifestCheck() async throws {
        _ = try await install()
        let steps = await host.journal
        let upload = try #require(steps.firstIndex { $0.hasSuffix("/main.js") && $0.contains("/staging-") })
        let check = try #require(steps.firstIndex(of: "hashTree"))
        let promote = try #require(steps.firstIndex(of: "promote"))
        #expect(upload < check)
        #expect(check < promote)
        #expect(!steps.contains { $0.hasPrefix("write \(app)/") })
        let files = await host.filePaths()
        #expect(files.contains("\(app)/main.js"))
        #expect(files.contains("\(app)/shared/delivery/push.js"))
        #expect(files.contains("\(app)/manifest.json"))
        #expect(!files.contains { $0.contains("/staging-") })
    }

    @Test func theHelperDirectoryAndItsFilesArePrivateToTheUser() async throws {
        await host.seedFolder(ScriptedHelperHost.helperDirectory, mode: 0o755)
        _ = try await install()
        #expect(await host.folders[ScriptedHelperHost.helperDirectory] == 0o700)
        #expect(await host.folders[app] == 0o700)
        #expect(await host.folders["\(app)/shared/delivery"] == 0o700)
        for path in await host.filePaths() where path.hasPrefix(ScriptedHelperHost.helperDirectory) {
            #expect(await host.files[path]?.mode == 0o600, "\(path)")
        }
        #expect(await host.files[ScriptedHelperHost.unit]?.mode == 0o600)
    }

    @Test func leavesTheUnitsFolderModeAlone() async throws {
        await host.seedFolder("/home/me/.config/systemd/user", mode: 0o755)
        _ = try await install()
        #expect(await host.folders["/home/me/.config/systemd/user"] == 0o755)
    }

    @Test func aFileThatArrivesWrongNeverComesIntoPlace() async throws {
        await host.configure { $0.corruptUploadNamed = "main.js" }
        await #expect(throws: HostHelperError.verificationFailed) { _ = try await install() }
        let files = await host.filePaths()
        #expect(!files.contains { $0.hasPrefix("\(app)/") })
        #expect(!files.contains { $0.contains("/staging-") })
        #expect(await !host.journal.contains("promote"))
        #expect(await !host.journal.contains { $0.hasPrefix("systemctl") })
    }

    @Test func aFailedUploadCleansItsStaging() async throws {
        await host.configure { $0.failUploadsNamed = "version.json" }
        await #expect(throws: HostHelperError.self) { _ = try await install() }
        #expect(await !host.filePaths().contains { $0.contains("/staging-") })
        #expect(await !host.journal.contains("promote"))
    }

    private func uploadFailureMessage(_ error: any Error) async throws -> String {
        await host.configure {
            $0.failUploadsNamed = "version.json"
            $0.uploadError = error
        }
        do {
            _ = try await install()
        } catch let failure as HostHelperError {
            return failure.message
        }
        Issue.record("Expected the upload to fail")
        return ""
    }

    @Test func aFailedUploadSaysWhyInTheHostsWords() async throws {
        let message = try await uploadFailureMessage(
            NotificationRegistrationError.writeFailed(detail: "The SSH connection is unavailable."))
        #expect(message == "Uploading the Host Helper failed: The SSH connection is unavailable.")
    }

    @Test func aFailedUploadOverATransportErrorSaysWhatThatErrorSays() async throws {
        let message = try await uploadFailureMessage(TransportError.timedOut)
        #expect(message == "Uploading the Host Helper failed: \(TransportError.timedOut.presentation.message)")
    }

    /// The sheet's words when the SSH forward dropped mid-upload (hc-lab, 2026-11-03),
    /// whose detail already ends its sentence.
    @Test func aFailedUploadOverADroppedLinkEndsEachSentenceOnce() async throws {
        let message = try await uploadFailureMessage(
            TransportError.sshUnreachable(detail: "The SSH connection is no longer reusable."))
        #expect(
            message
                == "Uploading the Host Helper failed: SSH unavailable: The SSH connection is no longer reusable. "
                + "Check that the Host is awake and reachable, then verify its address and port.")
        #expect(!message.contains(".."))
    }

    @Test func aFailedUploadForAnotherReasonShowsNoTypeName() async throws {
        let message = try await uploadFailureMessage(ScriptedHelperHost.Failure())
        #expect(message == "Uploading the Host Helper failed.")
    }

    @Test func aFolderThatCannotBeMadeTakesBackTheOnesMadeBeforeIt() async throws {
        await host.seedFolder("/home/me/.config")
        let before = await host.folders
        await host.configure { $0.folderRefusal = ("/home/me/.pi/agent", "mkdir: File exists") }
        await #expect(throws: HostHelperError.stepFailed(step: "Creating the folders", detail: "mkdir: File exists")) {
            _ = try await install()
        }
        #expect(await host.folders == before)
        #expect(await host.writes.isEmpty)
    }

    @Test func aRecordThatCannotBeWrittenTakesBackTheFoldersItWouldHaveNamed() async throws {
        await host.seedFolder("/home/me/.config")
        let before = await host.folders
        await host.configure { $0.failUploadsNamed = HostHelperLayout.recordFileName }
        await #expect(throws: HostHelperError.self) { _ = try await install() }
        #expect(await host.folders == before)
    }

    @Test func takingFoldersBackLeavesOneSomethingElseFilled() async throws {
        let mine = "/home/me/.pi/agent/mine.js"
        await host.configure { $0.folderRefusal = ("/home/me/.omp", "mkdir: Permission denied") }
        await host.seedFolder("/home/me/.local/share/heeler")
        await host.seedFile(mine, Data("mine".utf8))
        await #expect(throws: HostHelperError.self) { _ = try await install() }
        #expect(await host.files[mine] != nil)
    }

    @Test func recordsFilesOutsideTheHelperDirectoryAndCreatedFolders() async throws {
        await host.seedFolder("/home/me/.config")
        _ = try await install()
        let data = try #require(await host.files["\(ScriptedHelperHost.helperDirectory)/installed.json"]?.contents)
        let record = try JSONDecoder().decode(HostHelperInstallRecord.self, from: data)
        #expect(record.files == [
            ScriptedHelperHost.unitLink, ScriptedHelperHost.unit,
            "/home/me/.omp/agent/extensions/heeler-session.js",
            "/home/me/.pi/agent/extensions/heeler-session.js",
        ].sorted())
        #expect(record.folders == [
            "/home/me/.config/systemd", "/home/me/.config/systemd/user",
            "/home/me/.config/systemd/user/default.target.wants",
            "/home/me/.local", "/home/me/.local/share", "/home/me/.local/share/heeler",
            "/home/me/.omp", "/home/me/.omp/agent", "/home/me/.omp/agent/extensions",
            "/home/me/.pi", "/home/me/.pi/agent", "/home/me/.pi/agent/extensions",
        ])
    }

    @Test func theRecordIsWrittenBeforeAnythingOutsideTheHelperDirectory() async throws {
        _ = try await install()
        let steps = await host.journal
        let record = try #require(steps.firstIndex(of: "write \(ScriptedHelperHost.helperDirectory)/installed.json"))
        let unit = try #require(steps.firstIndex(of: "write \(ScriptedHelperHost.unit)"))
        #expect(record < unit)
    }

    @Test func aLaterInstallKeepsTheFoldersTheFirstOneCreated() async throws {
        _ = try await install()
        // Everything now exists, so this install creates nothing new.
        let updater = HostHelperFixture.bundle(version: "9.9.9")
        let reading = HostHelperReading(probe: try await installer.read().probe, bundled: PluginVersion(9, 9, 9))
        _ = try await installer.install(over: reading, bundle: updater)
        let data = try #require(await host.files["\(ScriptedHelperHost.helperDirectory)/installed.json"]?.contents)
        let record = try JSONDecoder().decode(HostHelperInstallRecord.self, from: data)
        #expect(record.folders.contains("/home/me/.local/share/heeler"))
    }

    @Test func theSheetsFileListIsExactlyWhatTheInstallWrites() async throws {
        let before = await host.filePaths()
        let plan = try HostHelperInstallPlan(reading: try await installer.read(), bundle: bundle)
        _ = try await install()
        let written = await host.filePaths().subtracting(before)
        #expect(written == Set(plan.files))
        #expect(plan.files.contains(ScriptedHelperHost.unit))
        #expect(plan.files.contains(ScriptedHelperHost.unitLink))
        #expect(plan.files.contains("\(app)/main.js"))
        // The manifest, the record, the unit, its link, and the two default extensions.
        #expect(plan.files.count == bundle.files.count + 6)
    }

    @Test func refusesToReplaceANewerHelper() async throws {
        _ = try await installOlderBuildOverNewer()
    }

    private func installOlderBuildOverNewer() async throws {
        let newer = HostHelperFixture.bundle(version: "9.9.9")
        let reading = HostHelperReading(probe: try await installer.read().probe, bundled: PluginVersion(9, 9, 9))
        _ = try await installer.install(over: reading, bundle: newer)
        let main = await host.files["\(app)/version.json"]
        await host.configure { $0.clearLog() }

        let older = try await installer.read()
        #expect(older.status == .newer(version: PluginVersion(9, 9, 9)))
        #expect(older.installAction == nil)
        await #expect(throws: HostHelperError.newerInstalled(version: PluginVersion(9, 9, 9))) {
            _ = try await installer.install(over: older, bundle: bundle)
        }
        #expect(await host.files["\(app)/version.json"] == main)
        #expect(await host.writes.isEmpty)
        // Only the read's two steps, neither of which changes anything.
        #expect(await host.journal == ["probe", "listExtensionFolders"])
    }

    @Test func aDamagedNewerHelperIsStillNotDowngraded() async throws {
        let newer = HostHelperFixture.bundle(version: "9.9.9")
        let reading = HostHelperReading(probe: try await installer.read().probe, bundled: PluginVersion(9, 9, 9))
        _ = try await installer.install(over: reading, bundle: newer)
        await host.seedFile("\(app)/main.js", Data("changed".utf8))
        let older = try await installer.read()
        #expect(older.status == .newer(version: PluginVersion(9, 9, 9)))
        await #expect(throws: HostHelperError.self) {
            _ = try await installer.install(over: older, bundle: bundle)
        }
    }

    @Test func replacesAnOlderHelper() async throws {
        let older = HostHelperFixture.bundle(version: "0.0.1")
        let reading = HostHelperReading(probe: try await installer.read().probe, bundled: PluginVersion(0, 0, 1))
        _ = try await installer.install(over: reading, bundle: older)
        #expect(try await installer.read().installAction == .update)
        let after = try await install()
        #expect(after.integrity == .intact(version: HostHelperCompatibility.bundled))
    }

    @Test func replacesAHelperWithAMissingFile() async throws {
        try await installed()
        await host.removeFile("\(app)/shared/delivery/push.js")
        let reading = try await installer.read()
        #expect(reading.status == .damaged)
        #expect(reading.installAction == .repair)
        _ = try await installer.install(over: reading, bundle: bundle)
        #expect(await host.filePaths().contains("\(app)/shared/delivery/push.js"))
        #expect(await host.journal.contains("promote"))
    }

    @Test func replacesAHelperWithAChangedFile() async throws {
        try await installed()
        await host.seedFile("\(app)/main.js", Data("changed".utf8))
        let reading = try await installer.read()
        #expect(reading.status == .damaged)
        let after = try await installer.install(over: reading, bundle: bundle)
        #expect(after.integrity == .intact(version: HostHelperCompatibility.bundled))
    }

    @Test func anAddedFileCountsAsDamage() async throws {
        try await installed()
        await host.seedFile("\(app)/extra.js", Data("extra".utf8))
        #expect(try await installer.read().status == .damaged)
    }

    @Test func replacesAHelperWhoseManifestIsGone() async throws {
        try await installed()
        await host.removeFile("\(app)/manifest.json")
        let reading = try await installer.read()
        #expect(reading.status == .damaged)
        #expect(reading.replacesHelper)
    }

    @Test func aHealthyHelperOfTheSameVersionIsLeftInPlace() async throws {
        try await installed()
        let reading = try await installer.read()
        #expect(reading.installAction == nil)
        let plan = try HostHelperInstallPlan(reading: reading, bundle: bundle)
        #expect(!plan.replacesHelper)
        _ = try await installer.install(over: reading, bundle: bundle)
        #expect(await !host.journal.contains("promote"))
    }

    @Test func keepsRegistrationsAcrossAReplacement() async throws {
        try await installed()
        let registrations = "\(ScriptedHelperHost.helperDirectory)/notifications.json"
        await host.seedFile(registrations, Data("{}".utf8))
        await host.seedFile("\(app)/main.js", Data("changed".utf8))
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        #expect(await host.filePaths().contains(registrations))
    }

    @Test func aHelperThatCannotBeHashedIsNotCalledDamaged() async throws {
        try await installed()
        await host.configure { $0.hashToolMissing = true }
        let reading = try await installer.read()
        #expect(reading.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
        #expect(reading.installAction == nil)
        #expect(reading.notificationStanding.canRegister)
    }

    @Test func anUpdateWithNoHashToolStopsAndSaysWhy() async throws {
        let older = HostHelperFixture.bundle(version: "0.0.1")
        let first = HostHelperReading(probe: try await installer.read().probe, bundled: PluginVersion(0, 0, 1))
        _ = try await installer.install(over: first, bundle: older)
        await host.configure { $0.hashToolMissing = true }
        let reading = try await installer.read()
        #expect(reading.installAction == .update)
        await #expect(throws: HostHelperError.noHashTool) {
            _ = try await installer.install(over: reading, bundle: bundle)
        }
    }

    @Test func aManifestThatCannotBeReadIsDamagedEvenWithNoHashTool() async throws {
        try await installed()
        await host.configure { $0.hashToolMissing = true }
        await host.removeFile("\(app)/manifest.json")
        #expect(try await installer.read().status == .damaged)
    }

    @Test func changedFilesOnAHostWithNoNodeSayNodeIsMissing() async throws {
        try await installed()
        await host.seedFile("\(app)/main.js", Data("changed".utf8))
        await host.configure { $0.node = .missing }
        let reading = try await installer.read()
        #expect(reading.status == .nodeMissing(tooOld: nil))
        #expect(reading.installAction == nil)
        #expect(!reading.notificationStanding.canRegister)

        // Repair comes back with Node.js.
        await host.configure { $0.node = .found(path: ScriptedHelperHost.node) }
        let again = try await installer.read()
        #expect(again.status == .damaged)
        #expect(again.installAction == .repair)
    }

    @Test func aHostWithoutNodeCannotInstall() async throws {
        await host.configure { $0.node = .missing }
        let reading = try await installer.read()
        #expect(reading.status == .nodeMissing(tooOld: nil))
        #expect(reading.installAction == nil)
        await #expect(throws: HostHelperError.nodeMissing) {
            _ = try await installer.install(over: reading, bundle: bundle)
        }
        #expect(await host.writes.isEmpty)
    }
}

@Suite("Host Helper service")
struct HostHelperServiceTests {
    private let host = ScriptedHelperHost()
    private let bundle = HostHelperFixture.bundle()
    private var installer: HostHelperInstaller { HostHelperInstaller(host: host) }

    private func install() async throws -> HostHelperReading {
        try await installer.install(over: try await installer.read(), bundle: bundle)
    }

    @Test func theUnitNamesTheAbsoluteNodePathAndRestartsAlways() async throws {
        _ = try await install()
        let unit = try #require(await host.files[ScriptedHelperHost.unit]?.contents)
        let text = String(decoding: unit, as: UTF8.self)
        #expect(text.contains(
            "ExecStart=\"\(ScriptedHelperHost.node)\" \"\(ScriptedHelperHost.helperDirectory)/app/main.js\"\n"))
        #expect(text.contains("Restart=always\n"))
        #expect(!text.contains("on-failure"))
        #expect(text.contains("WantedBy=default.target\n"))
    }

    @Test func startsTheServiceAndReadsItBack() async throws {
        let after = try await install()
        let calls = await host.journal.filter { $0.hasPrefix("systemctl") }
        #expect(calls == [
            "systemctl daemon-reload",
            "systemctl reset-failed heeler-host-helper.service",
            "systemctl enable heeler-host-helper.service",
            "systemctl restart heeler-host-helper.service",
        ])
        #expect(after.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
    }

    /// An Update from `0.0.1`, ready to run.
    private func olderHelper() async throws -> HostHelperReading {
        _ = try await installer.install(
            over: try await installer.read(), bundle: HostHelperFixture.bundle(version: "0.0.1"))
        await host.configure { $0.clearLog() }
        return try await installer.read()
    }

    /// The stopped service is a state the status shows and Repair can leave,
    /// where a running one on replaced files would read as healthy.
    @Test func anUpdateCutOffAfterTheNewFilesAreInPlaceReadsAsStoppedWithRepair() async throws {
        let older = try await olderHelper()
        await host.configure { $0.failUploadsNamed = HostHelperScript.unitName }
        await #expect(throws: HostHelperError.self) {
            _ = try await installer.install(over: older, bundle: bundle)
        }
        await host.configure { $0.failUploadsNamed = nil }

        let reading = try await installer.check()

        guard case .serviceFailed = reading.status else {
            Issue.record("\(reading.status)")
            return
        }
        #expect(reading.installAction == .repair)
        #expect(await host.runningCode == nil)
        _ = try await installer.install(over: reading, bundle: bundle)
        #expect(await host.runningCode == bundle.manifestData)
    }

    @Test func anUpdateStopsTheRunningCopyOnlyOnceItsFilesAreChecked() async throws {
        let older = try await olderHelper()

        _ = try await installer.install(over: older, bundle: bundle)

        let journal = await host.journal
        let hashed = try #require(journal.firstIndex(of: "hashTree"))
        let stopped = try #require(journal.firstIndex(of: "systemctl stop \(HostHelperScript.unitName)"))
        let promoted = try #require(journal.firstIndex(of: "promote"))
        #expect(hashed < stopped)
        #expect(stopped < promoted)
    }

    @Test func aCopyThatWillNotStopKeepsItsFilesAndAnswersTheUpdate() async throws {
        let older = try await olderHelper()
        let manifestPath = "\(ScriptedHelperHost.helperDirectory)/app/manifest.json"
        let manifest = await host.files[manifestPath]
        await host.configure { $0.systemctlFailure = "Access denied" }

        await #expect(throws: HostHelperError.stepFailed(step: "Stopping the service", detail: "Access denied")) {
            _ = try await installer.install(over: older, bundle: bundle)
        }

        #expect(await host.files[manifestPath] == manifest)
        #expect(await !host.journal.contains("promote"))
        #expect(await !host.filePaths().contains { $0.contains("/staging-") })
    }

    @Test func aRunningServiceWhoseNodeHasGoneOffersARepairThatRestartsIt() async throws {
        _ = try await install()
        await host.configure {
            $0.serviceNodeGone = true
            $0.node = .found(path: "/usr/bin/node")
            $0.clearLog()
        }
        let reading = try await installer.check()
        #expect(reading.status == .serviceNodeGone)
        #expect(reading.installAction == .repair)

        let after = try await installer.install(over: reading, bundle: bundle)

        let unit = try #require(await host.files[ScriptedHelperHost.unit]?.contents)
        #expect(String(decoding: unit, as: UTF8.self).contains("ExecStart=\"/usr/bin/node\""))
        #expect(await host.journal.contains("systemctl restart \(HostHelperScript.unitName)"))
        #expect(after.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
    }

    @Test func aRefusedSystemctlShowsWhatItSaid() async throws {
        await host.configure { $0.systemctlFailure = "Failed to connect to bus: No medium found" }
        await #expect(
            throws: HostHelperError.stepFailed(
                step: "Reloading systemd", detail: "Failed to connect to bus: No medium found")
        ) {
            _ = try await install()
        }
    }

    /// The unit's three fields, as `systemctl show` prints them.
    @Test(arguments: [
        ("active", "success", 0, HostHelperStatus.installed(version: HostHelperCompatibility.bundled, updateAvailable: false)),
        // Between two runs of a restart that may yet work.
        ("activating", "exit-code", 2, HostHelperStatus.installed(version: HostHelperCompatibility.bundled, updateAvailable: false)),
        ("failed", "start-limit-hit", 5, HostHelperStatus.serviceFailed(
            HostHelperHealth(loadState: "loaded", activeState: "failed", result: "start-limit-hit", restarts: 5))),
        ("failed", "exit-code", 1, HostHelperStatus.serviceFailed(
            HostHelperHealth(loadState: "loaded", activeState: "failed", result: "exit-code", restarts: 1))),
        ("inactive", "success", 0, HostHelperStatus.serviceFailed(
            HostHelperHealth(loadState: "loaded", activeState: "inactive", result: "success", restarts: 0))),
    ])
    func healthParsesIntoStatus(active: String, result: String, restarts: Int, expected: HostHelperStatus) async throws {
        _ = try await install()
        await host.configure {
            $0.activeState = active
            $0.result = result
            $0.restarts = restarts
        }
        #expect(try await installer.read().status == expected)
    }

    @Test func aUnitThatWentAwayReadsAsDamaged() async throws {
        _ = try await install()
        await host.removeFile(ScriptedHelperHost.unit)
        let reading = try await installer.read()
        #expect(reading.status == .damaged)
        #expect(reading.installAction == .repair)
    }

    @Test func aServiceThatFailedAfterNodeMovedIsRepairedWithTheNodeTheHostHasNow() async throws {
        _ = try await install()
        let moved = "/usr/local/bin/node"
        await host.configure {
            $0.activeState = "failed"
            $0.result = "start-limit-hit"
            $0.restarts = 5
            $0.node = .found(path: moved)
        }
        let reading = try await installer.read()
        #expect(reading.installAction == .repair)
        #expect(!reading.replacesHelper)
        let after = try await installer.install(over: reading, bundle: bundle)
        let unit = try #require(await host.files[ScriptedHelperHost.unit]?.contents)
        #expect(String(decoding: unit, as: UTF8.self).contains("ExecStart=\"\(moved)\""))
        #expect(after.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
    }

    @Test func aServiceThatFailedWithNoNodeLeftSaysNodeIsMissing() async throws {
        _ = try await install()
        await host.configure {
            $0.activeState = "failed"
            $0.result = "exit-code"
            $0.node = .tooOld(version: "18.19.0")
        }
        let reading = try await installer.read()
        #expect(reading.status == .nodeMissing(tooOld: "18.19.0"))
        #expect(HostHelperPresentation(reading.status).detail.contains("18.19.0"))
    }

    @Test func aUserManagerNobodyCanReachIsNotAHealthyHelper() async throws {
        _ = try await install()
        await host.configure { $0.userManagerReachable = false }
        #expect(try await installer.read().status == .serviceFailed(nil))
        await host.configure { $0.lingerOn = false }
        let reading = try await installer.read()
        #expect(reading.status == .serviceFailed(nil))
        // Linger may be the cure, and it is still on offer.
        #expect(reading.offersLinger)
        #expect(!reading.notificationStanding.canRegister)
        #expect(!reading.notificationStanding.drivesLiveActivity)
    }

    @Test func aUnitThatWentAwayOnAHostWithNoNodeSaysNodeIsMissing() async throws {
        _ = try await install()
        await host.removeFile(ScriptedHelperHost.unit)
        await host.configure { $0.node = .tooOld(version: "18.19.0") }
        let reading = try await installer.read()
        #expect(reading.status == .nodeMissing(tooOld: "18.19.0"))
        #expect(reading.installAction == nil)
    }

    private func installNewerHelper() async throws {
        let newer = HostHelperFixture.bundle(version: "9.9.9")
        let reading = HostHelperReading(probe: try await installer.read().probe, bundled: PluginVersion(9, 9, 9))
        _ = try await installer.install(over: reading, bundle: newer)
    }

    @Test func aNewerHelperThatRunsStillReadsAsNewer() async throws {
        try await installNewerHelper()
        let reading = try await installer.read()
        #expect(reading.status == .newer(version: PluginVersion(9, 9, 9)))
        #expect(reading.notificationStanding.canRegister)
        #expect(reading.notificationStanding.drivesLiveActivity)
    }

    @Test func aNewerHelperThatFailedSaysSoAndNamesTheUpdateNotARepair() async throws {
        try await installNewerHelper()
        await host.configure {
            $0.activeState = "failed"
            $0.result = "start-limit-hit"
            $0.restarts = 5
        }
        let reading = try await installer.read()
        #expect(reading.status == .serviceFailed(
            HostHelperHealth(loadState: "loaded", activeState: "failed", result: "start-limit-hit", restarts: 5)))
        #expect(reading.installAction == nil)
        let detail = reading.presentation.detail
        #expect(detail.contains("start-limit-hit"))
        #expect(detail.contains("Update the app"))
        #expect(!detail.contains("Repair"))
        let standing = reading.notificationStanding
        #expect(!standing.canRegister)
        #expect(!standing.drivesLiveActivity)
        #expect(standing.requirement?.contains("Update the app") == true)
        // Still never replaced from here.
        await #expect(throws: HostHelperError.newerInstalled(version: PluginVersion(9, 9, 9))) {
            _ = try await installer.install(over: reading, bundle: bundle)
        }
    }

    @Test func aNewerHelperNobodyCanAskAboutIsNotCalledRunning() async throws {
        try await installNewerHelper()
        await host.configure { $0.userManagerReachable = false }
        let reading = try await installer.read()
        #expect(reading.status == .serviceFailed(nil))
        #expect(!reading.notificationStanding.drivesLiveActivity)
    }

    @Test func aNewerHelperThatStoppedWithNoNodeLeftSaysNodeIsMissing() async throws {
        try await installNewerHelper()
        await host.configure {
            $0.activeState = "failed"
            $0.node = .missing
        }
        #expect(try await installer.read().status == .nodeMissing(tooOld: nil))
    }

    @Test func aFailedServiceShowsItsResultAndRestarts() {
        let health = HostHelperHealth(loadState: "loaded", activeState: "failed", result: "start-limit-hit", restarts: 5)
        let presentation = HostHelperPresentation(.serviceFailed(health))
        #expect(presentation.value == "Service Failed")
        #expect(presentation.detail.contains("start-limit-hit"))
        #expect(presentation.detail.contains("5 restarts"))
        #expect(presentation.needsAttention)
    }
}

@Suite("Host Helper linger")
struct HostHelperLingerTests {
    private let host = ScriptedHelperHost()
    private var installer: HostHelperInstaller { HostHelperInstaller(host: host) }

    @Test func offersLingerWhileItIsOff() async throws {
        await host.configure { $0.lingerOn = false }
        let off = try await installer.read()
        #expect(off.offersLinger)
        await host.configure { $0.lingerOn = true }
        #expect(try await !installer.read().offersLinger)
    }

    @Test func aRunningHelperWithLingerOffSaysSo() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: HostHelperFixture.bundle())
        await host.configure { $0.lingerOn = false }
        let reading = try await installer.read()
        #expect(reading.status == .lingerOff)
        #expect(reading.installAction == nil)
        #expect(HostHelperPresentation(.lingerOff).detail.contains("linger"))
    }

    @Test func turnsLingerOnForTheHostsUser() async throws {
        await host.configure { $0.lingerOn = false }
        try await installer.turnOnLinger(over: try await installer.read())
        #expect(await host.steps.contains(.enableLinger(user: "me")))
        #expect(try await !installer.read().offersLinger)
    }

    @Test func aHostThatAsksForAnAdministratorRefusesWithItsReason() async throws {
        let reason = "Could not enable linger: Interactive authentication required."
        await host.configure {
            $0.lingerOn = false
            $0.lingerRefusal = reason
        }
        let reading = try await installer.read()
        await #expect(throws: HostHelperError.lingerRefused(user: "me", detail: reason)) {
            try await installer.turnOnLinger(over: reading)
        }
        let message = HostHelperError.lingerRefused(user: "me", detail: reason).message
        #expect(message.contains(reason))
        #expect(message.contains("sudo loginctl enable-linger me"))
    }
}

@Suite("Host Helper removal")
struct HostHelperRemovalTests {
    private let host = ScriptedHelperHost()
    private let bundle = HostHelperFixture.bundle()
    private var installer: HostHelperInstaller { HostHelperInstaller(host: host) }
    private let directory = ScriptedHelperHost.helperDirectory

    private func installAndRemove() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        await host.configure { $0.clearLog() }
        try await installer.remove(over: try await installer.read())
    }

    @Test func worksInTheOrderTheDesignSays() async throws {
        try await installAndRemove()
        let steps = await host.journal
        let disable = try #require(steps.firstIndex(of: "systemctl disable --now heeler-host-helper.service"))
        let files = try #require(steps.firstIndex { $0.hasPrefix("removeFiles") })
        let folders = try #require(steps.firstIndex { $0.hasPrefix("removeEmptyFolders") })
        let tree = try #require(steps.firstIndex { $0.hasPrefix("removeTree") })
        #expect(disable < files)
        #expect(files < folders)
        #expect(folders < tree)
        #expect(await host.activeState == "inactive")
    }

    // MARK: The OpenCode edit

    private static let openCodeConfig = "/home/me/.config/opencode/tui.json"
    private static let openCodeFolder = "/home/me/.config/opencode/heeler-opencode"
    private static let openCodeOriginal = Data("{\n  \"theme\": \"dark\"\n}\n".utf8)

    /// An installed Helper on a Host where this device applied the OpenCode edit.
    @MainActor
    private func appliedEdit(
        on hostID: Host.ID, core: ScriptedCoreHost, in edits: HarnessConfigEditStore
    ) async throws {
        await host.seedFile(Self.openCodeConfig, Self.openCodeOriginal)
        let edit = OpenCodePluginEdit.edit(
            configDirectory: "/home/me/.config/opencode", fileName: "tui.json", form: .tuiConfig,
            files: OpenCodePluginEdit.fileNames.map { .init(name: $0, contents: Data($0.utf8)) })
        let editor = HarnessConfigEditor(files: core)
        guard case .change(let change) = try await editor.propose(edit) else {
            Issue.record("expected a change")
            return
        }
        edits.note(try await editor.apply(change), on: hostID)
        await host.configure { $0.clearLog() }
    }

    @MainActor
    @Test func anAppliedEditIsUndoneAfterTheFilesAndFoldersAndBeforeTheDirectory() async throws {
        let core = ScriptedCoreHost(helper: host, channel: .refused)
        let hostID = Host.ID()
        let edits = HarnessConfigEditStore()
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        try await appliedEdit(on: hostID, core: core, in: edits)

        try await installer.remove(over: try await installer.read()) {
            _ = try await edits.undoEditsGoingWithTheHelper(on: hostID, over: core)
        }

        let steps = await host.journal
        let disable = try #require(steps.firstIndex(of: "systemctl disable --now heeler-host-helper.service"))
        let files = try #require(steps.firstIndex { $0.hasPrefix("removeFiles") })
        let folders = try #require(steps.firstIndex { $0.hasPrefix("removeEmptyFolders") })
        let entry = try #require(steps.firstIndex(of: "writeText \(Self.openCodeConfig)"))
        let pluginFile = try #require(steps.firstIndex(of: "removeText \(Self.openCodeFolder)/tui.js"))
        let pluginFolder = try #require(steps.firstIndex(of: "removeFolder \(Self.openCodeFolder)"))
        let tree = try #require(steps.firstIndex { $0.hasPrefix("removeTree") })
        #expect(disable < files)
        #expect(files < folders)
        #expect(folders < entry)
        #expect(entry < pluginFile)
        #expect(pluginFile < pluginFolder)
        #expect(pluginFolder < tree)

        #expect(await host.files[Self.openCodeConfig]?.contents == Self.openCodeOriginal)
        #expect(await host.folders[Self.openCodeFolder] == nil)
        #expect(await host.folders[directory] == nil)
        #expect(edits.edits(on: hostID).isEmpty)
    }

    @MainActor
    @Test func withNoAppliedEditRemovalSkipsTheUndo() async throws {
        let core = ScriptedCoreHost(helper: host, channel: .refused)
        let edits = HarnessConfigEditStore()
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        await host.seedFile(Self.openCodeConfig, Self.openCodeOriginal)
        await host.configure { $0.clearLog() }

        try await installer.remove(over: try await installer.read()) {
            _ = try await edits.undoEditsGoingWithTheHelper(on: Host.ID(), over: core)
        }

        let steps = await host.journal
        #expect(!steps.contains { $0.contains("Text") || $0.hasPrefix("removeFolder") }, "\(steps)")
        #expect(steps.contains { $0.hasPrefix("removeTree") })
        #expect(await host.files[Self.openCodeConfig]?.contents == Self.openCodeOriginal)
    }

    /// Grok Build's edit keeps its own offer and undo.
    @MainActor
    @Test func anotherEditStaysThrough() async throws {
        let core = ScriptedCoreHost(helper: host, channel: .refused)
        let hostID = Host.ID()
        let edits = HarnessConfigEditStore()
        let grok = "/home/me/.grok/config.toml"
        await host.seedFile(grok, Data("[agent]\n".utf8))
        let editor = HarnessConfigEditor(files: core)
        guard case .change(let change) = try await editor.propose(GrokBuildProgramStatusEdit.edit(path: grok)) else {
            Issue.record("expected a change")
            return
        }
        edits.note(try await editor.apply(change), on: hostID)
        let after = await host.files[grok]?.contents
        await host.configure { $0.clearLog() }

        let refusal = try await edits.undoEditsGoingWithTheHelper(on: hostID, over: core)

        #expect(refusal == nil)
        #expect(edits.edits(on: hostID).count == 1)
        #expect(await host.files[grok]?.contents == after)
        #expect(await host.journal.isEmpty)
    }

    /// A file that refuses is no reason to keep a Helper the user wants gone. The
    /// edit stays listed, with its own Undo, and the user is told.
    @MainActor
    @Test func anEditTheFileRefusesStaysListedAndTheHelperStillGoes() async throws {
        let core = ScriptedCoreHost(helper: host, channel: .refused)
        let hostID = Host.ID()
        let edits = HarnessConfigEditStore()
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        try await appliedEdit(on: hostID, core: core, in: edits)
        await host.seedFile(Self.openCodeConfig, Data("broken {".utf8))
        let left = OSAllocatedUnfairLock<String?>(initialState: nil)

        try await installer.remove(over: try await installer.read()) {
            let refusal = try await edits.undoEditsGoingWithTheHelper(on: hostID, over: core)
            left.withLock { $0 = refusal }
        }

        #expect(left.withLock { $0 }?.contains(Self.openCodeConfig) == true)
        #expect(edits.edits(on: hostID).count == 1)
        #expect(await host.files[Self.openCodeConfig]?.contents == Data("broken {".utf8))
        #expect(await host.folders[Self.openCodeFolder] != nil)
        #expect(await host.folders[directory] == nil)
    }

    /// A step that fails stops the removal, as any step's does, with the directory there.
    @Test func aFailedUndoStopsBeforeTheDirectory() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        await host.configure { $0.clearLog() }

        await #expect(throws: TransportError.hostFileTimedOut) {
            try await installer.remove(over: try await installer.read()) { throw TransportError.hostFileTimedOut }
        }

        #expect(await !host.journal.contains { $0.hasPrefix("removeTree") })
        #expect(await host.folders[directory] != nil)
    }

    @Test func leavesNothingBehindOnAHostItFoundEmpty() async throws {
        let foldersBefore = await host.folders
        try await installAndRemove()
        #expect(await host.filePaths().isEmpty)
        #expect(await host.folders == foldersBefore)
    }

    @Test func deletesOnlyRecordedFilesAndOnlyEmptyCreatedFolders() async throws {
        await host.seedFolder("/home/me/.config")
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        // The user's own files, in a folder the install created and one it did not.
        let mine = "/home/me/.config/systemd/user/mine.service"
        await host.seedFile(mine, Data("mine".utf8))
        let other = "/home/me/.config/other.conf"
        await host.seedFile(other, Data("other".utf8))
        await host.configure { $0.clearLog() }

        try await installer.remove(over: try await installer.read())

        #expect(await host.filePaths() == [mine, other])
        let folders = await host.folders
        // Holds the user's file, so it stays with its parents.
        #expect(folders["/home/me/.config/systemd/user"] != nil)
        #expect(folders["/home/me/.config/systemd"] != nil)
        // Created by the install and now empty.
        #expect(folders["/home/me/.config/systemd/user/default.target.wants"] == nil)
        // Not created by the install.
        #expect(folders["/home/me/.config"] != nil)
    }

    @Test func theRecordDecidesWhichFilesGo() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        let recorded = "/home/me/.config/heeler-extension.conf"
        await host.seedFile(recorded, Data("recorded".utf8))
        let record = HostHelperInstallRecord(files: [recorded], folders: [])
        await host.seedFile("\(directory)/installed.json", try JSONEncoder().encode(record))

        try await installer.remove(over: try await installer.read())

        let left = await host.filePaths()
        #expect(!left.contains(recorded))
        // The record does not list it, so it is not removal's to delete.
        #expect(left.contains(ScriptedHelperHost.unit))
    }

    @Test func aFolderTheInstallDidNotCreateStaysEvenWhenEmpty() async throws {
        let existing = "/home/me/.config/systemd/user"
        await host.seedFolder(existing)
        try await installAndRemove()
        #expect(await host.folders[existing] != nil)
        #expect(await host.folders["\(existing)/default.target.wants"] == nil)
    }

    @Test func takesRegistrationsAndSeenMarksWithTheHelperDirectory() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        await host.seedFile("\(directory)/notifications.json", Data("{}".utf8))
        await host.seedFile("\(directory)/seen/device.json", Data("{}".utf8))
        try await installer.remove(over: try await installer.read())
        #expect(await host.folders[directory] == nil)
        #expect(await !host.filePaths().contains { $0.hasPrefix(directory) })
    }

    @Test func leavesLingerAsItIs() async throws {
        try await installAndRemove()
        #expect(await host.lingerOn)
        #expect(await !host.steps.contains(.enableLinger(user: "me")))
    }

    @Test func aFolderAboveTheHelperDirectoryGoesOnceTheDirectoryHas() async throws {
        try await installAndRemove()
        let steps = await host.journal
        let tree = try #require(steps.firstIndex { $0.hasPrefix("removeTree") })
        let last = try #require(steps.lastIndex { $0.hasPrefix("removeEmptyFolders") })
        #expect(tree < last)
        #expect(steps[last].contains("/home/me/.local/share/heeler"))
        #expect(await host.folders["/home/me/.local/share/heeler"] == nil)
    }

    @Test func stopsBeforeDeletingWhenTheServiceCannotBeStopped() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        let before = await host.filePaths()
        await host.configure { $0.systemctlFailure = "Access denied" }
        await #expect(throws: HostHelperError.stepFailed(step: "Stopping the service", detail: "Access denied")) {
            try await installer.remove(over: try await installer.read())
        }
        #expect(await host.filePaths() == before)
    }

    @Test func aHostWithNoUserManagerStillRemoves() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        await host.configure { $0.userManagerReachable = false }
        try await installer.remove(over: try await installer.read())
        #expect(await host.filePaths().isEmpty)
        #expect(await !host.journal.contains("systemctl disable --now heeler-host-helper.service"))
    }

    @Test func aRecordThatIsGoneStillClearsHeelersOwnFiles() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        await host.removeFile("\(directory)/installed.json")
        try await installer.remove(over: try await installer.read())
        #expect(await host.filePaths().isEmpty)
    }

    @Test func aRecordEntryThatClimbsOutIsIgnored() throws {
        let record = HostHelperInstallRecord(
            files: ["/home/me/../../etc/passwd", "relative", "/home/me/ok"],
            folders: ["/", "/home/me/../x", "/home/me/ok-folder"])
        #expect(record.safeFiles == ["/home/me/ok"])
        #expect(record.safeFolders == ["/home/me/ok-folder"])
    }
}

@Suite("Host Helper extensions for Pi and Oh My Pi")
struct HostHelperExtensionTests {
    private let host = ScriptedHelperHost()
    private let bundle = HostHelperFixture.bundle()
    private let directory = ScriptedHelperHost.helperDirectory
    private var installer: HostHelperInstaller { HostHelperInstaller(host: host, bundle: { [bundle] in bundle }) }

    private static let piFile = "/home/me/.pi/agent/extensions/heeler-session.js"
    private static let ompFile = "/home/me/.omp/agent/extensions/heeler-session.js"
    private static let workFile = "/home/me/.omp/profiles/work/agent/extensions/heeler-session.js"
    private static let sideFile = "/home/me/.omp/profiles/side/agent/extensions/heeler-session.js"

    private func withProfiles() async {
        await host.seedFolder("/home/me/.omp/profiles/work")
        await host.seedFolder("/home/me/.omp/profiles/side")
    }

    private func install() async throws {
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
    }

    private func record() async throws -> HostHelperInstallRecord {
        let data = try #require(await host.files["\(directory)/installed.json"]?.contents)
        return try JSONDecoder().decode(HostHelperInstallRecord.self, from: data)
    }

    @Test func asksTheHostsOwnNodeWithTheBundledScriptAndItsHome() async throws {
        _ = try await installer.read()
        let lister = try #require(bundle.files[HostHelperScript.extensionFoldersPath])
        let expected = HostHelperScript.Step.listExtensionFolders(
            node: ScriptedHelperHost.node, lister: String(decoding: lister, as: UTF8.self),
            home: ScriptedHelperHost.home)
        #expect(await host.steps.contains(expected))
    }

    @Test func theSheetListsEveryExtensionFileAndTheInstallWritesThem() async throws {
        await withProfiles()
        let before = await host.filePaths()
        let plan = try HostHelperInstallPlan(reading: try await installer.read(), bundle: bundle)
        for file in [Self.piFile, Self.ompFile, Self.workFile, Self.sideFile] {
            #expect(plan.files.contains(file), "\(file)")
        }
        try await install()
        #expect(await host.filePaths().subtracting(before) == Set(plan.files))
        let extensionText = try #require(bundle.files[HostHelperScript.extensionPath])
        for file in [Self.piFile, Self.ompFile, Self.workFile, Self.sideFile] {
            #expect(await host.files[file]?.contents == extensionText, "\(file)")
        }
    }

    @Test func theRecordListsEachFileAndEveryFolderTheInstallCreated() async throws {
        await host.seedFolder("/home/me/.omp/profiles/work")
        await host.seedFolder("/home/me/.pi/agent")
        try await install()
        let record = try await record()
        for file in [Self.piFile, Self.ompFile, Self.workFile] {
            #expect(record.files.contains(file), "\(file)")
        }
        for folder in [
            "/home/me/.pi/agent/extensions", "/home/me/.omp/agent", "/home/me/.omp/agent/extensions",
            "/home/me/.omp/profiles/work/agent", "/home/me/.omp/profiles/work/agent/extensions",
        ] {
            #expect(record.folders.contains(folder), "\(folder)")
        }
        // The user's, from before the install.
        for folder in ["/home/me/.pi", "/home/me/.pi/agent", "/home/me/.omp", "/home/me/.omp/profiles/work"] {
            #expect(!record.folders.contains(folder), "\(folder)")
        }
    }

    @Test func aHostWithNeitherProgramGetsBothFoldersAndRemovalTakesThemAgain() async throws {
        let foldersBefore = await host.folders
        try await install()
        #expect(await host.files[Self.piFile] != nil)
        #expect(await host.files[Self.ompFile] != nil)
        try await installer.remove(over: try await installer.read())
        #expect(await host.filePaths().isEmpty)
        #expect(await host.folders == foldersBefore)
    }

    @Test func removalDeletesTheFilesThenOnlyCreatedFoldersThatAreNowEmpty() async throws {
        await withProfiles()
        await host.seedFolder("/home/me/.pi/agent/extensions")
        try await install()
        // Another extension of the user's, in a folder the install created.
        let mine = "/home/me/.omp/agent/extensions/mine.js"
        await host.seedFile(mine, Data("mine".utf8))
        await host.configure { $0.clearLog() }

        try await installer.remove(over: try await installer.read())

        let left = await host.filePaths()
        #expect(left == [mine])
        let folders = await host.folders
        // Holds the user's file.
        #expect(folders["/home/me/.omp/agent/extensions"] != nil)
        // Created by the install and now empty.
        #expect(folders["/home/me/.omp/profiles/work/agent"] == nil)
        // From before the install, even though empty now.
        #expect(folders["/home/me/.pi/agent/extensions"] != nil)
        #expect(folders["/home/me/.omp/profiles/work"] != nil)
        let steps = await host.journal
        let files = try #require(steps.firstIndex { $0.hasPrefix("removeFiles") && $0.contains(Self.piFile) })
        let emptied = try #require(steps.firstIndex { $0.hasPrefix("removeEmptyFolders") && $0.contains("/.omp/agent") })
        #expect(files < emptied)
    }

    @Test func aRecordThatIsGoneStillClearsTheExtensions() async throws {
        await withProfiles()
        try await install()
        await host.removeFile("\(directory)/installed.json")
        try await installer.remove(over: try await installer.read())
        #expect(await host.filePaths().isEmpty)
    }

    @Test func aProfileAddedAfterTheInstallIsOfferedARepairThatOnlyAddsIt() async throws {
        try await install()
        #expect(try await installer.read().installAction == nil)
        await host.seedFolder("/home/me/.omp/profiles/work")
        await host.configure { $0.clearLog() }

        let reading = try await installer.read()
        #expect(reading.installAction == .repair)
        #expect(reading.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
        _ = try await installer.install(over: reading, bundle: bundle)

        #expect(await host.files[Self.workFile] != nil)
        #expect(await !host.journal.contains("promote"))
        let record = try await record()
        #expect(record.files.contains(Self.workFile))
        #expect(record.files.contains(Self.piFile))
        #expect(try await installer.read().installAction == nil)
    }

    @Test func anExtensionFileTheUserDeletedComesBackWithARepair() async throws {
        try await install()
        await host.removeFile(Self.piFile)
        let reading = try await installer.read()
        #expect(reading.installAction == .repair)
        _ = try await installer.install(over: reading, bundle: bundle)
        #expect(await host.files[Self.piFile] != nil)
    }

    @Test func aHostThatCannotListItsFoldersIsNotInstalledOnBlindly() async throws {
        await withProfiles()
        await host.configure { $0.extensionFoldersFailure = "node: bad option" }
        let reading = try await installer.read()
        #expect(throws: HostHelperError.extensionFoldersUnreadable) {
            _ = try HostHelperInstallPlan(reading: reading, bundle: bundle)
        }
        await #expect(throws: HostHelperError.extensionFoldersUnreadable) {
            _ = try await installer.install(over: reading, bundle: bundle)
        }
        #expect(await host.writes.isEmpty)
    }

    @Test func removalWorksEvenIfTheFoldersCannotBeListed() async throws {
        await withProfiles()
        try await install()
        await host.configure { $0.extensionFoldersFailure = "node: gone" }
        try await installer.remove(over: try await installer.read())
        #expect(await host.filePaths().isEmpty)
    }

    @Test func aHostWithoutNodeIsNotAskedForFolders() async throws {
        await host.configure { $0.node = .missing }
        _ = try await installer.read()
        #expect(await !host.journal.contains("listExtensionFolders"))
    }

    @Test func theRemovalConfirmationMentionsTheExtensions() {
        #expect(HostHelperSheet.removalMessage.contains("Pi and Oh My Pi extensions"))
    }
}

@Suite("Host Helper probe of hex fields")
struct HostHelperProbeHexTests {
    private func probe(_ line: String) throws -> HostHelperProbe {
        let lines = ["n begin", "home /h", "data /h/d", "config /h/c", line, "n end"]
        return try HostHelperProbe(stdout: Data((lines.joined(separator: "\n") + "\n").utf8), nonce: "n")
    }

    @Test func hexReadsAsItsBytes() throws {
        #expect(try probe("manifest 00fFa5").manifest == Data([0x00, 0xFF, 0xA5]))
        #expect(try probe("record 7b7d").record == Data([0x7B, 0x7D]))
    }

    /// `é` is two UTF-8 bytes and one Character, so its length alone passes as hex.
    @Test(arguments: ["é", "00é", "é00", "zz", "+1", "0"])
    func whatIsNotHexReadsAsNothing(_ hex: String) throws {
        #expect(try probe("manifest \(hex)").manifest == nil)
        #expect(try probe("record \(hex)").record == nil)
    }
}

@Suite("Host Helper status by platform")
struct HostHelperPlatformTests {
    private let host = ScriptedHelperHost()
    private var installer: HostHelperInstaller { HostHelperInstaller(host: host) }

    @Test func aNativeWindowsCoreHostIsUnsupportedAndSaysWhatComesWithTheHelper() async throws {
        await host.configure { $0.platform = .nativeWindows }
        let reading = try await installer.read()
        #expect(reading.status == .unsupportedPlatform(.nativeWindows))
        #expect(reading.installAction == nil)
        #expect(!reading.offersRemoval)
        #expect(!reading.offersLinger)
        // No POSIX shell there to run anything in.
        #expect(await host.scripts.isEmpty)
        let copy = HostHelperPresentation(reading.status).detail
        #expect(copy.contains("Agent Notifications (in-app banners included)"))
        #expect(copy.contains("Live Activity"))
        #expect(copy.contains("Usage"))
        #expect(copy.contains("not available"))
        #expect(copy.contains("Host Helper"))
    }

    @Test func aLinuxHostWithoutSystemdIsOfferedNoInstall() async throws {
        await host.configure { $0.hasSystemd = false }
        let reading = try await installer.read()
        #expect(reading.status == .unsupportedPlatform(.noSystemd))
        #expect(reading.installAction == nil)
    }

    @Test func aHostWithNothingInstalledOffersTheInstall() async throws {
        let reading = try await installer.read()
        #expect(reading.status == .notInstalled)
        #expect(reading.installAction == .install)
        #expect(!reading.offersRemoval)
    }
}
