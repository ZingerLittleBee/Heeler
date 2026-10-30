import CryptoKit
import Foundation
import Testing

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

    @Test func recordsFilesOutsideTheHelperDirectoryAndCreatedFolders() async throws {
        await host.seedFolder("/home/me/.config")
        _ = try await install()
        let data = try #require(await host.files["\(ScriptedHelperHost.helperDirectory)/installed.json"]?.contents)
        let record = try JSONDecoder().decode(HostHelperInstallRecord.self, from: data)
        #expect(record.files == [ScriptedHelperHost.unitLink, ScriptedHelperHost.unit].sorted())
        #expect(record.folders == [
            "/home/me/.config/systemd", "/home/me/.config/systemd/user",
            "/home/me/.config/systemd/user/default.target.wants",
            "/home/me/.local", "/home/me/.local/share", "/home/me/.local/share/heeler",
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
        #expect(plan.files.count == bundle.files.count + 4)
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
        #expect(await host.journal == ["probe"])
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

    @Test func everySystemctlCallCarriesTheRuntimeDirectory() async throws {
        _ = try await install()
        try await installer.remove(over: try await installer.read())
        let prefix = "XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\" "
        var count = 0
        for script in await host.scripts {
            let pieces = script.components(separatedBy: "systemctl --user ")
            for piece in pieces.dropLast() {
                count += 1
                #expect(piece.hasSuffix(prefix), "\(script)")
            }
        }
        // Reads, install and removal all reach systemd.
        #expect(count >= 8)
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
        #expect(try await installer.read().status == .lingerOff)
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

    @Test func aMacOSCoreHostIsOfferedNoInstallYet() async throws {
        await host.configure { $0.kernel = "Darwin" }
        let reading = try await installer.read()
        #expect(reading.status == .unsupportedPlatform(.macOS))
        #expect(reading.installAction == nil)
        #expect(!reading.offersRemoval)
        #expect(!reading.offersLinger)
        await #expect(throws: HostHelperError.unsupportedPlatform) {
            _ = try await installer.install(over: reading, bundle: HostHelperFixture.bundle())
        }
        #expect(await host.writes.isEmpty)
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
