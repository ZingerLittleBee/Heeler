import AVFoundation
import ImageIO
import UIKit

/// Where a description's picture or video loads from now (ADR 0065): the
/// last read's address while its signature lasts, else a new read's.
/// `refresh` asks for a new read after the address failed.
typealias GitHubMediaResolver = @MainActor @Sendable (GitHubMedia, _ refresh: Bool) async -> URL?

enum GitHubMediaFailure: Error, Equatable, Sendable {
    /// GitHub did not send it: offline, refused, or the read for a new
    /// address failed.
    case unavailable
    /// Not a picture the phone can draw, such as an SVG badge.
    case unsupported
    case tooLarge
}

/// A picture as the body draws it, with the size of what GitHub sent.
struct GitHubLoadedImage: Sendable {
    /// The picture, or an animation's first frame.
    let image: UIImage
    /// In pixels, upright.
    let pixelSize: CGSize
    /// What GitHub sent for an animated GIF or PNG, which plays a frame at
    /// a time (`AnimatedImageView`); nil for a still picture.
    let animation: Data?
}

/// A video's first frame and length, for its tile.
struct GitHubVideoPoster: Sendable {
    let image: UIImage?
    /// In pixels, upright.
    let pixelSize: CGSize?
    let duration: Duration?
}

/// Loads a description's pictures over HTTPS from the addresses GitHub's
/// HTML gives, a few at a time, and keeps what it loaded by each picture's
/// id, which stays the same across reads while signed addresses change.
@MainActor
final class GitHubMediaLoader {
    static let shared = GitHubMediaLoader()

    /// What GitHub accepts as an upload is smaller.
    static let maximumBytes = 20 << 20

    private let images = NSCache<NSString, Box<GitHubLoadedImage>>()
    private let bodies = NSCache<NSString, NSData>()
    private let posters = NSCache<NSString, Box<GitHubVideoPoster>>()
    private var imageLoads: [String: Task<Result<GitHubLoadedImage, GitHubMediaFailure>, Never>] = [:]
    private var posterLoads: [String: Task<GitHubVideoPoster, Never>] = [:]
    private var available = 4
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    init() {
        images.totalCostLimit = 96 << 20
        bodies.totalCostLimit = 48 << 20
        posters.totalCostLimit = 24 << 20
    }

    func cachedImage(_ id: String) -> GitHubLoadedImage? {
        images.object(forKey: id as NSString)?.value
    }

    func cachedPoster(_ id: String) -> GitHubVideoPoster? {
        posters.object(forKey: id as NSString)?.value
    }

    /// The picture as the body draws it: at most 2,400 pixels on its long
    /// edge, and an animation's data to play.
    func image(for media: GitHubMedia, resolve: @escaping GitHubMediaResolver) async -> Result<GitHubLoadedImage, GitHubMediaFailure> {
        if let cached = cachedImage(media.id) { return .success(cached) }
        if let running = imageLoads[media.id] { return await running.value }
        let task = Task { [weak self] () -> Result<GitHubLoadedImage, GitHubMediaFailure> in
            guard let self else { return .failure(.unavailable) }
            do {
                let data = try await data(for: media, resolve: resolve)
                let loaded = try await GitHubMediaDecoder.shared.image(from: data, maximumPixelSize: 2_400)
                let cost = loaded.image.memoryCost + (loaded.animation?.count ?? 0)
                images.setObject(Box(loaded), forKey: media.id as NSString, cost: cost)
                return .success(loaded)
            } catch let failure as GitHubMediaFailure {
                return .failure(failure)
            } catch {
                return .failure(.unavailable)
            }
        }
        imageLoads[media.id] = task
        let result = await task.value
        imageLoads[media.id] = nil
        return result
    }

    /// What GitHub sent for a picture, from memory when this device has it.
    func data(for media: GitHubMedia, resolve: @escaping GitHubMediaResolver) async throws -> Data {
        if let cached = bodies.object(forKey: media.id as NSString) { return cached as Data }
        await acquire()
        defer { release() }
        guard let url = await resolve(media, false) else { throw GitHubMediaFailure.unavailable }
        var (data, status) = try await Self.fetch(url)
        // A signature that ended in flight, or a clock that disagrees.
        if [400, 401, 403, 404, 410].contains(status), media.expiresAt != nil {
            guard let fresh = await resolve(media, true) else { throw GitHubMediaFailure.unavailable }
            (data, status) = try await Self.fetch(fresh)
        }
        guard (200..<300).contains(status) else { throw GitHubMediaFailure.unavailable }
        guard data.count <= Self.maximumBytes else { throw GitHubMediaFailure.tooLarge }
        bodies.setObject(data as NSData, forKey: media.id as NSString, cost: data.count)
        return data
    }

    /// A video's first frame and length. Nothing when the video cannot be
    /// read; the tile then shows only its play button.
    func poster(for media: GitHubMedia, resolve: @escaping GitHubMediaResolver) async -> GitHubVideoPoster {
        if let cached = cachedPoster(media.id) { return cached }
        if let running = posterLoads[media.id] { return await running.value }
        let task = Task { [weak self] () -> GitHubVideoPoster in
            let none = GitHubVideoPoster(image: nil, pixelSize: nil, duration: nil)
            // AVFoundation reads only what the first frame needs, and
            // outside the pictures' four requests, which it could hold up.
            guard let self, let url = await resolve(media, false) else { return none }
            let poster = await GitHubMediaDecoder.shared.poster(of: url)
            if poster.image != nil {
                posters.setObject(Box(poster), forKey: media.id as NSString, cost: poster.image?.memoryCost ?? 0)
            }
            return poster
        }
        posterLoads[media.id] = task
        let poster = await task.value
        posterLoads[media.id] = nil
        return poster
    }

    private static func fetch(_ url: URL) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw GitHubMediaFailure.unavailable
        }
    }

    /// Four requests at a time, so a long description's first pictures
    /// arrive first.
    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    private final class Box<Value>: NSObject {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
}

/// Decodes pictures and reads videos' first frames off the main actor, with
/// bounded pixel memory.
actor GitHubMediaDecoder {
    static let shared = GitHubMediaDecoder()

    /// The picture at most `maximumPixelSize` on its long edge. An animated
    /// GIF or PNG keeps its data to play, with its first frame to show
    /// until it plays or when it should not.
    func image(from data: Data, maximumPixelSize: Int) async throws -> GitHubLoadedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0
        else { throw GitHubMediaFailure.unsupported }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let pixelSize = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        do {
            let image = try await ChatImagePreviewDecoder.shared.decode(data, maximumPixelSize: maximumPixelSize)
            return GitHubLoadedImage(
                image: UIImage(cgImage: image), pixelSize: pixelSize,
                animation: CGImageSourceGetCount(source) > 1 ? data : nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitHubMediaFailure.unsupported
        }
    }

    /// A video's first frame, upright and at most 1,200 pixels across, and
    /// its length.
    func poster(of url: URL) async -> GitHubVideoPoster {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_200, height: 1_200)
        let frame = try? await generator.image(at: .zero).image
        let duration = try? await asset.load(.duration)
        var pixelSize: CGSize?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let geometry = try? await track.load(.naturalSize, .preferredTransform)
        {
            let upright = geometry.0.applying(geometry.1)
            pixelSize = CGSize(width: abs(upright.width), height: abs(upright.height))
        }
        return GitHubVideoPoster(
            image: frame.map { UIImage(cgImage: $0) },
            pixelSize: pixelSize ?? frame.map { CGSize(width: $0.width, height: $0.height) },
            duration: duration.flatMap { $0.isNumeric ? .seconds($0.seconds) : nil })
    }
}

extension UIImage {
    /// About the memory its pixels take, for a cache's cost.
    fileprivate var memoryCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
