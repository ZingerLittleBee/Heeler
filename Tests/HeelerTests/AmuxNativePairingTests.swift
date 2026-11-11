import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Post-authentication verification uses the real framed transport. Only the
/// external SSH channel and native-helper process responses are scripted.
@Suite(.serialized) struct AmuxNativePairingTests {
    private let connector = SSHPairingConnector(nonce: { ScriptedCoreHost.nonce })

    @Test func cancelledVerificationClosesBeforeAnyRemoteProbe() async throws {
        let endpoint = try #require(PairingCodeVectorFile.amuxCode().coreEndpoint)
        let host = ScriptedCoreHost(channel: .refused)
        let verification = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await connector.verifyCoreEndpoint(endpoint, over: host)
        }
        await #expect(throws: CancellationError.self) { try await verification.value }
        #expect(await host.log == ["close"])
    }

    @Test func authenticatedSSHDoesNotAuthorizeAReplacementCore() async throws {
        let endpoint = try #require(PairingCodeVectorFile.amuxCode().coreEndpoint)
        let helper = await ScriptedHelperHost.native()
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(
                executable: endpoint.executablePath, defaultPath: endpoint.socketPath, socketFile: true),
            helper: helper, channel: .core(.init(id: "replacement")))
        await #expect(throws: PairingCeremonyError.self) {
            try await connector.verifyCoreEndpoint(endpoint, over: host)
        }
        #expect(await host.log.last == "close")
        #expect(await host.socket?.isClosed == true)
        #expect(await helper.steps.isEmpty)
        #expect(await helper.writes.isEmpty)
    }

    @Test(arguments: ["ready", "stopped", "disconnected"])
    func onlyAnIdentityCheckedLiveFollowerFinishesPairing(state: String) async throws {
        let endpoint = try #require(PairingCodeVectorFile.amuxCode().coreEndpoint)
        let helper = await ScriptedHelperHost.native()
        await helper.configure {
            $0.nativeHealth = ScriptedHelperHost.nativeHealthJSON.replacingOccurrences(of: "ready", with: state)
        }
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(
                executable: endpoint.executablePath, defaultPath: endpoint.socketPath, socketFile: true),
            helper: helper, channel: .core(.init(id: endpoint.core.id)))
        if state == "ready" {
            try await connector.verifyCoreEndpoint(endpoint, over: host)
        } else {
            await #expect(throws: PairingCeremonyError.self) {
                try await connector.verifyCoreEndpoint(endpoint, over: host)
            }
        }
        #expect(await host.log == ["locator", "open \(endpoint.socketPath)", "close"])
        #expect(await host.socket?.isClosed == true)
        #expect(await helper.steps == [.amuxNative(endpoint, status: false), .amuxNative(endpoint, status: true)])
        #expect(await helper.writes.isEmpty)
    }

    @Test(arguments: ["process-exit", "missing-capability", "wrong-core", "wrong-session", "wrong-socket", "negative-sequence", "missing-sequence", "malformed-json"])
    func nativeVerificationFailureClosesTheAuthenticatedConnection(reason: String) async throws {
        let endpoint = try #require(PairingCodeVectorFile.amuxCode().coreEndpoint)
        let helper = await ScriptedHelperHost.native()
        await helper.configure {
            switch reason {
            case "process-exit": $0.nativeExitStatus = 1
            case "missing-capability": $0.nativeIdentity = ScriptedHelperHost.nativeIdentityJSON.replacingOccurrences(of: ",\"activity-v1\"", with: "")
            case "wrong-core": $0.nativeHealth = ScriptedHelperHost.nativeHealthJSON.replacingOccurrences(of: "core-a", with: "other")
            case "wrong-session": $0.nativeHealth = ScriptedHelperHost.nativeHealthJSON.replacingOccurrences(of: "amux-release", with: "other")
            case "wrong-socket": $0.nativeHealth = ScriptedHelperHost.nativeHealthJSON.replacingOccurrences(of: "c.sock", with: "other.sock")
            case "negative-sequence": $0.nativeHealth = ScriptedHelperHost.nativeHealthJSON.replacingOccurrences(of: ":7", with: ":-1")
            case "missing-sequence": $0.nativeHealth = ScriptedHelperHost.nativeHealthJSON.replacingOccurrences(of: ",\"sequence\":7", with: "")
            default: $0.nativeHealth = "not JSON"
            }
        }
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(
                executable: endpoint.executablePath, defaultPath: endpoint.socketPath, socketFile: true),
            helper: helper, channel: .core(.init(id: endpoint.core.id)))
        do {
            try await connector.verifyCoreEndpoint(endpoint, over: host)
            Issue.record("invalid native helper must fail verification")
        } catch PairingCeremonyError.verificationFailed(let detail) {
            #expect(!detail.contains("malformedResponse("))
            #expect(!detail.contains("DecodingError"))
        }
        #expect(await host.log.last == "close")
        #expect(await host.socket?.isClosed == true)
        #expect(await helper.writes.isEmpty)
    }

    @Test(arguments: ["kind", "contract", "schemaVersion", "serverKind", "coreID", "generation", "session", "socket", "directory", "capabilities", "coreExecutable"])
    func changedOrIncompleteNativeIdentityCannotAuthorizeFileAccess(field: String) async throws {
        let endpoint = try #require(PairingCodeVectorFile.amuxCode().coreEndpoint)
        let helper = await ScriptedHelperHost.native()
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(ScriptedHelperHost.nativeIdentityJSON.utf8))
        guard case .object(var identity) = decoded else { Issue.record("expected identity object"); return }
        if ["contract", "schemaVersion", "generation"].contains(field) { identity[field] = .number(2) }
        else if field == "capabilities" { identity[field] = .array([.string("enroll-v1")]) }
        else { identity[field] = .string("different") }
        let answer = String(decoding: try JSONEncoder().encode(JSONValue.object(identity)), as: UTF8.self)
        await helper.configure { $0.nativeIdentity = answer }
        let files = HostHelperFiles(host: helper, amuxEndpoint: endpoint)
        await #expect(throws: (any Error).self) { try await files.readHostHelper() }
        await #expect(throws: (any Error).self) { try await files.readNotificationRegistration() }
        await #expect(throws: (any Error).self) { try await files.replaceNotificationConfig(Data()) }
        #expect(await helper.reads.isEmpty)
        #expect(await helper.writes.isEmpty)
    }

    @MainActor
    @Test func nativeHelperStatesRenderWithoutNodeManagementAndActionsCannotTouchStandaloneFiles() async throws {
        let endpoint = try #require(PairingCodeVectorFile.amuxCode().coreEndpoint)
        for state in ["ready", "stopped", "disconnected", "invalid"] {
            let helper = await ScriptedHelperHost.native()
            await helper.configure {
                $0.nativeHealth = ScriptedHelperHost.nativeHealthJSON.replacingOccurrences(of: "ready", with: state)
                $0.seedFile(ScriptedHelperHost.helperDirectory + "/installed.json", Data("standalone".utf8))
            }
            let host = ScriptedCoreHost(helper: helper, channel: .refused)
            let store = HostHelperStore(amuxEndpoint: endpoint, connect: { host.transport() })
            await store.refresh()
            if state == "invalid" {
                #expect(store.rowValue == "Unavailable")
                #expect(store.detail?.contains("Mobile settings in amux") == true)
                #expect(store.detail?.contains("DecodingError") == false)
            } else {
                #expect(store.rowValue == (state == "ready" ? "amux Native" : state.capitalized))
            }
            #expect(store.installAction == nil)
            #expect(!store.offersRemoval)
            #expect(!store.offersLinger)
            #expect(store.plan == nil)
            await helper.clearLog()
            await store.install()
            await store.remove()
            await store.turnOnLinger()
            #expect(await helper.steps.isEmpty)
            #expect(await helper.writes.isEmpty)
            #expect(await helper.files[ScriptedHelperHost.helperDirectory + "/installed.json"]?.contents == Data("standalone".utf8))

            let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
            let controller = UIHostingController(rootView: HostHelperSheet(store: store)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, .light))
            controller.overrideUserInterfaceStyle = .light
            let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            Attachment.record(image, named: "amux-native-helper-\(state)", as: .png)
            let directory = URL.documentsDirectory.appendingPathComponent("amux-native-pairing-renders")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(image.pngData()).write(to: directory.appendingPathComponent("helper-\(state).png"))
        }
    }
}
