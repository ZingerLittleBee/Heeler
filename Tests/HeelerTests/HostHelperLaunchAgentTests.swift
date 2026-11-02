import Foundation
import Testing

@testable import Heeler

/// What the spike recorded of `launchctl print` (`plugin/test/fixtures/launchctl/`).
private enum LaunchctlFixture {
    static func text(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("plugin/test/fixtures/launchctl/\(name).txt"),
            encoding: .utf8)
    }

    /// The same run under another process, as the next run of a loop reads.
    static func text(_ name: String, pid: Int) throws -> String {
        try text(name).replacingOccurrences(
            of: #"\tpid = \d+"#, with: "\tpid = \(pid)", options: .regularExpression)
    }
}

@Suite("Host Helper LaunchAgent property list")
struct HostHelperLaunchAgentPropertyListTests {
    @Test func namesNodeByPathStaysUpAndLogsIntoTheHelperDirectory() throws {
        let data = try HostHelperLaunchAgent.propertyList(
            nodePath: "/opt/homebrew/bin/node",
            mainPath: "/Users/me/Library/Application Support/heeler/host-helper/app/main.js",
            logPath: "/Users/me/Library/Application Support/heeler/host-helper/helper.log")
        let list = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(list["Label"] as? String == "dev.bybee.heeler.host-helper")
        #expect(list["ProgramArguments"] as? [String] == [
            "/opt/homebrew/bin/node", "/Users/me/Library/Application Support/heeler/host-helper/app/main.js",
        ])
        #expect(list["KeepAlive"] as? Bool == true)
        #expect(list["RunAtLoad"] as? Bool == true)
        // `user/<uid>` refuses a list without this, and `[Aqua, Background]` lets
        // a desktop login start a copy that blocks the bootstrap (ADR 0033).
        #expect(list["LimitLoadToSessionType"] as? String == "Background")
        #expect(list["StandardOutPath"] as? String == "/Users/me/Library/Application Support/heeler/host-helper/helper.log")
        #expect(list["StandardErrorPath"] as? String == "/Users/me/Library/Application Support/heeler/host-helper/helper.log")
    }

    @Test func keepsPathsWholeWhateverTheyHoldInThem() throws {
        let data = try HostHelperLaunchAgent.propertyList(
            nodePath: "/opt/a&b <c>/node", mainPath: "/Users/d'e/main.js", logPath: "/Users/d'e/helper.log")
        let list = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(list["ProgramArguments"] as? [String] == ["/opt/a&b <c>/node", "/Users/d'e/main.js"])
    }
}

@Suite("launchctl print parser")
struct LaunchctlPrintParserTests {
    private func parsed(_ name: String) throws -> HostHelperHealth {
        HostHelperHealth(launchctlPrint: try LaunchctlFixture.text(name), exitStatus: 0)
    }

    @Test func aRunningAgent() throws {
        let health = try parsed("running")
        #expect(health.isLoaded)
        #expect(health.activeState == "running")
        #expect(health.result == "")
        #expect(health.restarts == 0)
        #expect(health.launchd?.pid == 1116)
    }

    @Test func aRestartedAgentNamesTheSignalAndItsRuns() throws {
        let health = try parsed("restarted")
        #expect(health.activeState == "running")
        #expect(health.result == "signal Killed: 9")
        #expect(health.restarts == 2)
        #expect(health.launchd?.pid == 1285)
    }

    @Test(arguments: [
        ("failed-node-missing", "exit 78: EX_CONFIG", 4),
        ("failed-node-missing-logged-out", "exit 78: EX_CONFIG", 2),
        ("failed-exit-1", "exit 1", 9),
        ("failed-signal-abort", "signal Abort trap: 6", 5),
    ])
    func aFailedAgentHasNoProcessBetweenRuns(name: String, result: String, restarts: Int) throws {
        let health = try parsed(name)
        // Its coalitions' `state = active`, one tab deeper, is not the service's.
        #expect(health.activeState == "spawn scheduled")
        #expect(health.isLoaded)
        #expect(!health.isUp)
        #expect(health.result == result)
        #expect(health.restarts == restarts)
        #expect(health.launchd?.pid == nil)
    }

    /// The README's point: these two differ only in their counters and pid.
    @Test func oneReadCannotTellALoopFromARecovery() throws {
        let looping = try parsed("failed-signal-running")
        let recovered = try parsed("recovered-after-signal")
        #expect(looping.activeState == recovered.activeState)
        #expect(looping.result == recovered.result)
        #expect(looping.isUp)
        #expect(recovered.isUp)
    }

    /// The Host writes this text, so no number in it may trap.
    @Test(arguments: ["-9223372036854775808", "-1", "0"])
    func aRunCountBelowOneCountsNoRestarts(runs: String) {
        let health = HostHelperHealth(
            launchctlPrint: "\tstate = running\n\truns = \(runs)\n\tpid = 1", exitStatus: 0)
        #expect(health.restarts == 0)
    }

    @Test func anAgentTheDomainDoesNotHold() throws {
        let health = HostHelperHealth(
            launchctlPrint: try LaunchctlFixture.text("not-loaded"), exitStatus: 113)
        #expect(health.loadState == HostHelperHealth.launchdNotFound)
        #expect(!health.isLoaded)
    }

    @Test func aDomainThatWillNotAnswerIsNeitherLoadedNorMissing() {
        let health = HostHelperHealth(
            launchctlPrint: "Domain does not support specified action", exitStatus: 125)
        #expect(!health.isLoaded)
        #expect(health.loadState != HostHelperHealth.launchdNotFound)
        #expect(health.result == "launchctl exit 125")
    }
}

/// A Mac through the real installer and the real script steps, on a scripted Host.
@Suite("Host Helper on macOS")
struct HostHelperMacOSTests {
    private let bundle = HostHelperFixture.bundle()
    private let directory = ScriptedHelperHost.macHelperDirectory
    private let agent = ScriptedHelperHost.launchAgent
    private let service = ScriptedHelperHost.macService

    private func installer(_ host: ScriptedHelperHost) -> HostHelperInstaller {
        HostHelperInstaller(host: host, bundle: { HostHelperFixture.bundle() }, healthGap: {})
    }

    private func installed() async throws -> ScriptedHelperHost {
        let host = await ScriptedHelperHost.macOS()
        let installer = installer(host)
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        await host.configure { $0.clearLog() }
        return host
    }

    private func record(_ host: ScriptedHelperHost) async throws -> HostHelperInstallRecord {
        let data = try #require(await host.files["\(directory)/installed.json"]?.contents)
        return try JSONDecoder().decode(HostHelperInstallRecord.self, from: data)
    }

    @Test func aFreshMacOffersTheInstallWithoutLinger() async throws {
        let host = await ScriptedHelperHost.macOS()
        let reading = try await installer(host).read()
        #expect(reading.status == .notInstalled)
        #expect(reading.installAction == .install)
        #expect(!reading.offersLinger)
    }

    @Test func theInstallWritesAndRecordsTheListThenBootstrapsItIntoTheDomain() async throws {
        let host = await ScriptedHelperHost.macOS()
        let installer = installer(host)
        let reading = try await installer.read()

        _ = try await installer.install(over: reading, bundle: bundle)

        let list = try #require(await host.files[agent]?.contents)
        let parsed = try #require(try PropertyListSerialization.propertyList(from: list, format: nil) as? [String: Any])
        #expect(parsed["ProgramArguments"] as? [String] == ["/opt/homebrew/bin/node", "\(directory)/app/main.js"])
        #expect(parsed["StandardOutPath"] as? String == "\(directory)/helper.log")

        let record = try await record(host)
        #expect(record.files.contains(agent))
        #expect(record.launchAgentLabel == "dev.bybee.heeler.host-helper")
        #expect(record.folders.contains("/Users/me/Library/LaunchAgents"))

        let journal = await host.journal
        let wrote = try #require(journal.firstIndex(of: "write \(agent)"))
        let recorded = try #require(journal.firstIndex(of: "write \(directory)/installed.json"))
        let boot = try #require(journal.firstIndex(of: "launchctl bootstrap user/501 \(agent)"))
        #expect(recorded < wrote)
        #expect(wrote < boot)
        #expect(await host.agentLoaded)
        #expect(await !host.steps.contains { if case .systemctl = $0 { true } else { false } })
    }

    /// The write through this seam keeps the directory private. Its 0600 comes
    /// from the SFTP path, which only a real Host runs.
    @Test func theLogGoesThroughThePrivateWriteIntoTheHelperDirectory() async throws {
        let host = await ScriptedHelperHost.macOS()
        let installer = installer(host)
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        let log = try #require(await host.writes.first { $0.path == "\(directory)/helper.log" })
        #expect(log.privateDirectory == directory)
    }

    @Test func anUpdateReplacesARunningCopy() async throws {
        let host = await ScriptedHelperHost.macOS()
        let installer = installer(host)
        _ = try await installer.install(
            over: try await installer.read(), bundle: HostHelperFixture.bundle(version: "0.0.1"))
        await host.configure { $0.clearLog() }
        let older = try await installer.read()
        #expect(older.installAction == .update)

        _ = try await installer.install(over: older, bundle: bundle)

        let journal = await host.journal
        let bootout = try #require(journal.firstIndex(of: "launchctl bootout \(service)"))
        let bootstrap = try #require(journal.firstIndex(of: "launchctl bootstrap user/501 \(agent)"))
        #expect(bootout < bootstrap)
        #expect(await host.agentLoaded)
    }

    /// An Update from `0.0.1`, ready to run.
    private func olderHelper() async throws -> (ScriptedHelperHost, HostHelperInstaller, HostHelperReading) {
        let host = await ScriptedHelperHost.macOS()
        let installer = installer(host)
        _ = try await installer.install(
            over: try await installer.read(), bundle: HostHelperFixture.bundle(version: "0.0.1"))
        await host.configure { $0.clearLog() }
        return (host, installer, try await installer.read())
    }

    /// Past the promote the files are new, so what still ran the old code must
    /// have stopped: one look at launchd then loads the new code.
    @Test func anUpdateCutOffAfterTheNewFilesAreInPlaceNeverLeavesTheOldCodeRunning() async throws {
        let (host, installer, older) = try await olderHelper()
        await host.configure { $0.failUploadsNamed = HostHelperLaunchAgent.fileName }
        await #expect(throws: HostHelperError.self) {
            _ = try await installer.install(over: older, bundle: bundle)
        }
        await host.configure { $0.failUploadsNamed = nil }

        let reading = try await installer.check()

        #expect(reading.status == current)
        #expect(await host.runningCode == bundle.manifestData)
    }

    @Test func anUpdateStopsTheRunningCopyOnlyOnceItsFilesAreChecked() async throws {
        let (host, installer, older) = try await olderHelper()

        _ = try await installer.install(over: older, bundle: bundle)

        let journal = await host.journal
        let hashed = try #require(journal.firstIndex(of: "hashTree"))
        let stopped = try #require(journal.firstIndex(of: "launchctl bootout \(service)"))
        let promoted = try #require(journal.firstIndex(of: "promote"))
        #expect(hashed < stopped)
        #expect(stopped < promoted)
    }

    @Test func aCopyThatWillNotStopKeepsItsFilesAndAnswersTheUpdate() async throws {
        let (host, installer, older) = try await olderHelper()
        let manifest = await host.files["\(directory)/app/manifest.json"]
        await host.configure { $0.bootoutRefusal = (1, "Boot-out failed: 1: Operation not permitted") }

        await #expect(throws: HostHelperError.stepFailed(
            step: "Stopping the service", detail: "Boot-out failed: 1: Operation not permitted")
        ) {
            _ = try await installer.install(over: older, bundle: bundle)
        }

        #expect(await host.files["\(directory)/app/manifest.json"] == manifest)
        #expect(await !host.journal.contains("promote"))
        #expect(await !host.filePaths().contains { $0.contains("/staging-") })
    }

    @Test func aFirstInstallHasNothingToStopBeforeItsFilesGoInPlace() async throws {
        let host = await ScriptedHelperHost.macOS()
        let installer = installer(host)
        await host.configure { $0.bootoutRefusal = (1, "Boot-out failed: 1: Operation not permitted") }

        _ = try await installer.install(over: try await installer.read(), bundle: bundle)

        #expect(await host.runningCode == bundle.manifestData)
    }

    @Test func refusesToReplaceANewerHelper() async throws {
        let host = await ScriptedHelperHost.macOS()
        let installer = installer(host)
        _ = try await installer.install(
            over: try await installer.read(), bundle: HostHelperFixture.bundle(version: "9.9.9"))
        await host.configure { $0.clearLog() }
        let reading = try await installer.read()
        #expect(reading.installAction == nil)
        await #expect(throws: HostHelperError.newerInstalled(version: PluginVersion(9, 9, 9))) {
            _ = try await installer.install(over: reading, bundle: bundle)
        }
        #expect(await host.writes.isEmpty)
    }

    @Test func aRefusedBootstrapSaysFiveHasMoreThanOneCause() async throws {
        let host = await ScriptedHelperHost.macOS()
        await host.configure { $0.bootstrapRefusal = (5, "Bootstrap failed: 5: Input/output error") }
        let installer = installer(host)
        do {
            _ = try await installer.install(over: try await installer.read(), bundle: bundle)
            Issue.record("expected the install to fail")
        } catch let error as HostHelperError {
            guard case .stepFailed(let step, let detail) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(step == "Starting the service")
            #expect(detail.hasPrefix("Bootstrap failed: 5: Input/output error"))
            #expect(detail.contains("more than one cause"))
        }
        // What it wrote is on record, so a removal can still find it.
        #expect(try await record(host).files.contains(agent))
    }

    @Test func removalBootsOutFirstThenFollowsTheLinuxOrder() async throws {
        let host = try await installed()
        let installer = installer(host)
        try await installer.remove(over: try await installer.read())

        let journal = await host.journal.filter { !$0.hasPrefix("probe") && !$0.hasPrefix("listExtensionFolders") }
        #expect(journal.first == "launchctl bootout \(service)")
        #expect(journal.dropFirst().first?.hasPrefix("removeFiles ") == true)
        #expect(journal.dropFirst().first?.contains(agent) == true)
        #expect(journal.dropFirst(2).first?.hasPrefix("removeEmptyFolders ") == true)
        #expect(journal.dropFirst(3).first == "removeTree \(directory)")
        #expect(journal.dropFirst(4).first?.hasPrefix("removeEmptyFolders ") == true)
        #expect(journal.count == 5)
        #expect(await !host.agentLoaded)
        #expect(await host.filePaths().isEmpty)
    }

    @Test func removalLeavesNothingTheInstallMade() async throws {
        let host = await ScriptedHelperHost.macOS()
        let before = await host.folders
        let installer = installer(host)
        _ = try await installer.install(over: try await installer.read(), bundle: bundle)
        try await installer.remove(over: try await installer.read())
        #expect(await host.folders == before)
        #expect(await host.filePaths().isEmpty)
    }

    @Test func removalBootsOutTheLabelTheRecordLists() async throws {
        let host = try await installed()
        let record = HostHelperInstallRecord(files: [agent], folders: [], launchAgentLabel: "dev.bybee.heeler.other")
        await host.seedFile("\(directory)/installed.json", try JSONEncoder().encode(record))
        let installer = installer(host)
        await host.configure { $0.bootoutRefusal = (0, "") }
        try await installer.remove(over: try await installer.read())
        #expect(await host.journal.contains("launchctl bootout user/501/dev.bybee.heeler.other"))
    }

    @Test func aRefusedBootoutStopsTheRemovalBeforeItDeletesAnything() async throws {
        let host = try await installed()
        await host.configure { $0.bootoutRefusal = (1, "Boot-out failed: 1: Operation not permitted") }
        let installer = installer(host)
        await #expect(throws: HostHelperError.stepFailed(
            step: "Stopping the service", detail: "Boot-out failed: 1: Operation not permitted")
        ) {
            try await installer.remove(over: try await installer.read())
        }
        #expect(await host.files[agent] != nil)
    }

    @Test func anAgentAlreadyGoneDoesNotStopTheRemoval() async throws {
        let host = try await installed()
        await host.configure { $0.agentLoaded = false }
        let installer = installer(host)
        try await installer.remove(over: try await installer.read())
        #expect(await host.filePaths().isEmpty)
    }

    /// Only `launchctl print` has been seen to answer this, which still can only
    /// mean launchd holds nothing to stop.
    @Test func aBootoutAnsweringThatItFindsNoServiceDoesNotStopTheRemoval() async throws {
        let host = try await installed()
        await host.configure { $0.bootoutRefusal = (HostHelperHealth.launchctlNotLoadedStatus, "Could not find service") }
        let installer = installer(host)
        try await installer.remove(over: try await installer.read())
        #expect(await host.files[agent] == nil)
    }

    /// Another connection reading the Helper in that moment finds no property
    /// list to load, so nothing outlives the removal in launchd with no record.
    @Test func aReadRightAfterTheRemovalsBootoutLoadsNothing() async throws {
        let host = try await installed()
        let installer = installer(host)
        let other = HostHelperInstaller(host: host, bundle: { HostHelperFixture.bundle() }, healthGap: {})
        await host.configure {
            $0.afterBootout = { _ = try? await other.readLoadingAgent() }
        }

        try await installer.remove(over: try await installer.read())

        #expect(await !host.agentLoaded)
        #expect(await !host.journal.contains("launchctl bootstrap user/501 \(agent)"))
    }

    @Test func turningOnLingerIsNotAThingOnAMac() async throws {
        let host = try await installed()
        let installer = installer(host)
        await #expect(throws: HostHelperError.unsupportedPlatform) {
            try await installer.turnOnLinger(over: try await installer.read())
        }
        #expect(await !host.steps.contains(.enableLinger(user: "me")))
    }

    // MARK: Health

    private func checked(_ prints: [String]) async throws -> (HostHelperStatus, ScriptedHelperHost) {
        let host = try await installed()
        await host.configure { $0.launchctlPrints = prints }
        return (try await installer(host).check().status, host)
    }

    private var current: HostHelperStatus {
        .installed(version: HostHelperCompatibility.bundled, updateAvailable: false)
    }

    @Test func twoReadsOfOneRunCallItRunning() async throws {
        let (status, host) = try await checked([
            try LaunchctlFixture.text("running"), try LaunchctlFixture.text("running"),
        ])
        #expect(status == current)
        #expect(await host.steps.filter { if case .launchctl = $0 { true } else { false } }.count == 1)
    }

    @Test func aRestartedAgentThatStaysUpReadsAsRunning() async throws {
        let (status, _) = try await checked([
            try LaunchctlFixture.text("restarted"), try LaunchctlFixture.text("restarted"),
        ])
        #expect(status == current)
    }

    /// Node.js moved away: launchd reports no failed state, only this.
    @Test(arguments: ["failed-node-missing", "failed-node-missing-logged-out", "failed-exit-1", "failed-signal-abort"])
    func aHelperThatKeepsFailingReadsAsFailed(name: String) async throws {
        let (status, _) = try await checked([
            try LaunchctlFixture.text(name), try LaunchctlFixture.text(name),
        ])
        guard case .serviceFailed(let health) = status else {
            Issue.record("\(status)")
            return
        }
        #expect(health?.activeState == "spawn scheduled")
        #expect(health?.launchd?.staysRunning == false)
    }

    @Test func aLoopCaughtMidRunIsNotCalledRunning() async throws {
        let (status, _) = try await checked([
            try LaunchctlFixture.text("failed-signal-running"), try LaunchctlFixture.text("failed-signal-abort"),
        ])
        guard case .serviceFailed = status else {
            Issue.record("\(status)")
            return
        }
    }

    @Test func aLoopCaughtMidRunTwiceIsNotCalledRunning() async throws {
        let (status, _) = try await checked([
            try LaunchctlFixture.text("failed-signal-running", pid: 100),
            try LaunchctlFixture.text("failed-signal-running", pid: 200),
            try LaunchctlFixture.text("failed-signal-running", pid: 300),
        ])
        guard case .serviceFailed = status else {
            Issue.record("\(status)")
            return
        }
    }

    @Test func aFirstReadBetweenTwoRunsDoesNotCondemnARecovery() async throws {
        let (status, _) = try await checked([
            try LaunchctlFixture.text("failed-signal-abort"),
            try LaunchctlFixture.text("recovered-after-signal"),
            try LaunchctlFixture.text("recovered-after-signal"),
        ])
        #expect(status == current)
    }

    /// A known gap of the rule: only the counters would show this.
    @Test func aRunThatOutlivesTheGapIsCalledRunning() async throws {
        let (status, _) = try await checked([
            try LaunchctlFixture.text("failed-signal-running"), try LaunchctlFixture.text("failed-signal-running"),
        ])
        #expect(status == current)
    }

    @Test func readingIsNotWaitedForWhereLaunchdHoldsNothing() async throws {
        let host = await ScriptedHelperHost.macOS()
        let reading = try await installer(host).check()
        #expect(reading.status == .notInstalled)
        #expect(await host.steps.filter { if case .launchctl = $0 { true } else { false } }.isEmpty)
    }

    @Test func aFailedHelperOffersRepairAndSaysWhatItRead() async throws {
        let host = try await installed()
        let failing = try LaunchctlFixture.text("failed-node-missing")
        await host.configure { $0.launchctlPrints = [failing, failing] }
        let reading = try await installer(host).check()
        #expect(reading.installAction == .repair)
        let presentation = reading.presentation
        #expect(presentation.value == "Service Failed")
        #expect(presentation.detail.contains("spawn scheduled"))
        #expect(presentation.detail.contains("exit 78: EX_CONFIG"))
        #expect(presentation.detail.contains("4 restarts"))
        #expect(presentation.detail.contains("Repair"))
        #expect(!presentation.detail.contains("systemd"))
    }

    @Test func aRepairWritesTheNodeTheHostHasNowAndLoadsItAgain() async throws {
        let host = try await installed()
        let failing = try LaunchctlFixture.text("failed-node-missing")
        await host.configure {
            $0.launchctlPrints = [failing, failing]
            $0.node = .found(path: "/usr/local/bin/node")
        }
        let installer = installer(host)
        let reading = try await installer.check()
        _ = try await installer.install(over: reading, bundle: bundle)
        let list = try #require(await host.files[agent]?.contents)
        let parsed = try #require(try PropertyListSerialization.propertyList(from: list, format: nil) as? [String: Any])
        #expect((parsed["ProgramArguments"] as? [String])?.first == "/usr/local/bin/node")
        let journal = await host.journal
        #expect(journal.contains("launchctl bootout \(service)"))
        #expect(journal.contains("launchctl bootstrap user/501 \(agent)"))
        #expect(!journal.contains { $0.contains("kickstart") })
    }

    // MARK: A restart of the Mac

    @Test func anAgentARestartLeftOutIsLoadedAgainWithoutWritingAnything() async throws {
        let host = try await installed()
        await host.configure { $0.agentLoaded = false }
        let reading = try await installer(host).check()
        #expect(reading.status == current)
        #expect(await host.journal.contains("launchctl bootstrap user/501 \(agent)"))
        #expect(await host.writes.isEmpty)
    }

    @Test func aLoadThatFailsReadsAsFailedWithRepairOnOffer() async throws {
        let host = try await installed()
        await host.configure {
            $0.agentLoaded = false
            $0.bootstrapRefusal = (5, "Bootstrap failed: 5: Input/output error")
        }
        let reading = try await installer(host).check()
        guard case .serviceFailed = reading.status else {
            Issue.record("\(reading.status)")
            return
        }
        #expect(reading.installAction == .repair)
        #expect(reading.presentation.detail.contains("launchd does not have the service loaded"))
    }

    @Test func aPlainReadChangesNothing() async throws {
        let host = try await installed()
        await host.configure { $0.agentLoaded = false }
        _ = try await installer(host).read()
        #expect(await !host.agentLoaded)
    }

    @Test func aMissingPropertyListIsDamageARepairPutsBack() async throws {
        let host = try await installed()
        await host.configure { $0.agentLoaded = false }
        await host.removeFile(agent)
        let reading = try await installer(host).check()
        #expect(reading.status == .damaged)
        #expect(await !host.agentLoaded)
        #expect(reading.installAction == .repair)
    }

    @Test func nothingIsLoadedWithoutARecordOrWithNoNode() async throws {
        let host = try await installed()
        await host.configure {
            $0.agentLoaded = false
            $0.node = .missing
        }
        #expect(try await installer(host).check().status == .nodeMissing(tooOld: nil))
        #expect(await !host.agentLoaded)
        await host.configure { $0.node = .found(path: "/opt/homebrew/bin/node") }
        await host.removeFile("\(directory)/installed.json")
        _ = try await installer(host).check()
        #expect(await !host.agentLoaded)
    }

    // MARK: Files and notifications

    /// Usage's own path is the script's, which test-host-helper-scripts.py runs.
    @Test func registrationsGoToApplicationSupport() async throws {
        let host = try await installed()
        let files = HostHelperFiles(host: host, session: "default")
        try await files.replaceNotificationRegistration(Data("{}".utf8))
        let written = await host.writes.map(\.path)
        #expect(written.first == "\(directory)/\(HeelerSSHTransport.notificationRegistrationFileName)")
    }

    @Test func aPlainReadOfTheHelperLoadsAnAgentARestartLeftOut() async throws {
        let host = try await installed()
        await host.configure { $0.agentLoaded = false }
        let reading = try #require(try await HostHelperFiles(host: host).readHostHelper())
        #expect(await host.agentLoaded)
        #expect(reading.notificationStanding.canRegister)
    }

    @Test func aHelperThatKeepsFailingStandsInTheWayOfNotifications() async throws {
        let host = try await installed()
        let failing = try LaunchctlFixture.text("failed-node-missing")
        await host.configure { $0.launchctlPrints = [failing] }
        let reading = try #require(try await HostHelperFiles(host: host).readHostHelper())
        let standing = reading.notificationStanding
        #expect(!standing.canRegister)
        #expect(standing.requirement?.hasPrefix("Host Helper: Service Failed.") == true)
    }
}

/// The install sheet's model on a Mac, through the real framed transport.
@Suite("Host Helper store on macOS")
@MainActor
struct HostHelperStoreMacOSTests {
    private let bundle = HostHelperFixture.bundle()

    private func store(_ helper: ScriptedHelperHost) -> HostHelperStore {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let bundle = bundle
        return HostHelperStore(connect: { core.transport() }, bundle: { bundle }, healthGap: {})
    }

    @Test func theSheetIsTheSameListWithoutTheLingerRow() async throws {
        let helper = await ScriptedHelperHost.macOS()
        let store = store(helper)
        await store.refresh()
        #expect(store.status == .notInstalled)
        #expect(store.installAction == .install)
        #expect(!store.offersLinger)
        let listed = try #require(store.plan?.files)
        #expect(listed.contains(ScriptedHelperHost.launchAgent))
        #expect(listed.contains("\(ScriptedHelperHost.macHelperDirectory)/helper.log"))
        #expect(listed.contains("\(ScriptedHelperHost.macHelperDirectory)/installed.json"))
        #expect(listed.contains("\(ScriptedHelperHost.macHelperDirectory)/app/main.js"))
        #expect(listed.contains("/Users/me/.pi/agent/extensions/heeler-session.js"))
        #expect(!listed.contains { $0.contains("systemd") })

        let before = await helper.filePaths()
        await store.install()
        #expect(store.failure == nil)
        #expect(await helper.filePaths().subtracting(before) == Set(listed))
        #expect(store.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
        #expect(store.detail == "The Host Helper is running.")
        #expect(!store.offersLinger)
    }

    @Test func removalLeavesNothingAndSaysNothingOfLinger() async throws {
        let helper = await ScriptedHelperHost.macOS()
        let store = store(helper)
        await store.refresh()
        await store.install()
        #expect(!store.removalMessage.lowercased().contains("linger"))
        #expect(store.offersRemoval)
        await store.remove()
        #expect(store.failure == nil)
        #expect(await helper.filePaths().isEmpty)
        #expect(await !helper.agentLoaded)
        #expect(store.status == .notInstalled)
    }

    @Test func aLinuxHostsRemovalStillNamesLinger() async {
        let helper = ScriptedHelperHost()
        let store = store(helper)
        await store.refresh()
        #expect(store.removalMessage.contains("Systemd linger"))
    }

    @Test func aFailedInstallIsReadBackAndSaysWhy() async {
        let helper = await ScriptedHelperHost.macOS()
        await helper.configure { $0.bootstrapRefusal = (5, "Bootstrap failed: 5: Input/output error") }
        let store = store(helper)
        await store.refresh()
        await store.install()
        #expect(store.failure?.contains("Starting the service failed") == true)
        #expect(store.failure?.contains("more than one cause") == true)
    }

    @Test func aHostStillReadsAsCheckingUntilTheSecondRead() async throws {
        let helper = await ScriptedHelperHost.macOS()
        let plain = store(helper)
        await plain.refresh()
        await plain.install()

        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let bundle = bundle
        let store = HostHelperStore(
            connect: { core.transport() }, bundle: { bundle },
            healthGap: {
                started.continuation.yield()
                for await _ in gate.stream { return }
            })
        store.checkStarted()
        let refresh = Task { await store.refresh() }
        for await _ in started.stream { break }
        #expect(store.reading == .checking)
        gate.continuation.yield()
        await refresh.value
        #expect(store.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
    }
}

@Suite("Usage Limits through the Host Helper on macOS")
struct HostHelperKeychainWordingTests {
    /// The Helper's answer with `keychainUnavailable` where the plugin's code
    /// puts it, for the program and for each of its Accounts.
    private func helperAnswer() throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        let limits = ["state": "unavailable", "reason": "keychainUnavailable"]
        programs[0]["usageLimits"] = limits
        programs[0]["accounts"] = [[
            "id": "default", "isDefault": true, "directory": "/Users/me/.claude", "state": "ok",
            "usageLimits": limits,
        ]]
        object["programs"] = programs
        return Data("__HEELER_USAGE_BEGIN_n\n".utf8) + (try JSONSerialization.data(withJSONObject: object))
            + Data("\n__HEELER_USAGE_END_n:0\n".utf8)
    }

    @Test func theKeychainReadingNamesTheUsersOwnLogin() throws {
        let report = try AgentUsageProbe.parseHelper(stdout: try helperAnswer(), nonce: "n")
        let program = try #require(report.programs?.first)
        let message = AgentUsageLimitsView.unavailableMessage(program.usageLimits, program: "claude")
        #expect(message == "Claude Code’s Usage Limits need your own login on this Mac. "
            + "The Host Helper and SSH cannot reach its login keychain.")
        #expect(!message.contains("herdr"))
        let account = try #require(program.accounts?.first?.usageLimits)
        #expect(AgentUsageLimitsView.unavailableMessage(account, program: "claude") == message)
    }

    @Test func otherReadingsPassThrough() throws {
        let plugin = try AgentUsageLimitFixture.report(state: "unavailable", reason: "notSignedIn")
        #expect(plugin.readThroughHostHelper() == plugin)
    }

    /// The same answer through the plugin's parser, which a Herdr TUI Host reads.
    @Test func aHerdrTuiHostKeepsItsWords() throws {
        let report = try AgentUsageProbe.parse(stdout: try helperAnswer(), nonce: "n")
        let program = try #require(report.programs?.first)
        #expect(AgentUsageLimitsView.unavailableMessage(program.usageLimits, program: "claude").contains("Start herdr"))
        let account = try #require(program.accounts?.first?.usageLimits)
        #expect(AgentUsageLimitsView.unavailableMessage(account, program: "claude").contains("Start herdr"))
    }
}
