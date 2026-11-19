import Foundation
import Observation

/// One Host file open in Files. Text is read in place, a megabyte at a time;
/// anything else is copied to this device first, because the system's
/// viewers and the share sheet read local files. The copy is removed when
/// the preview closes. Either way the file comes in pieces sized to the
/// link (`HostFilePace`).
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
        /// Text on its way, once it is more than one piece.
        case reading(received: UInt64, total: UInt64)
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
    @ObservationIgnored private let pace: HostFilePace
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// The whole file on this device, once something needed it.
    @ObservationIgnored private var copy: URL?
    @ObservationIgnored private var folder: URL?
    /// A whole text file's bytes, which make its copy without a second read.
    @ObservationIgnored private var wholeText: Data?

    init(
        path: String, name: String, size: UInt64?, modified: Date?,
        files: ChatHostFiles, copies: HostFileCopies, pace: HostFilePace
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.modified = modified
        self.files = files
        self.copies = copies
        self.pace = pace
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
            let asked = ContinuousClock.now
            guard let status = try await files.status(path) else {
                phase = .failed(HostFilesFailure.missing.fileMessage)
                return
            }
            // A request with nothing to carry: what the link's delay is now.
            pace.roundTrip(took: asked.duration(to: .now))
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
            case .image:
                // Past what the image viewer takes, and not text either.
                phase = size <= Self.copyLimit ? .noPreview : .tooLarge
            case .markdown, .other:
                try await loadText(size: size)
            }
        } catch {
            fail(error)
        }
    }

    /// A file with no viewer of its own is text when its start reads as
    /// text, and otherwise something to share or save. Its first piece
    /// decides, so a file that is not text is not read on to learn so.
    private func loadText(size: UInt64) async throws {
        let window = min(size, Self.textWindow)
        let start = try await read(from: 0, count: window, size: size, while: HostFileText.looksLikeText)
        guard !Task.isCancelled else { return }
        guard HostFileText.looksLikeText(start) else {
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

    /// `count` bytes from `offset`, a piece at a time, for as long as
    /// `isWanted` takes what has come. Past the first piece the page shows
    /// how far the read is.
    private func read(
        from offset: UInt64, count: UInt64, size: UInt64,
        while isWanted: (Data) -> Bool = { _ in true }
    ) async throws -> Data {
        var data = Data()
        while UInt64(data.count) < count, data.isEmpty || isWanted(data) {
            try Task.checkCancellation()
            data.append(
                try await HostFileCopy.piece(
                    of: path, at: offset + UInt64(data.count), upTo: count - UInt64(data.count),
                    size: size, files: files, pace: pace))
            if UInt64(data.count) < count {
                phase = .reading(received: UInt64(data.count), total: count)
            }
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
                path: path, size: size, files: files, pace: pace, to: destination, progress: progress)
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

/// How much of a file one request asks the Host for.
///
/// A piece's bytes hold the Host's one connection while they cross it. The
/// terminal's output waits behind them, and a piece that needs longer than a
/// request may take never arrives at all. So a piece is what the link carries
/// in about a second, as the pieces before it measured: no less than a slow
/// link still finishes, no more than pays on a fast one. Files keeps one pace
/// while it is open, so the next file starts where the last one got to.
@MainActor
final class HostFilePace {
    static let smallestPiece = 32 << 10
    static let largestPiece = 256 << 10
    /// The first piece, before the link has carried anything.
    static let firstPiece = 64 << 10
    /// How long one piece's bytes may hold the link.
    static let linkTime: Duration = .seconds(1)
    /// A piece asks the Host four things, and one of them carries the file:
    /// its status, its open, the read and its close.
    static let requestsInPiece = 4

    private(set) var pieceBytes = HostFilePace.firstPiece
    /// What a piece costs before its bytes: its requests there and back.
    private var overhead: Duration?

    /// A request with nothing to carry took this long, as a file opened.
    /// The quickest one counts: a slower answer waited behind something else
    /// on the link. One several times slower may also mean the link has
    /// worsened since the pace was learned, so that file starts no larger
    /// than a first piece.
    func roundTrip(took elapsed: Duration) {
        let cost = elapsed * Self.requestsInPiece
        if let overhead, cost > overhead * 4 {
            pieceBytes = min(pieceBytes, Self.firstPiece)
        }
        overhead = min(overhead ?? cost, cost)
    }

    /// A piece of `bytes` arrived `elapsed` after it was asked for.
    func piece(of bytes: Int, took elapsed: Duration) {
        // No piece costs more before its bytes than a whole one took.
        if let overhead, elapsed < overhead { self.overhead = elapsed }
        // The end of a file, or a short one, says little of the link.
        guard bytes >= Self.smallestPiece else { return }
        // With no round trip measured, all of a piece's time is its bytes'.
        let overhead = self.overhead ?? .zero
        let carrying = elapsed - overhead
        // No piece is asked to be more than twice one that arrived, so a
        // wrong measure cannot ask for one that outlasts its request.
        let reachable = min(Self.largestPiece, max(pieceBytes, bytes * 2))
        // Under this the time is the estimate's own error: the link is fast.
        guard carrying > max(.milliseconds(100), overhead / 4) else {
            pieceBytes = reachable
            return
        }
        let carried = Double(bytes) * (Self.linkTime / carrying)
        let fitting = max(Self.smallestPiece, Int(min(Double(reachable), carried)))
        // One piece measures roughly, and a piece sized by one measure
        // swings past the link's speed and back. So the pace moves halfway,
        // unless the link carries under half of it: that is believed at once.
        pieceBytes = carried < Double(pieceBytes) / 2 ? fitting : (pieceBytes + fitting + 1) / 2
    }

    /// A piece outlasted its request: the next try asks for the least.
    func pieceTimedOut() {
        pieceBytes = Self.smallestPiece
    }

    /// The Host's connection is a new one, perhaps over another network, so
    /// the next piece is a first one again. The quickest round trip stays: a
    /// piece that was crossing as the connection changed then reads as slow,
    /// and on a slower network the pieces are only smaller than they could be.
    func reset() {
        pieceBytes = Self.firstPiece
    }
}

/// Reads one Host file in pieces, and copies one to this device, off the
/// main actor.
enum HostFileCopy {
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

    /// The next piece of a file from `offset`: what the pace allows, and no
    /// more than `limit`. It fails if the file's length moved under the
    /// read, because the pieces would no longer be one file.
    static func piece(
        of path: String, at offset: UInt64, upTo limit: UInt64, size: UInt64,
        files: ChatHostFiles, pace: HostFilePace
    ) async throws -> Data {
        let wanted = Int(min(UInt64(await pace.pieceBytes), limit))
        let asked = ContinuousClock.now
        let slice: RemoteFileSlice
        do {
            slice = try await files.read(RemoteFileRange(path: path, offset: offset, maxBytes: wanted))
        } catch {
            switch error {
            case TransportError.hostFileTimedOut, TransportError.timedOut: await pace.pieceTimedOut()
            default: break
            }
            throw error
        }
        let elapsed = asked.duration(to: .now)
        guard let length = slice.length else { throw Failure.missing }
        guard length == size, !slice.data.isEmpty, slice.data.count <= wanted else {
            throw Failure.changed
        }
        await pace.piece(of: slice.data.count, took: elapsed)
        return slice.data
    }

    static func run(
        path: String, size: UInt64, files: ChatHostFiles, pace: HostFilePace, to destination: URL,
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
            let data = try await piece(
                of: path, at: received, upTo: size - received, size: size, files: files, pace: pace)
            try handle.write(contentsOf: data)
            received += UInt64(data.count)
            await progress(received)
        }
        try Task.checkCancellation()
    }
}
