import Foundation

@testable import Heeler

/// A Host's text files for a harness edit: reads and the compare-and-swap replace
/// over a dictionary, recording every replace that wrote. Everything else keeps
/// the seam's refusal.
actor InMemoryHostFiles: HostServices {
    struct Write: Equatable {
        let path: String
        let contents: Data?
    }

    private(set) var files: [String: Data]
    private(set) var writes: [Write] = []
    private(set) var replaceCalls = 0
    private var beforeNextReplace: (@Sendable (InMemoryHostFiles) async -> Void)?
    private var failure: (any Error)?
    private var lostReplaceAnswer: (any Error)?
    private var losesConnectionWithAnswer = false
    private var replaceFailure: (any Error)?
    private let home: String

    init(files: [String: Data] = [:], home: String = "/home/dev") {
        self.files = files
        self.home = home
    }

    func set(_ path: String, _ contents: Data?) {
        files[path] = contents
    }

    /// Runs once, after a read and before the next replace compares.
    func onNextReplace(_ change: @escaping @Sendable (InMemoryHostFiles) async -> Void) {
        beforeNextReplace = change
    }

    func setFailure(_ failure: (any Error)?) {
        self.failure = failure
    }

    /// The next replace takes effect and its answer is lost, with this as the
    /// error. With `andConnection`, everything after it fails the same way until
    /// `setFailure(nil)`.
    func loseNextReplaceAnswer(_ failure: any Error, andConnection: Bool = false) {
        lostReplaceAnswer = failure
        losesConnectionWithAnswer = andConnection
    }

    /// Every replace fails with this before it writes, while reads still work.
    func setReplaceFailure(_ failure: (any Error)?) {
        replaceFailure = failure
    }

    func hostHomeDirectory() async throws -> String { home }

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        if let failure { throw failure }
        guard let file = files[range.path] else { return RemoteFileSlice(data: Data(), length: nil) }
        let start = min(Int(range.offset), file.count)
        return RemoteFileSlice(
            data: file[start..<min(start + range.maxBytes, file.count)], length: UInt64(file.count))
    }

    func replaceHostTextFile(path: String, expected: Data?, contents: Data?) async throws {
        replaceCalls += 1
        if let change = beforeNextReplace {
            beforeNextReplace = nil
            await change(self)
        }
        if let failure { throw failure }
        if let replaceFailure { throw replaceFailure }
        guard files[path] == expected else { throw HostTextFileError.changedSinceRead }
        files[path] = contents
        writes.append(Write(path: path, contents: contents))
        if let lost = lostReplaceAnswer {
            lostReplaceAnswer = nil
            if losesConnectionWithAnswer { failure = lost }
            throw lost
        }
    }
}
