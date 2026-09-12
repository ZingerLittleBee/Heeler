import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// #280 part 2 (UI): the remote-directory browser model against a scripted
/// fake lister — home probe, enter/back, filter scoping, truncation, failure
/// presentation, cancellation, and the store pick that fills the Directory
/// field without starting.
@MainActor
@Suite("Remote directory browser")
struct RemoteDirectoryBrowserTests {
    /// Scripted fake lister: per-path listings, one scripted error, a call
    /// log, and an optional gate that holds in-flight listings open.
    @MainActor
    private final class FakeLister {
        var listings: [String: RemoteDirectoryListing] = [:]
        var error: (any Error)?
        var calls: [String] = []
        var completions = 0
        var gatedPaths: Set<String> = []
        var gateWaiters: [CheckedContinuation<Void, Never>] = []

        func list(_ path: String) async throws -> RemoteDirectoryListing {
            calls.append(path)
            if gatedPaths.contains(path) {
                await withCheckedContinuation { gateWaiters.append($0) }
            }
            completions += 1
            if let error { throw error }
            return listings[path] ?? RemoteDirectoryListing(directories: [], truncated: false)
        }

        func openGate() {
            for waiter in gateWaiters { waiter.resume() }
            gateWaiters = []
        }
    }

    private func makeBrowser(
        _ fake: FakeLister,
        home: String = "/home/you"
    ) -> RemoteDirectoryBrowser {
        RemoteDirectoryBrowser(resolveHome: { home }, list: fake.list)
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    @Test func startLoadsHomeThenEnterAndBackNavigate() async throws {
        let fake = FakeLister()
        fake.listings = [
            "/home/you": RemoteDirectoryListing(directories: ["src", "docs"], truncated: false),
            "/home/you/src": RemoteDirectoryListing(directories: ["app"], truncated: false),
        ]
        let browser = makeBrowser(fake)

        browser.start()
        try await waitUntil("home path loaded") { browser.currentPath == "/home/you" }
        #expect(browser.directories == ["src", "docs"])

        browser.enter("src")
        try await waitUntil("child path loaded") { browser.currentPath == "/home/you/src" }
        #expect(browser.directories == ["app"])

        browser.goBack()
        try await waitUntil("back returns to home") { browser.currentPath == "/home/you" }
        #expect(fake.calls == ["/home/you", "/home/you/src", "/home/you"])
    }

    @Test func filterNarrowsCurrentListingWithoutListingAgain() async throws {
        let fake = FakeLister()
        fake.listings = [
            "/home/you": RemoteDirectoryListing(directories: ["alpha", "beta"], truncated: false),
        ]
        let browser = makeBrowser(fake)
        browser.start()
        try await waitUntil("home path loaded") { browser.currentPath == "/home/you" }

        browser.filter = "alp"
        #expect(browser.visibleDirectories == ["alpha"])
        #expect(fake.calls == ["/home/you"])

        browser.filter = ""
        #expect(browser.visibleDirectories == ["alpha", "beta"])
    }

    @Test func truncationFlagTracksEachListing() async throws {
        let fake = FakeLister()
        fake.listings = [
            "/home/you": RemoteDirectoryListing(directories: ["a"], truncated: true),
            "/home/you/a": RemoteDirectoryListing(directories: [], truncated: false),
        ]
        let browser = makeBrowser(fake)
        browser.start()
        try await waitUntil("home path loaded") { browser.currentPath == "/home/you" }
        #expect(browser.truncated)

        browser.enter("a")
        try await waitUntil("child path loaded") { browser.currentPath == "/home/you/a" }
        #expect(!browser.truncated)
    }

    @Test func failedListingKeepsPriorPathAndError() async throws {
        let fake = FakeLister()
        fake.listings = [
            "/home/you": RemoteDirectoryListing(directories: ["src"], truncated: false),
        ]
        let browser = makeBrowser(fake)
        browser.start()
        try await waitUntil("home path loaded") { browser.currentPath == "/home/you" }

        let failure = TransportError.invalidDirectoryPath(path: "/home/you/missing")
        fake.error = failure
        browser.enter("missing")
        try await waitUntil("failure surfaced") { browser.errorMessage != nil }

        #expect(browser.currentPath == "/home/you")
        #expect(browser.directories == ["src"])
        #expect(browser.errorMessage == failure.presentation.message)
        #expect(!browser.isLoading)
    }

    @Test func homeProbeFailureShowsPresentationWithoutPath() async throws {
        let failure = TransportError.homeDirectoryUnresolvable(detail: "probe failed")
        let browser = RemoteDirectoryBrowser(
            resolveHome: { throw failure }, list: FakeLister().list)
        browser.start()
        try await waitUntil("home failure surfaced") { browser.errorMessage != nil }

        #expect(browser.currentPath == nil)
        #expect(browser.directories == [])
        #expect(browser.errorMessage == failure.presentation.message)
    }

    @Test func cancelDropsInFlightListing() async throws {
        let fake = FakeLister()
        fake.gatedPaths = ["/home/you"]
        let browser = makeBrowser(fake)
        browser.start()
        try await waitUntil("listing started") { !fake.calls.isEmpty }

        browser.cancel()
        fake.openGate()
        try await waitUntil("stale load settled") { fake.completions == 1 }

        #expect(!browser.isLoading)
        #expect(browser.currentPath == nil)
        #expect(browser.errorMessage == nil)
    }

    @Test func pathHelpersHandleRootAndNonAbsolutePaths() {
        #expect(RemoteDirectoryBrowser.childPath("/", name: "x") == "/x")
        #expect(RemoteDirectoryBrowser.childPath("/home/you", name: "src") == "/home/you/src")
        #expect(RemoteDirectoryBrowser.parentPath(of: "/home/you/src") == "/home/you")
        #expect(RemoteDirectoryBrowser.parentPath(of: "/") == nil)
        #expect(RemoteDirectoryBrowser.parentPath(of: "relative") == nil)
        #expect(RemoteDirectoryBrowser.parentPath(of: "") == nil)

        let browser = makeBrowser(FakeLister())
        #expect(!browser.canGoBack)
    }

    /// Counts submits, so the browse assertion can prove nothing was started.
    @MainActor
    private final class StartCounter {
        var count = 0
    }

    @Test func browsedDirectoryFillsTheFieldWithoutStarting() async {
        let starts = StartCounter()
        let store = StartAgentStore(
            hosts: [Host.fixture()], workspaces: { _ in [] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in [.claude] },
            start: { _, _, _ in
                starts.count += 1
                return Agent(.fixture(paneID: "w1:pnew", status: .working))
            },
            awaitAgentVisible: { _ in })

        store.applyBrowsedDirectory("/home/you/src/app")

        #expect(store.newWorkspaceDirectory == "/home/you/src/app")
        #expect(starts.count == 0)
    }
}
