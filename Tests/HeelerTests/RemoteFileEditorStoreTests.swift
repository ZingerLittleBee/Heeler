import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Remote file editor store")
struct RemoteFileEditorStoreTests {
    @Test func loadEditAndSaveReplaceTheBaseline() async throws {
        let path = "/workspace/main.swift"
        let openedAt = Date(timeIntervalSince1970: 100)
        let savedAt = Date(timeIntervalSince1970: 200)
        let original = snapshot(path: path, text: "let answer = 1\n", modified: openedAt)
        let recorder = EditorAccessRecorder(
            reads: [.success(original)],
            stats: [.success(nil)],
            writes: [.success(entry(path: path, modified: savedAt, sizeBytes: 16))])
        let store = RemoteFileEditorStore(path: path, access: access(recorder))

        await store.load()
        #expect(store.text == "let answer = 1\n")
        #expect(!store.isDirty)

        store.text = "let answer = 42\n"
        #expect(store.isDirty)
        await store.save()

        let written = await recorder.writtenData
        #expect(written == [Data("let answer = 42\n".utf8)])
        #expect(!store.isDirty)
        guard case .editing(let text, let baseline) = store.state else {
            Issue.record("Save should return to editing.")
            return
        }
        #expect(text == "let answer = 42\n")
        #expect(baseline.data == Data("let answer = 42\n".utf8))
        #expect(baseline.modified == savedAt)
    }

    @Test func overwriteResolutionWritesAfterAConflict() async throws {
        let path = "/workspace/main.swift"
        let openedAt = Date(timeIntervalSince1970: 100)
        let remoteAt = Date(timeIntervalSince1970: 200)
        let original = snapshot(path: path, text: "let name = \"old\"\n", modified: openedAt)
        let recorder = EditorAccessRecorder(
            reads: [.success(original)],
            stats: [.success(entry(path: path, modified: remoteAt))],
            writes: [.success(entry(path: path, modified: remoteAt, sizeBytes: 20))])
        let store = RemoteFileEditorStore(path: path, access: access(recorder))

        await store.load()
        store.text = "let name = \"local\"\n"
        await store.save()

        guard case .conflict(let conflict) = store.state else {
            Issue.record("Newer remote modification should require a resolution.")
            return
        }
        #expect(conflict.remote.modified == remoteAt)
        #expect(await recorder.writeCount == 0)

        await store.resolveConflict(.overwrite)
        #expect(await recorder.writtenData == [Data("let name = \"local\"\n".utf8)])
        #expect(!store.isDirty)
    }

    @Test func reloadResolutionDiscardsTheDraftAndReadsAgain() async throws {
        let path = "/workspace/main.swift"
        let openedAt = Date(timeIntervalSince1970: 100)
        let remoteAt = Date(timeIntervalSince1970: 200)
        let recorder = EditorAccessRecorder(
            reads: [
                .success(snapshot(path: path, text: "let value = 1\n", modified: openedAt)),
                .success(snapshot(path: path, text: "let value = 2\n", modified: remoteAt)),
            ],
            stats: [.success(entry(path: path, modified: remoteAt))],
            writes: [])
        let store = RemoteFileEditorStore(path: path, access: access(recorder))

        await store.load()
        store.text = "let value = 99\n"
        await store.save()
        await store.resolveConflict(.reload)

        #expect(store.text == "let value = 2\n")
        #expect(!store.isDirty)
        #expect(await recorder.readCount == 2)
        #expect(await recorder.writeCount == 0)
    }

    @Test func repeatedAppearanceLoadPreservesADirtyDraft() async throws {
        let path = "/workspace/main.swift"
        let recorder = EditorAccessRecorder(
            reads: [.success(snapshot(path: path, text: "let value = 1\n", modified: nil))],
            stats: [],
            writes: [])
        let store = RemoteFileEditorStore(path: path, access: access(recorder))

        await store.load()
        store.text = "let value = 2\n"
        await store.load()

        #expect(store.text == "let value = 2\n")
        #expect(store.isDirty)
        #expect(await recorder.readCount == 1)
    }

    @Test func binaryAndOversizedReadsUseDedicatedStates() async throws {
        let binaryPath = "/workspace/image.dat"
        let binaryRecorder = EditorAccessRecorder(
            reads: [
                .success(
                    RemoteFileSnapshot(
                        path: binaryPath,
                        data: Data([0x50, 0x4B, 0x00, 0x04]),
                        modified: nil,
                        sizeBytes: 4))
            ],
            stats: [],
            writes: [])
        let binaryStore = RemoteFileEditorStore(path: binaryPath, access: access(binaryRecorder))

        await binaryStore.load()
        guard case .binary(let notice) = binaryStore.state else {
            Issue.record("NUL data should be presented as a binary file.")
            return
        }
        #expect(notice.contains("binary"))

        let invalidUTF8Path = "/workspace/invalid.txt"
        let invalidUTF8Recorder = EditorAccessRecorder(
            reads: [
                .success(
                    RemoteFileSnapshot(
                        path: invalidUTF8Path,
                        data: Data([0xC3, 0x28]),
                        modified: nil,
                        sizeBytes: 2))
            ],
            stats: [],
            writes: [])
        let invalidUTF8Store = RemoteFileEditorStore(
            path: invalidUTF8Path,
            access: access(invalidUTF8Recorder))

        await invalidUTF8Store.load()
        guard case .binary = invalidUTF8Store.state else {
            Issue.record("Invalid UTF-8 should be presented as a binary file.")
            return
        }

        let largePath = "/workspace/large.txt"
        let largeRecorder = EditorAccessRecorder(
            reads: [
                .failure(
                    RemoteFileError.tooLarge(
                        path: largePath,
                        sizeBytes: UInt64(RemoteFileEditorStore.readLimit + 1),
                        limit: RemoteFileEditorStore.readLimit))
            ],
            stats: [],
            writes: [])
        let largeStore = RemoteFileEditorStore(path: largePath, access: access(largeRecorder))

        await largeStore.load()
        #expect(
            largeStore.state
                == .tooLarge(
                    sizeBytes: UInt64(RemoteFileEditorStore.readLimit + 1),
                    limit: RemoteFileEditorStore.readLimit))
    }

    private func access(_ recorder: EditorAccessRecorder) -> RemoteFileAccess {
        RemoteFileAccess(
            listDirectory: { _ in throw RemoteFileError.failure(message: "Unused in this test.") },
            readFile: { _, _ in try await recorder.read() },
            writeFile: { _, data in try await recorder.write(data) },
            statFile: { _ in try await recorder.stat() })
    }

    private func snapshot(path: String, text: String, modified: Date?) -> RemoteFileSnapshot {
        let data = Data(text.utf8)
        return RemoteFileSnapshot(path: path, data: data, modified: modified, sizeBytes: UInt64(data.count))
    }

    private func entry(
        path: String,
        modified: Date?,
        sizeBytes: UInt64? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: .file,
            sizeBytes: sizeBytes,
            modified: modified)
    }
}

private actor EditorAccessRecorder {
    private var reads: [Result<RemoteFileSnapshot, Error>]
    private var stats: [Result<RemoteFileEntry?, Error>]
    private var writes: [Result<RemoteFileEntry, Error>]
    private(set) var writtenData: [Data] = []
    private(set) var readCount = 0
    private(set) var writeCount = 0

    init(
        reads: [Result<RemoteFileSnapshot, Error>],
        stats: [Result<RemoteFileEntry?, Error>],
        writes: [Result<RemoteFileEntry, Error>]
    ) {
        self.reads = reads
        self.stats = stats
        self.writes = writes
    }

    func read() throws -> RemoteFileSnapshot {
        readCount += 1
        guard !reads.isEmpty else { throw RemoteFileError.failure(message: "Unexpected read.") }
        return try reads.removeFirst().get()
    }

    func stat() throws -> RemoteFileEntry? {
        guard !stats.isEmpty else { return nil }
        return try stats.removeFirst().get()
    }

    func write(_ data: Data) throws -> RemoteFileEntry {
        writeCount += 1
        writtenData.append(data)
        guard !writes.isEmpty else { throw RemoteFileError.failure(message: "Unexpected write.") }
        return try writes.removeFirst().get()
    }
}
