import Foundation
import Observation

/// One Host file open in Files. Text is read in place, a megabyte at a time;
/// anything else is copied to this device first, because the system's
/// viewers and the share sheet read local files. The copy is removed when
/// the preview closes.
@MainActor
@Observable
final class HostFilePreview: Identifiable {
    /// The largest file Files copies to this device, as an upload's is.
    static let copyLimit: UInt64 = 64 << 20
    /// How much text one read shows.
    static let textWindow: UInt64 = 1 << 20
    /// Markdown past this size is shown as its source: laying it out all at
    /// once would stall the page.
    static let renderedMarkdownLimit = 256 << 10

    enum TextPortion: Equatable, Sendable {
        case whole
        case start
        case end
    }

    struct TextDocument: Equatable, Sendable {
        let text: String
        let portion: TextPortion
        /// Markdown that fits, laid out; nil for anything else.
        let markdown: [ChatMarkdownBlock]?
    }

    enum Phase: Equatable {
        case loading
        case copying(received: UInt64, total: UInt64)
        case text(TextDocument)
        case image(URL)
        case media(URL)
        case document(URL)
        /// Not something Files shows; it can still be shared or saved.
        case noPreview
        case tooLarge
        case failed(String)
    }

    /// What a finished copy is for.
    enum Export: Equatable, Sendable {
        case share
        case save
    }

    struct PresentedExport: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let export: Export
    }

    let path: String
    let name: String
    let kind: HostFileKind
    private(set) var size: UInt64?
    private(set) var modified: Date?
    private(set) var phase = Phase.loading
    /// A copy being made for Share or Save while the page shows something
    /// else; nil when none is.
    private(set) var exportProgress: (received: UInt64, total: UInt64)?
    var presentedExport: PresentedExport?
    var exportFailure: String?
    /// Markdown shows laid out until its source is asked for.
    var showsMarkdownSource = false

    @ObservationIgnored private let files: ChatHostFiles
    @ObservationIgnored private let copies: HostFileCopies
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// The whole file on this device, once something needed it.
    @ObservationIgnored private var copy: URL?
    @ObservationIgnored private var folder: URL?
    /// A whole text file's bytes, which make its copy without a second read.
    @ObservationIgnored private var wholeText: Data?

    init(
        path: String, name: String, size: UInt64?, modified: Date?,
        files: ChatHostFiles, copies: HostFileCopies
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.modified = modified
        self.files = files
        self.copies = copies
        kind = HostFileKind(name: name)
    }

    var detail: String {
        HostFileFormat.detail(size: size, modified: modified)
    }

    /// Whether Share and Save have a file they may copy.
    var canExport: Bool {
        guard let size else { return false }
        return size <= Self.copyLimit
    }

    var isCopying: Bool {
        if case .copying = phase { return true }
        return false
    }

    /// The page showed, or Try Again was tapped.
    func open() {
        task?.cancel()
        phase = .loading
        task = Task { [weak self] in await self?.load() }
    }

    /// Cancel on the copying page: back to the folder is the caller's.
    func cancel() {
        task?.cancel()
        task = nil
    }

    func showText(_ portion: TextPortion) {
        guard let size, portion != .whole else { return }
        task?.cancel()
        phase = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.phase = .text(try await self.readText(portion, size: size))
            } catch {
                self.fail(error)
            }
        }
    }

    func export(_ export: Export) {
        guard canExport, exportTask == nil, let size else { return }
        if let copy {
            presentedExport = PresentedExport(url: copy, export: export)
            return
        }
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.exportTask = nil
                self.exportProgress = nil
            }
            do {
                let url: URL
                if let wholeText = self.wholeText {
                    url = try self.write(wholeText)
                } else {
                    self.exportProgress = (0, size)
                    url = try await self.copyFile(size: size) { [weak self] received in
                        self?.exportProgress = (received, size)
                    }
                }
                guard !Task.isCancelled else { return }
                self.presentedExport = PresentedExport(url: url, export: export)
            } catch {
                guard !Task.isCancelled, !HostFilesFailure.isCancellation(error) else { return }
                self.exportFailure = Self.message(for: error)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// The preview closed: nothing it read stays on this device.
    func discard() {
        task?.cancel()
        exportTask?.cancel()
        copy = nil
        wholeText = nil
        if let folder {
            self.folder = nil
            Task.detached { try? FileManager.default.removeItem(at: folder) }
        }
    }

    // MARK: Reading

    private func load() async {
        do {
            guard RemoteFilePath.isAcceptable(path) else {
                phase = .failed(String(localized: "Files can't open this path."))
                return
            }
            guard let status = try await files.status(path) else {
                phase = .failed(HostFilesFailure.missing.fileMessage)
                return
            }
            guard !Task.isCancelled else { return }
            guard status.kind == .regular, let size = status.size else {
                phase = .failed(String(localized: "This is not a file Files can open."))
                return
            }
            self.size = size
            modified = status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? modified
            if size == 0, kind != .markdown, kind != .other {
                // Nothing for a viewer to open.
                phase = .noPreview
                return
            }
            switch kind {
            case .image where size <= UInt64(ChatImagePreviewReader.maximumBytes):
                phase = .image(try await copyForViewing(size: size))
            case .video, .audio:
                phase = size <= Self.copyLimit ? .media(try await copyForViewing(size: size)) : .tooLarge
            case .document:
                phase = size <= Self.copyLimit ? .document(try await copyForViewing(size: size)) : .tooLarge
            case .markdown, .other, .image:
                try await loadText(size: size)
            }
        } catch {
            fail(error)
        }
    }

    /// A file with no viewer of its own is text when its start reads as
    /// text, and otherwise something to share or save.
    private func loadText(size: UInt64) async throws {
        let window = min(size, Self.textWindow)
        let start = try await read(from: 0, count: window, size: size)
        guard !Task.isCancelled else { return }
        guard kind != .image, HostFileText.looksLikeText(start) else {
            phase = size <= Self.copyLimit ? .noPreview : .tooLarge
            return
        }
        let isWhole = window == size
        if isWhole { wholeText = start }
        phase = .text(await Self.document(from: start, portion: isWhole ? .whole : .start, kind: kind))
    }

    private func readText(_ portion: TextPortion, size: UInt64) async throws -> TextDocument {
        let window = min(size, Self.textWindow)
        let offset = portion == .end ? size - window : 0
        let data = try await read(from: offset, count: window, size: size)
        try Task.checkCancellation()
        return await Self.document(from: data, portion: portion, kind: kind)
    }

    private static func document(
        from data: Data, portion: TextPortion, kind: HostFileKind
    ) async -> TextDocument {
        let markdownLimit = renderedMarkdownLimit
        // Decoding and Markdown's parse both stay off the main actor.
        return await Task.detached {
            let text = HostFileText.decode(
                data, cutAtStart: portion == .end, cutAtEnd: portion == .start)
            let rendersMarkdown = kind == .markdown && portion == .whole
                && data.count <= markdownLimit
            return TextDocument(
                text: text, portion: portion,
                markdown: rendersMarkdown ? ChatMarkdown.blocks(from: text) : nil)
        }.value
    }

    /// `count` bytes from `offset`, which fails if the file's length moves
    /// under the read: the pieces would no longer be one file.
    private func read(from offset: UInt64, count: UInt64, size: UInt64) async throws -> Data {
        var data = Data()
        while UInt64(data.count) < count {
            try Task.checkCancellation()
            let wanted = Int(min(UInt64(HostFileCopy.chunkBytes), count - UInt64(data.count)))
            let slice = try await files.read(
                RemoteFileRange(path: path, offset: offset + UInt64(data.count), maxBytes: wanted))
            guard let length = slice.length else { throw HostFileCopy.Failure.missing }
            guard length == size, !slice.data.isEmpty, slice.data.count <= wanted else {
                throw HostFileCopy.Failure.changed
            }
            data.append(slice.data)
        }
        return data
    }

    // MARK: Copying

    private func copyForViewing(size: UInt64) async throws -> URL {
        phase = .copying(received: 0, total: size)
        return try await copyFile(size: size) { [weak self] received in
            guard let self, self.isCopying else { return }
            self.phase = .copying(received: received, total: size)
        }
    }

    private func copyFile(
        size: UInt64, progress: @escaping @MainActor @Sendable (UInt64) -> Void
    ) async throws -> URL {
        if let copy { return copy }
        let destination = try destination()
        do {
            try await HostFileCopy.run(
                path: path, size: size, files: files, to: destination, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        copy = destination
        return destination
    }

    private func write(_ data: Data) throws -> URL {
        if let copy { return copy }
        let destination = try destination()
        try data.write(to: destination)
        copy = destination
        return destination
    }

    /// The copy keeps the file's name, which is what a share shows.
    private func destination() throws -> URL {
        let folder = try self.folder ?? copies.makeFolder()
        self.folder = folder
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    private func fail(_ error: any Error) {
        guard !Task.isCancelled, !HostFilesFailure.isCancellation(error) else { return }
        phase = .failed(Self.message(for: error))
    }

    private static func message(for error: any Error) -> String {
        if let failure = error as? HostFileCopy.Failure { return failure.message }
        return HostFilesFailure(error).fileMessage
    }
}

/// Copies one Host file to this device in pieces, off the main actor.
enum HostFileCopy {
    /// One read's size, as Chat's image reads use.
    static let chunkBytes = 256 << 10

    enum Failure: Error, Equatable {
        case missing
        case changed

        var message: String {
            switch self {
            case .missing: HostFilesFailure.missing.fileMessage
            case .changed: String(localized: "The file changed on the Host while it was being read. Try again.")
            }
        }
    }

    static func run(
        path: String, size: UInt64, files: ChatHostFiles, to destination: URL,
        progress: @escaping @MainActor @Sendable (UInt64) -> Void
    ) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var received: UInt64 = 0
        while received < size {
            try Task.checkCancellation()
            let wanted = Int(min(UInt64(chunkBytes), size - received))
            let slice = try await files.read(RemoteFileRange(path: path, offset: received, maxBytes: wanted))
            guard let length = slice.length else { throw Failure.missing }
            guard length == size, !slice.data.isEmpty, slice.data.count <= wanted else {
                throw Failure.changed
            }
            try handle.write(contentsOf: slice.data)
            received += UInt64(slice.data.count)
            await progress(received)
        }
        try Task.checkCancellation()
    }
}
