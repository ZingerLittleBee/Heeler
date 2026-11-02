import Foundation
import Testing

@testable import Heeler

/// The finished Changes read path against the kinds of Host a user has (#395):
/// the direct and Jump Host fixtures the merge gate provisions, and, when
/// `scripts/verify-changes-linux-host.sh` runs it, a Linux Host whose accounts
/// log in through fish and through POSIX sh.
///
/// One test visits every configured Host rather than one test per Host, so the
/// merge gate proves the same test name the Linux run exercises and the full
/// lane's skip of it is accounted for.
@Suite(
    "Changes field Hosts e2e",
    .enabled(
        if: RealSSHFixture.gate(!ChangesFieldHost.configured.isEmpty),
        "requires the disposable direct and Jump Host fixtures or the Linux Host container"),
    .serialized)
struct ChangesFieldHostE2ETests {
    @Test("Changes, file patches and an untracked directory read correctly on every configured field Host")
    func everyFieldHostReadsChanges() async throws {
        if RealSSHFixture.isRequired {
            // The merge gate always provisions both of its fixture routes.
            try #require(HeelerSSHTransportBehaviorEnvironment.current != nil)
        }
        let hosts = ChangesFieldHost.configured
        try #require(!hosts.isEmpty)
        for host in hosts {
            try await ChangesFieldCheckout.verifyReads(on: host)
        }
    }
}

/// One route to a Host that Changes must read correctly.
struct ChangesFieldHost: Sendable {
    let label: String
    let settings: SSHTransportSettings

    static var configured: [ChangesFieldHost] {
        var hosts: [ChangesFieldHost] = []
        if let environment = HeelerSSHTransportBehaviorEnvironment.current {
            hosts.append(ChangesFieldHost(label: "direct", settings: environment.directSettings()))
            hosts.append(ChangesFieldHost(label: "jump", settings: environment.jumpSettings()))
        }
        if let linux = LinuxHostFixture.current {
            for account in linux.accounts {
                hosts.append(
                    ChangesFieldHost(
                        label: "linux-\(account.loginShell)",
                        settings: linux.settings(for: account)))
            }
        }
        return hosts
    }
}

/// A Checkout seeded on the Host itself, holding every shape of change the
/// research note's script was verified against: a modification, a staged
/// rename, a binary file, an untracked file and directory, and the hostile
/// names that login shells and pathspec magic mangle.
enum ChangesFieldCheckout {
    static let hostileNames = [
        "--", "-dash.txt", "sp ace.txt", "quo\"te.txt", "sq'uote.txt",
        #"two\\bs.txt"#, #"trail\"#, "bang!.txt", "$HOME.txt", "*.txt",
        "[ab].txt", "ünï.txt", "中文.txt", "line\nbreak.txt", "tab\tname.txt",
    ]

    private struct ExpectedFile: Equatable {
        let path: Data
        var originalPath: Data? = nil
        let kind: ChangedFile.Kind
        let staging: ChangedFile.Staging?
        let lineCounts: LineCounts?
    }

    private static var expectedFiles: [ExpectedFile] {
        var files = hostileNames.map {
            ExpectedFile(
                path: Data($0.utf8), kind: .modified, staging: .unstaged,
                lineCounts: .lines(added: 1, removed: 0))
        }
        files += [
            ExpectedFile(
                path: Data("tracked.txt".utf8), kind: .modified, staging: .unstaged,
                lineCounts: .lines(added: 2, removed: 1)),
            ExpectedFile(
                path: Data("new-name.txt".utf8), originalPath: Data("old-name.txt".utf8),
                kind: .renamed, staging: .staged, lineCounts: .lines(added: 0, removed: 0)),
            ExpectedFile(
                path: Data("image.bin".utf8), kind: .modified, staging: .unstaged,
                lineCounts: .binary),
            ExpectedFile(
                path: Data("untracked.txt".utf8), kind: .untracked, staging: nil,
                lineCounts: nil),
            ExpectedFile(
                path: Data("newdir/".utf8), kind: .untracked, staging: nil, lineCounts: nil),
        ]
        // Conflicts would come first; otherwise the model orders by raw bytes.
        return files.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    static func verifyReads(on host: ChangesFieldHost) async throws {
        let transport = try await HeelerSSHTransport.connect(settings: host.settings)
        defer { Task { try? await transport.close() } }
        // `$HOME` resolves on the Host, so one script serves every account.
        let root = "\"$HOME\"/changes-field-" + UUID().uuidString
        let cleanup = Data("{ rm -rf \(root); } </dev/null\n".utf8)
        do {
            try await verifyReads(on: host, transport: transport, root: root)
        } catch {
            _ = try? await transport.runGitScript(cleanup)
            throw error
        }
        let cleaned = try await transport.runGitScript(cleanup)
        #expect(cleaned.exitStatus == 0, "\(host.label): cleanup failed")
    }

    private static func verifyReads(
        on host: ChangesFieldHost, transport: HeelerSSHTransport, root: String
    ) async throws {
        let seeded = try await transport.runGitScript(seedScript(root: root))
        try #require(
            seeded.exitStatus == 0,
            "\(host.label): seed failed: \(String(decoding: seeded.stderr, as: UTF8.self))")
        let seedValues = markedValues(seeded.stdout)
        let topLevel = try #require(seedValues["TOP"]?.first, "\(host.label): no top level")
        let indexBefore = try #require(seedValues["INDEX"]?.first, "\(host.label): no index")

        let reader: any Transport = transport
        let (read, changesDuration) = try await timed {
            try await reader.readChanges(ChangesReadRequest(directory: topLevel + "/sub"))
        }

        let changes = read.changes
        #expect(changes.checkout.topLevel == Data(topLevel.utf8), "\(host.label)")
        #expect(!changes.checkout.isLinkedWorktree, "\(host.label)")
        #expect(read.directoryPrefix == Data("sub/".utf8), "\(host.label)")
        #expect(changes.head.branch == .named("main"), "\(host.label)")
        #expect(changes.head.commit?.count == 40, "\(host.label)")
        #expect(changes.head.latestCommit?.subject == "Seed the field Checkout", "\(host.label)")
        #expect(!changes.isStatusTruncated && !changes.isMetadataTruncated, "\(host.label)")
        let files = changes.files.map {
            ExpectedFile(
                path: $0.path, originalPath: $0.originalPath, kind: $0.kind,
                staging: $0.staging, lineCounts: $0.lineCounts)
        }
        #expect(files == expectedFiles, "\(host.label): \(changes.files.map(\.accessibilityLabel))")
        #expect(changes.totals.trackedFiles == hostileNames.count + 3, "\(host.label)")
        #expect(changes.totals.untrackedItems == 2, "\(host.label)")
        #expect(changes.totals.added == hostileNames.count + 2, "\(host.label)")
        #expect(changes.totals.removed == 1, "\(host.label)")

        var patchDurations: [Duration] = []
        for file in changes.files where !file.isUntrackedDirectory {
            let request = try #require(FilePatchRequest(file: file, checkout: changes.checkout))
            let (patch, elapsed) = try await timed { try await reader.readFilePatch(request) }
            patchDurations.append(elapsed)
            expectPatch(patch, for: file, host: host)
        }

        let directory = try #require(changes.files.first { $0.isUntrackedDirectory })
        let (listing, listingDuration) = try await timed {
            try await reader.listUntrackedDirectory(
                UntrackedDirectoryRequest(
                    topLevel: changes.checkout.topLevel, directory: directory.path))
        }
        #expect(
            listing.entries.map { String(decoding: $0.path, as: UTF8.self) }
                == ["newdir/a.txt", "newdir/deep/b.txt", "newdir/sp ace.txt"],
            "\(host.label)")
        #expect(listing.total == 3 && !listing.isTruncated, "\(host.label)")
        #expect(!listing.isSeparateRepository && listing.limitNotice == nil, "\(host.label)")
        // A file found only by expanding the directory reads like any other.
        let nested = try #require(listing.entries.first { $0.path == Data("newdir/sp ace.txt".utf8) })
        let nestedRequest = try #require(FilePatchRequest(file: nested, checkout: changes.checkout))
        let nestedPatch = try await reader.readFilePatch(nestedRequest)
        #expect(
            nestedPatch.files.flatMap(\.hunks).flatMap(\.lines).map(\.text) == ["s"],
            "\(host.label)")

        // Nothing above touched the Checkout: same index inode and bytes, no
        // index write after the seed finished, and neither trap fired.
        let after = try await transport.runGitScript(afterScript(root: root))
        let afterValues = markedValues(after.stdout)
        #expect(afterValues["INDEX"] == [indexBefore], "\(host.label)")
        #expect(afterValues["REWRITTEN"] == nil, "\(host.label)")
        #expect(afterValues["TRAP"] == nil, "\(host.label)")

        // The traps were armed: plain git on this Host fires both.
        let control = try await transport.runGitScript(controlScript(root: root))
        #expect(
            markedValues(control.stdout)["TRAP"] == ["fsmonitor-ran", "post-index-change-ran"],
            "\(host.label)")

        print(
            "[changes-field] host=\(host.label) files=\(changes.files.count)"
                + " changes=\(milliseconds(changesDuration))"
                + " patches=\(patchDurations.count) \(spread(patchDurations))"
                + " listing=\(milliseconds(listingDuration))")
    }

    private static func expectPatch(_ patch: FilePatch, for file: ChangedFile, host: ChangesFieldHost) {
        let name = String(decoding: file.path, as: UTF8.self)
        let label = "\(host.label): \(file.displayPath)"
        #expect(!patch.isTruncated, "\(label)")
        #expect(patch.files.count == 1, "\(label): \(patch.files.map(\.newPath))")
        guard let diff = patch.files.first else { return }
        let lines = diff.hunks.flatMap(\.lines)
        switch file.kind {
        case .renamed:
            #expect(diff.oldPath == "old-name.txt" && diff.newPath == name, "\(label)")
            #expect(diff.hunks.isEmpty, "\(label)")
        case .untracked:
            #expect(diff.oldPath == nil && diff.newPath == name, "\(label)")
            #expect(lines.map(\.text) == ["new", "file"], "\(label)")
            #expect(lines.allSatisfy { $0.kind == .added }, "\(label)")
        case .modified where file.lineCounts == .binary:
            #expect(diff.isBinary && diff.newPath == name, "\(label)")
        case .modified where name == "tracked.txt":
            #expect(lines.map(\.text) == ["one", "two", "TWO", "three", "four"], "\(label)")
            #expect(lines.map(\.kind) == [.context, .removed, .added, .context, .added], "\(label)")
        default:
            // Every hostile name reads its own patch and nothing else: no
            // glob, pathspec magic or shell quoting widened or broke it.
            #expect(diff.oldPath == name && diff.newPath == name, "\(label)")
            #expect(lines.map(\.text) == ["hostile", "edited"], "\(label)")
            #expect(lines.map(\.kind) == [.context, .added], "\(label)")
        }
    }

    // MARK: Host scripts

    /// POSIX sh, sent on stdin like every Changes script, so the login shell
    /// never parses a hostile name. Only fixed markers are printed, because a
    /// chatty login shell writes its own lines around them.
    private static func seedScript(root: String) -> Data {
        var hostileWrites = Data()
        var hostileEdits = Data()
        for name in hostileNames {
            let quoted = GitProbe.singleQuoted(Data(name.utf8))
            hostileWrites.append(Data("printf 'hostile\\n' > ".utf8) + quoted + Data("\n".utf8))
            hostileEdits.append(Data("printf 'edited\\n' >> ".utf8) + quoted + Data("\n".utf8))
        }
        var script = Data(
            """
            {
            set -e
            r=\(root)
            mkdir -p "$r/repo/sub" "$r/repo/newdir/deep"
            cd "$r/repo"
            git init -q .
            git symbolic-ref HEAD refs/heads/main
            printf 'one\\ntwo\\nthree\\n' > tracked.txt
            printf 'rename me\\nline 2\\nline 3\\nline 4\\nline 5\\n' > old-name.txt
            printf '\\000\\001\\002binary\\000' > image.bin
            printf 'nested\\n' > sub/nested.txt

            """.utf8)
        script.append(hostileWrites)
        script.append(Data(
            """
            git add -A
            git -c user.name=Heeler -c user.email=fixture@heeler.invalid commit -q -m 'Seed the field Checkout'
            printf 'one\\nTWO\\nthree\\nfour\\n' > tracked.txt
            git mv old-name.txt new-name.txt
            printf '\\000\\003\\004binary\\000' > image.bin

            """.utf8))
        script.append(hostileEdits)
        script.append(Data(
            """
            printf 'new\\nfile\\n' > untracked.txt
            printf 'a\\n' > newdir/a.txt
            printf 'b\\n' > newdir/deep/b.txt
            printf 's\\n' > 'newdir/sp ace.txt'
            touch -t 203001010000 sub/nested.txt
            printf '#!/bin/sh\\n: > "%s/fsmonitor-ran"\\n' "$r" > "$r/fsmonitor.sh"
            mkdir -p .git/hooks
            printf '#!/bin/sh\\n: > "%s/post-index-change-ran"\\n' "$r" > .git/hooks/post-index-change
            chmod +x "$r/fsmonitor.sh" .git/hooks/post-index-change
            git config core.fsmonitor "$r/fsmonitor.sh"
            : > "$r/index-stamp"
            printf '__FIELD_TOP__=%s\\n' "$(pwd -P)"
            \(indexFingerprint)
            } </dev/null

            """.utf8))
        return script
    }

    private static func afterScript(root: String) -> Data {
        Data(
            """
            {
            r=\(root)
            cd "$r/repo"
            \(indexFingerprint)
            find .git/index -newer "$r/index-stamp" -exec printf '__FIELD_REWRITTEN__=%s\\n' {} \\;
            \(trapReport)
            } </dev/null

            """.utf8)
    }

    private static func controlScript(root: String) -> Data {
        Data(
            """
            {
            r=\(root)
            cd "$r/repo"
            git status --porcelain >/dev/null 2>&1
            \(trapReport)
            } </dev/null

            """.utf8)
    }

    /// Portable across BSD and GNU userlands, unlike `stat`.
    private static let indexFingerprint = """
        printf '__FIELD_INDEX__=%s %s\\n' "$(ls -di .git/index | awk '{print $1}')" "$(cksum < .git/index)"
        """

    private static let trapReport = """
        for m in fsmonitor-ran post-index-change-ran; do
          if [ -e "$r/$m" ]; then printf '__FIELD_TRAP__=%s\\n' "$m"; fi
        done
        """

    /// `__FIELD_<KEY>__=<value>` lines, in order, ignoring everything else.
    private static func markedValues(_ output: Data) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            guard line.hasPrefix("__FIELD_"), let end = line.range(of: "__=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 8)..<end.lowerBound])
            values[key, default: []].append(String(line[end.upperBound...]))
        }
        return values
    }

    // MARK: Measurement

    /// Wall-clock time of one call, from the caller's side of the Transport.
    static func timed<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> (Value, Duration) {
        let started = ContinuousClock.now
        let value = try await operation()
        return (value, started.duration(to: .now))
    }

    static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
        return String(format: "%.0fms", value)
    }

    /// `min=… median=… max=…` for the measurement log.
    static func spread(_ durations: [Duration]) -> String {
        let sorted = durations.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "min=- median=- max=-" }
        return "min=\(milliseconds(first)) median=\(milliseconds(sorted[sorted.count / 2]))"
            + " max=\(milliseconds(last))"
    }
}
