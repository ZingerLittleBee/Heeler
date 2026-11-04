import Foundation
import UIKit

/// The pictures image rows show under their titles (ADR 0024). A file is
/// read only while a row shows it, one file at a time over Chat's own Host
/// connection, decoded small and kept in memory only. A file larger than
/// ``automaticBytes`` waits for a tap.
@MainActor
@Observable
final class ChatImageThumbnails {
    enum Phase: Equatable {
        /// Waiting its turn, or reading.
        case loading
        case loaded(UIImage)
        /// Too large to read by itself; a tap reads it.
        case large(bytes: UInt64)
        /// The Host is not connected, and no copy is kept.
        case offline
        /// Why it could not show; a tap tries again.
        case failed(String)
    }

    /// How thumbnails reach the Host's files.
    struct Source: Sendable {
        /// The file's status, checked before any of it is read.
        var stamp: @Sendable (String) async throws -> ChatImageStamp
        /// The file the stamp describes.
        var read: @Sendable (String, ChatImageStamp) async throws -> Data

        init(
            stamp: @escaping @Sendable (String) async throws -> ChatImageStamp,
            read: @escaping @Sendable (String, ChatImageStamp) async throws -> Data
        ) {
            self.stamp = stamp
            self.read = read
        }

        init(files: ChatHostFiles) {
            self.init(
                stamp: { try await ChatImagePreviewReader.stamp(path: $0, files: files) },
                read: { try await ChatImagePreviewReader.read(path: $0, stamp: $1, files: files) })
        }
    }

    /// Larger files wait for a tap: screenshots are rarely this big, and
    /// the phone may be on a metered connection.
    nonisolated static let automaticBytes: UInt64 = 8 << 20
    /// The long edge a thumbnail decodes to: its height on a 3x screen, or
    /// a row's width, with room to spare.
    nonisolated static let maximumPixelSize = 1_024

    private var phases: [String: Phase] = [:]
    @ObservationIgnored private let source: Source
    @ObservationIgnored private let cache: ChatImageThumbnailCache
    /// Keys this store's pictures in the shared cache.
    @ObservationIgnored private let scope = UUID()
    /// How many rows show each path right now.
    @ObservationIgnored private var shown: [String: Int] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var current: Run?
    @ObservationIgnored private var runs = 0
    /// What each path's file was when last read, which finds its kept copy.
    @ObservationIgnored private var stamps: [String: ChatImageStamp] = [:]
    /// Paths a tap asked to read whatever their size.
    @ObservationIgnored private var readsWhole: Set<String> = []
    @ObservationIgnored private var isHostConnected = true

    private struct Run {
        let path: String
        let id: Int
        let task: Task<Void, Never>
    }

    init(source: Source, cache: ChatImageThumbnailCache = .shared) {
        self.source = source
        self.cache = cache
    }

    func phase(of path: String) -> Phase {
        phases[path] ?? .loading
    }

    /// The picture a row shows for `path`, if one does.
    func image(of path: String) -> UIImage? {
        if case .loaded(let image)? = phases[path] { image } else { nil }
    }

    /// A row showing `path` came on screen.
    func appear(_ path: String) {
        shown[path, default: 0] += 1
        guard shown[path] == 1 else { return }
        // A kept copy shows at once. The file is checked again all the same:
        // an Agent often writes its screenshots to one path.
        if let kept = kept(path) { phases[path] = .loaded(kept) }
        enqueue(path)
    }

    /// A row showing `path` left the screen.
    func disappear(_ path: String) {
        guard let count = shown[path] else { return }
        guard count == 1 else {
            shown[path] = count - 1
            return
        }
        shown[path] = nil
        queue.removeAll { $0 == path }
        if current?.path == path {
            current?.task.cancel()
            current = nil
            startNext()
        }
        // Only pictures on screen are held here; the cache keeps a copy.
        phases[path] = nil
    }

    /// A tap on a thumbnail that could not show: tries again, reading the
    /// file whatever its size.
    func load(_ path: String) {
        guard shown[path] != nil else { return }
        readsWhole.insert(path)
        enqueue(path)
    }

    /// What the Console says of the Host's connection. Thumbnails waiting
    /// for it load once it connects.
    func hostConnectionChanged(_ isConnected: Bool) {
        guard isConnected != isHostConnected else { return }
        isHostConnected = isConnected
        guard isConnected else { return }
        for path in shown.keys where phases[path] == .offline {
            enqueue(path)
        }
    }

    /// Resolves once no read is queued or running, for tests.
    func settled() async {
        while let run = current {
            await run.task.value
        }
    }

    // MARK: Reading

    private func kept(_ path: String) -> UIImage? {
        stamps[path].flatMap { cache.image(for: .init(scope: scope, path: path, stamp: $0)) }
    }

    private func enqueue(_ path: String) {
        guard current?.path != path, !queue.contains(path) else { return }
        guard isHostConnected else {
            if kept(path) == nil { phases[path] = .offline }
            return
        }
        // A kept copy stays up while the file is checked.
        if case .loaded? = phases[path] {} else { phases[path] = .loading }
        queue.append(path)
        startNext()
    }

    private func startNext() {
        guard current == nil else { return }
        while !queue.isEmpty {
            let path = queue.removeFirst()
            guard shown[path] != nil else { continue }
            runs += 1
            let id = runs
            let request = Request(path: path, readsWhole: readsWhole.contains(path), scope: scope)
            let source = source
            let cache = cache
            let task = Task { [weak self] in
                let outcome = await Self.read(request, source: source, cache: cache)
                self?.finish(id, outcome)
            }
            current = Run(path: path, id: id, task: task)
            return
        }
    }

    private func finish(_ id: Int, _ outcome: Outcome) {
        // A read cancelled when its row left has been replaced already.
        guard let run = current, run.id == id else { return }
        current = nil
        defer { startNext() }
        let path = run.path
        guard shown[path] != nil else { return }
        switch outcome {
        case .image(let image, let stamp):
            stamps[path] = stamp
            phases[path] = .loaded(image)
        case .large(let bytes):
            phases[path] = .large(bytes: bytes)
        case .failed(let message, let reachedHost):
            if !reachedHost, let kept = kept(path) {
                phases[path] = .loaded(kept)
            } else if !reachedHost, !isHostConnected {
                phases[path] = .offline
            } else {
                phases[path] = .failed(message)
            }
        }
    }

    private struct Request: Sendable {
        let path: String
        let readsWhole: Bool
        let scope: UUID
    }

    private enum Outcome: Sendable {
        case image(UIImage, ChatImageStamp)
        case large(UInt64)
        /// `reachedHost` when the Host answered and the file is the cause.
        case failed(String, reachedHost: Bool)
    }

    private nonisolated static func read(
        _ request: Request, source: Source, cache: ChatImageThumbnailCache
    ) async -> Outcome {
        do {
            let stamp = try await source.stamp(request.path)
            let key = ChatImageThumbnailCache.Key(scope: request.scope, path: request.path, stamp: stamp)
            if let kept = cache.image(for: key) { return .image(kept, stamp) }
            guard request.readsWhole || stamp.size <= automaticBytes else { return .large(stamp.size) }
            let data = try await source.read(request.path, stamp)
            let decoded = try await ChatImagePreviewDecoder.shared.decode(data, maximumPixelSize: maximumPixelSize)
            let image = UIImage(cgImage: decoded)
            cache.insert(image, cost: decoded.bytesPerRow * decoded.height, for: key)
            return .image(image, stamp)
        } catch let error as ChatImagePreviewError {
            return .failed(error.thumbnailMessage, reachedHost: true)
        } catch {
            return .failed("Couldn't load this image", reachedHost: false)
        }
    }
}

/// Decoded thumbnails across Chat, bounded by their pixel memory and
/// emptied under memory pressure. `NSCache` is safe to use from any thread.
final class ChatImageThumbnailCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let scope: UUID
        let path: String
        let stamp: ChatImageStamp

        fileprivate var name: NSString {
            let time = stamp.modificationTime.map(String.init) ?? "-"
            return "\(scope.uuidString)\n\(stamp.size)\n\(time)\n\(path)" as NSString
        }
    }

    static let shared = ChatImageThumbnailCache()

    private let images = NSCache<NSString, UIImage>()

    init(costLimit: Int = 48 << 20) {
        images.totalCostLimit = costLimit
    }

    func image(for key: Key) -> UIImage? {
        images.object(forKey: key.name)
    }

    func insert(_ image: UIImage, cost: Int, for key: Key) {
        images.setObject(image, forKey: key.name, cost: cost)
    }
}
