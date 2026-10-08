import Foundation
import Testing

@testable import Heeler

/// The files a tool call changed, as Chat lists them: Claude Code's record
/// of what a Bash command changed and an edit's patch, capped like output,
/// numbered like the terminal, and read again when a row needs more.
@Suite("Chat file changes")
struct ChatFileChangesTests {
    private static let sessionID = "5c1d8a52-0f7e-4c39-9d3b-2b8f4a7e1c60"
    private static let cwd = "/home/dev/proj"
    private static let claudePath = "/home/dev/.claude/projects/-home-dev-proj/\(sessionID).jsonl"

    private static func json(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
    }

    /// A Bash call that ran `command` in `cwd`, with `editDiff` as the
    /// changes Claude Code recorded for it.
    private static func bashTranscript(command: String, editDiff: String, isError: Bool = false) -> String {
        #"""
        {"type":"user","uuid":"p1","parentUuid":null,"cwd":"\#(cwd)","message":{"role":"user","content":"Fix it"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","cwd":"\#(cwd)","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_fix","name":"Bash","input":{"command":\#(json(command))}}]},"apiBlockIndex":0}
        {"type":"user","uuid":"r1","parentUuid":"a1","cwd":"\#(cwd)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_fix","content":\#(json(isError ? "Exit code 1" : "")),"is_error":\#(isError)}]},"toolUseResult":{"stdout":"","stderr":"","interrupted":false,"bashEditDiff":\#(editDiff)}}
        """#
    }

    /// A recorded hunk of `count` added lines, `+line 1` on.
    private static func addedHunk(_ count: Int) -> String {
        let lines = (1...count).map { json("+line \($0)") }.joined(separator: ",")
        return #"{"oldStart":0,"oldLines":0,"newStart":1,"newLines":\#(count),"lines":[\#(lines)]}"#
    }

    private static let threeFiles = #"""
        {"files":[{"filePath":"/home/dev/proj/docs/guide.md","hunks":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":3,"lines":[" # Guide","-Old line","+New line"," end"]}]},{"filePath":"/home/dev/proj/notes/new.md","hunks":[{"oldStart":0,"oldLines":0,"newStart":1,"newLines":2,"lines":["+a","+b"]}],"created":true},{"filePath":"/srv/shared/old.txt","hunks":[],"deleted":true}],"moreFiles":2,"changedFiles":[]}
        """#

    private static func row(_ jsonl: String, id: String = "tool:toolu_fix") -> ChatToolActivity? {
        guard case .tool(let row) = ClaudeSample.entry(id, in: ClaudeSample.transcript(jsonl)) else { return nil }
        return row
    }

    // MARK: Claude Code's record

    @Test func aCommandsChangesListUnderItsRowRelativeToWhereItRan() throws {
        let row = try #require(Self.row(Self.bashTranscript(command: "python3 fix.py", editDiff: Self.threeFiles)))
        let changes = try #require(row.fileChanges)

        #expect(changes.files.map { changes.displayPath(of: $0) } == ["docs/guide.md", "notes/new.md", "/srv/shared/old.txt"])
        #expect(changes.files.map(\.kind) == [.updated, .created, .deleted])
        #expect(changes.files.map(\.added) == [1, 2, 0])
        #expect(changes.files.map(\.removed) == [1, 0, 0])
        #expect(changes.files.allSatisfy { $0.isComplete })
        #expect(changes.moreFiles == 2)
        #expect(changes.soleNote == nil)
        #expect(changes.notes == ["… 2 more files changed"])
        #expect(!changes.movesWorkingTree)
        // The files carry the counts; the row has no badge of its own.
        #expect(row.diff == nil)
        #expect(!row.showsDiffAsOutput)
    }

    @Test func aCommandThatFailedListsNothing() throws {
        let row = try #require(
            Self.row(Self.bashTranscript(command: "python3 fix.py", editDiff: Self.threeFiles, isError: true)))
        #expect(row.status == .failed)
        #expect(row.fileChanges == nil)
    }

    @Test func aRecordThatSaysNothingListsNothing() throws {
        let row = try #require(Self.row(Self.bashTranscript(command: "true", editDiff: #"{"files":[],"moreFiles":0}"#)))
        #expect(row.fileChanges == nil)
    }

    @Test func filesPastTheLimitCountAsMore() throws {
        let files = (1...25).map { #"{"filePath":"/home/dev/proj/f\#($0).txt","hunks":[\#(Self.addedHunk(1))],"created":true}"# }
        let diff = #"{"files":[\#(files.joined(separator: ","))],"moreFiles":3}"#
        let changes = try #require(Self.row(Self.bashTranscript(command: "make", editDiff: diff))?.fileChanges)
        #expect(changes.files.count == ChatFileChanges.maximumFiles)
        #expect(changes.moreFiles == 3 + 25 - ChatFileChanges.maximumFiles)
    }

    @Test func anOddFieldCostsOnlyItself() throws {
        let diff = #"""
            {"files":[{"filePath":"/home/dev/proj/a.txt","hunks":"none","created":"yes"},{"filePath":42}],"moreFiles":"many","shared":true}
            """#
        let changes = try #require(Self.row(Self.bashTranscript(command: "make", editDiff: diff))?.fileChanges)
        #expect(changes.files.map(\.path) == ["/home/dev/proj/a.txt"])
        #expect(changes.files.first?.kind == .updated)
        #expect(changes.files.first?.lineCount == 0)
        #expect(changes.moreFiles == 0)
        #expect(changes.isShared)
    }

    @Test func aGitStepThatCanMoveTheTreeIsNoted() throws {
        let row = try #require(
            Self.row(Self.bashTranscript(command: "git stash && python3 fix.py && git stash pop", editDiff: Self.threeFiles)))
        let changes = try #require(row.fileChanges)
        #expect(changes.movesWorkingTree)
        #expect(
            changes.notes == [
                "… 2 more files changed",
                "A git step in this command can move the working tree, so these may be its changes, not edits.",
            ])
    }

    @Test(arguments: [
        "git checkout main",
        "sudo git reset --hard",
        "cd repo && git -C sub stash pop",
        "git -c core.editor=true rebase main",
        "(git pull)",
        "FOO=1 git clean -fd",
        "if true; then git switch -; fi",
        "git cherry-pick abc123",
        "git --no-pager stash list",
        "make || git restore .",
        "cat <<'EOF' > notes.md\ngit checkout main\nEOF\ngit revert HEAD",
        "git \\\n  checkout main",
        "git commit -m \"$(cat <<'EOF'\nDon't ask again\nEOF\n)\" && git pull --rebase",
        "gh pr create --body \"$(cat <<'EOF'\n## Summary\n- it's done\nEOF\n)\" && git checkout main",
        "cat > notes.md <<'EOF'\nThe 27\" display\nEOF\ngit checkout main",
        "echo \"x $(git stash)\"",
        "echo $((1<<4))\ngit checkout main",
        "(( n <<= 1 ))\ngit stash",
        "while (( n << 1 < 64 )); do n=$((n + 1)); done; git reset --hard",
        "echo $((cd repo) && git pull)",
        "echo $'it\\'s' && git checkout main",
        "2>/dev/null git checkout main && make",
        ">pull.log git pull",
        "function sync { git pull; }; sync",
    ])
    func aGitStepThatCanMoveTheTree(command: String) {
        #expect(ClaudeToolSummary.movesWorkingTree(command))
    }

    /// Steps Claude Code's check passes over, which Chat notes anyway.
    @Test(arguments: [
        "echo $(git merge topic)",
        "echo `git pull`",
        "time git pull",
        "{ cd repo; git pull; } > log.txt",
        "for d in a b; do git -C \"$d\" pull; done",
    ])
    func aGitStepTheTerminalPassesOver(command: String) {
        #expect(ClaudeToolSummary.movesWorkingTree(command))
    }

    @Test func aStepAfterSubstitutionsNestedPastTheLimitIsStillFound() {
        let command = String(repeating: "$((", count: 2_000) + "\ngit pull"
        #expect(ClaudeToolSummary.movesWorkingTree(command))
    }

    @Test(arguments: [
        "git status",
        "git diff --stat",
        "echo 'git checkout main'",
        "echo git checkout main",
        "grep -r \"git reset\" .",
        "cat <<'EOF' > notes.md\ngit checkout main\nEOF",
        "cat <<-EOF > notes.md\n\tgit stash\n\tEOF",
        "ls # git checkout main",
        "git -C checkout status",
        "python3 - <<'EOF'\nimport subprocess\nEOF",
        "sed -i '' 's/a/b/' x.txt 2>&1 | tail -n 1",
        "git commit -m \"$(cat <<'EOF'\ngit checkout main\nEOF\n)\"",
        "git log -- checkout",
        "echo \"\\$(git pull)\"",
    ])
    func aCommandThatLeavesTheTreeBe(command: String) {
        #expect(!ClaudeToolSummary.movesWorkingTree(command))
    }

    @Test func notesSayWhatTheTerminalSays() {
        #expect(ChatFileChanges(files: [], isSkipped: true).soleNote == "File diff skipped for this git command.")
        #expect(
            ChatFileChanges(files: [], moreFiles: 3, isUnavailable: true).soleNote
                == "File diff unavailable for this command; 3 files changed.")
        #expect(ChatFileChanges(files: [], isUnavailable: true).soleNote == "File diff unavailable for this command.")
        let shared = ChatFileChanges(files: [], moreFiles: 2, isShared: true, movesWorkingTree: true)
        #expect(shared.soleNote == ChatFileChanges.sharedNote)
        #expect(shared.notes.isEmpty)

        let file = ChatFileChange(path: "/p/a.txt", kind: .updated, added: 1, removed: 1, lineCount: 2)
        #expect(
            ChatFileChanges(files: [file], moreFiles: 1, isUnavailable: true).notes
                == ["… 1 more file changed (part of the diff is unavailable)"])
        #expect(
            ChatFileChanges(files: [], moreFiles: 2).notes
                == ["2 files changed (binary, mode only or too large to show)"])
        #expect(
            ChatFileChanges(files: [file], isShared: true, movesWorkingTree: true).notes
                == [
                    "A git step in this command can move the working tree, so these may be its changes, not edits.",
                    ChatFileChanges.sharedNote,
                ])
    }

    // MARK: Edits

    @Test func anEditsRowOpensToItsPatch() throws {
        let jsonl = #"""
            {"type":"user","uuid":"p1","parentUuid":null,"cwd":"/home/dev/proj","message":{"role":"user","content":"Rename it"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","cwd":"/home/dev/proj","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_edit","name":"Edit","input":{"file_path":"/home/dev/proj/a.swift","old_string":"old","new_string":"new"}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"r1","parentUuid":"a1","cwd":"/home/dev/proj","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_edit","content":"The file /home/dev/proj/a.swift has been updated successfully."}]},"toolUseResult":{"filePath":"/home/dev/proj/a.swift","structuredPatch":[{"oldStart":3,"oldLines":3,"newStart":3,"newLines":3,"lines":[" keep","-old","+new"," keep"]}]}}
            """#
        let row = try #require(Self.row(jsonl, id: "tool:toolu_edit"))
        #expect(row.showsDiffAsOutput)
        #expect(row.preview == nil)
        #expect(!row.previewIsIncomplete)
        #expect(row.diff == ChatDiffStats(added: 1, removed: 1))
        let changes = try #require(row.fileChanges)
        #expect(changes.files.map { changes.displayPath(of: $0) } == ["a.swift"])
        #expect(changes.files.first?.isComplete == true)
    }

    // MARK: Caps

    @Test func aRowKeepsTheTerminalsShareOfEachFile() {
        var lines = (1...100).map { "+line \($0)" }
        lines.insert("\\ No newline at end of file", at: 40)
        let hunk = ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 100, lines: lines)

        let change = ChatFileChange(path: "/p/a.txt", kind: .created, recorded: [hunk])
        #expect(change.added == 100 && change.lineCount == 100)
        #expect(change.heldLineCount == ChatFileChanges.rowLimits.lines)
        // A newline marker stays with the line before it.
        #expect(change.hunks.first?.lines.last == "\\ No newline at end of file")
        #expect(!change.isComplete)

        let read = ChatFileChanges.$limits.withValue(ChatFileChanges.expandedLimits) {
            ChatFileChange(path: "/p/a.txt", kind: .created, recorded: [hunk])
        }
        #expect(read.heldLineCount == 100)
        #expect(read.isComplete)
    }

    @Test func aLineLongerThanARowKeepsItsStart() throws {
        let long = "+" + String(repeating: "é", count: 20_000)
        let change = ChatFileChange(
            path: "/p/a.min.js", kind: .updated,
            recorded: [ChatDiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 2, lines: [long, "+next"])])
        let kept = try #require(change.hunks.first?.lines.first)
        #expect(kept.utf8.count <= ChatFileChanges.rowLimits.bytes)
        #expect(kept.utf8.count > ChatFileChanges.rowLimits.bytes - 2)
        #expect(long.hasPrefix(kept))
        #expect(change.heldLineCount == 1)
        #expect(change.isLineCut)
        #expect(!change.isComplete)
    }

    @Test func theCacheKeepsEachFilesSummaryButNotItsLines() throws {
        let hunk = ChatDiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-a", "+b"])
        let changes = ChatFileChanges(
            files: [ChatFileChange(path: "/p/a.txt", kind: .updated, recorded: [hunk])], moreFiles: 1,
            directory: "/p", isShared: true, movesWorkingTree: true)
        let tool = ChatToolActivity(kind: .command, name: "Bash", title: "fix", status: .succeeded, fileChanges: changes)

        let decoded = try JSONDecoder().decode(ChatToolActivity.self, from: JSONEncoder().encode(tool))

        var expected = changes
        expected.files[0].hunks = []
        #expect(decoded.fileChanges == expected)
        #expect(decoded.fileChanges?.files.first?.isComplete == false)
    }

    @Test func copyTakesEachFilesLineAndItsHunks() {
        let changes = ChatFileChanges(
            files: [
                ChatFileChange(
                    path: "/p/docs/a.md", kind: .updated,
                    recorded: [ChatDiffHunk(oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ["-old", "+new"])])
            ], directory: "/p")
        #expect(changes.copyText == "Updated docs/a.md (+1 -1)\n@@ -2,1 +2,1 @@\n-old\n+new")
    }

    // MARK: Drawing

    @Test func aDiffNumbersEachLineInOneGutter() {
        let file = ChatFileChange(
            path: "/p/a.txt", kind: .updated,
            recorded: [
                ChatDiffHunk(oldStart: 10, oldLines: 3, newStart: 10, newLines: 4, lines: [" a", "-b", "+B", "+C", " d"]),
                ChatDiffHunk(
                    oldStart: 30, oldLines: 2, newStart: 31, newLines: 2,
                    lines: [" x", "-y", "+Y\r", "\\ No newline at end of file"]),
            ])

        let diff = ChatFileDiff(file)

        #expect(diff.hunks.map(\.unchangedBefore) == [nil, 17])
        let lines = diff.hunks.flatMap(\.diff.lines)
        // A removed line by its old number, every other line by its new one.
        #expect(lines.map { ChatFileDiff.number(of: $0) } == [10, 11, 11, 12, 13, 31, 31, 32])
        #expect(lines.map(\.kind) == [.context, .removed, .added, .added, .context, .context, .removed, .added])
        #expect(lines.map(\.text) == ["a", "b", "B", "C", "d", "x", "y", "Y"])
        #expect(lines.map(\.missingNewline) == [false, false, false, false, false, false, false, true])
        #expect(diff.numberDigits == 2)
        #expect(diff.hiddenLines == 0)

        let start = ChatFileDiff(file.keeping(ChatToolPreview.Limits(lines: 4, bytes: 1_024)))
        #expect(start.hunks.flatMap(\.diff.lines).count == 4)
        #expect(start.hiddenLines == 4)
        #expect(start.hunks.count == 1)
    }

    @Test func aFileWithoutItsLinesShowsNoneOfThem() {
        let saved = ChatFileChange(path: "/p/a.txt", kind: .updated, added: 3, removed: 2, lineCount: 9)
        let diff = ChatFileDiff(saved)
        #expect(diff.hunks.isEmpty)
        #expect(diff.hiddenLines == 9)
    }

    /// A hunk that creates `count` lines.
    private static func created(_ count: Int) -> ChatDiffHunk {
        ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: count, lines: (1...count).map { "+line \($0)" })
    }

    @Test func aFileReadInFullOffersWhatItsRowLeavesOut() {
        let read = ChatFileChanges.$limits.withValue(ChatFileChanges.expandedLimits) {
            ChatFileChange(path: "/p/a.txt", kind: .created, recorded: [Self.created(100)])
        }
        let shown = read.keeping(ChatFileChanges.rowLimits)
        #expect(shown.heldLineCount == ChatFileChanges.rowLimits.lines)
        #expect(!shown.isLineCut)

        let footer = ChatFileDiffFooter(file: read, read: .read, missingOutputText: nil)
        #expect(footer.moreLines == "… 60 more lines")
        #expect(footer.status == nil)
        #expect(footer.action == .viewAll)

        let small = ChatFileChange(path: "/p/b.txt", kind: .created, recorded: [Self.created(2)])
        #expect(small.keeping(ChatFileChanges.rowLimits) == small)
        #expect(ChatFileDiffFooter(file: small, read: nil, missingOutputText: "Loading output…") == .empty)
    }

    @Test func aFileReadInFullOffersTheRestOfALineItsRowCut() {
        let long = "+" + String(repeating: "x", count: 40_000)
        let read = ChatFileChanges.$limits.withValue(ChatFileChanges.expandedLimits) {
            ChatFileChange(
                path: "/p/a.min.js", kind: .updated,
                recorded: [ChatDiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: [long])])
        }
        #expect(read.isComplete)
        #expect(read.keeping(ChatFileChanges.rowLimits).isLineCut)

        let footer = ChatFileDiffFooter(file: read, read: .read, missingOutputText: nil)
        #expect(footer.moreLines == nil)
        #expect(footer.action == .viewAll)
    }

    @Test func aFileWithoutAllItsLinesSaysHowReadingThemStands() {
        let row = ChatFileChange(path: "/p/a.txt", kind: .created, recorded: [Self.created(100)])
        let saved = ChatFileChange(path: "/p/b.txt", kind: .updated, added: 3, removed: 2, lineCount: 9)
        let missing = "Output is available when connected."

        let unread = ChatFileDiffFooter(file: saved, read: nil, missingOutputText: missing)
        #expect(unread.moreLines == "… 9 more lines")
        #expect(unread.status == missing)
        #expect(unread.action == nil)
        // A row with no record to read them from says nothing about reading.
        #expect(ChatFileDiffFooter(file: saved, read: nil, missingOutputText: nil).status == nil)

        let loading = ChatFileDiffFooter(file: row, read: .loading, missingOutputText: missing)
        #expect(loading.moreLines == "… 60 more lines")
        #expect(loading.status == "Loading output…")
        #expect(loading.action == nil)

        let failure = "Couldn't load output: The connection closed."
        let failed = ChatFileDiffFooter(file: row, read: .failed(failure), missingOutputText: missing)
        #expect(failed.status == failure)
        #expect(failed.action == .tryAgain)

        let gone = "Output is no longer available."
        let unavailable = ChatFileDiffFooter(file: row, read: .unavailable(gone), missingOutputText: missing)
        #expect(unavailable.status == gone)
        #expect(unavailable.action == nil)
    }

    // MARK: Reading again

    private static func claudeEngine(_ files: VirtualHostFiles) throws -> ChatConversationEngine {
        ChatConversationEngine(
            reference: ConversationReference(program: .claude, sessionID: sessionID),
            cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: .claude, conversationID: sessionID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .claude)), now: { Date() })
    }

    @Test func aReadKeepsMoreOfEachFile() async throws {
        let files = VirtualHostFiles()
        let diff = #"{"files":[{"filePath":"/home/dev/proj/big.txt","hunks":[\#(Self.addedHunk(300))],"created":true}],"moreFiles":0}"#
        await files.write(Self.bashTranscript(command: "python3 gen.py", editDiff: diff) + "\n", at: Self.claudePath)
        let engine = try Self.claudeEngine(files)
        let snapshot = await engine.open(directories: [Self.cwd], context: ChatProjectionContext(activity: .idle))
        guard case .tool(let row)? = ClaudeSample.entry("tool:toolu_fix", in: snapshot.transcript) else {
            Issue.record("The command has no row")
            return
        }
        #expect(row.fileChanges?.files.first?.heldLineCount == ChatFileChanges.rowLimits.lines)

        let read = try await engine.output(of: row).get()

        #expect(read.preview == nil)
        #expect(read.fileChanges?.files.first?.heldLineCount == 300)
        #expect(read.fileChanges?.files.first?.isComplete == true)
    }

    @Test func aReadLaidOverItsRowKeepsWhatTheRowReadFromTheCommand() {
        let id = ChatEntryID("tool:toolu_fix")
        let reference = ChatOutputReference(offset: 0, length: 10)
        let held = ChatFileChange(path: "/p/a.txt", kind: .updated, added: 1, removed: 0, lineCount: 1)
        let whole = ChatFileChange(
            path: "/p/a.txt", kind: .updated,
            recorded: [ChatDiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: ["+a"])])
        let row = ChatToolActivity(
            kind: .command, name: "Bash", title: "git pull && make", status: .succeeded,
            fileChanges: ChatFileChanges(files: [held], movesWorkingTree: true), output: reference)
        var outputs = ChatToolOutputs()
        outputs.begin(id, at: reference)
        outputs.finish(
            id, at: reference, with: .success(ChatExpandedOutput(fileChanges: ChatFileChanges(files: [whole]))))

        let marked = outputs.marking([ChatEntry(id: id, sourceOffset: 0, content: .tool(row))])

        guard case .tool(let tool)? = marked.first?.content else {
            Issue.record("The row is gone")
            return
        }
        #expect(tool.fileChanges?.files == [whole])
        #expect(tool.fileChanges?.movesWorkingTree == true)
        #expect(tool.outputRead == .read)
    }
}
