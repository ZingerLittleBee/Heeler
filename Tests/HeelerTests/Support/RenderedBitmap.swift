import CoreGraphics
import SwiftUI
import Testing
import UIKit

/// A SwiftUI view drawn by Core Graphics into memory the test owns: 8-bit
/// sRGB, premultiplied RGBA, rows from the top.
///
/// Tests read pixels through this, not through `ImageRenderer.uiImage` or
/// `cgImage`. Those images get their pixels later, from a RenderBox image
/// provider that draws on the GPU, and on iOS 27 that provider can stop
/// waiting ("image provider … timed out while waiting for phase 6"). The
/// image then has no pixels and `pngData()` returns nil.
/// `render(rasterizationScale:renderer:)` draws into the context it is handed
/// before it returns.
///
/// Core Graphics rasterizes what it can draw. The views these tests render use
/// no material, blur, shader or glass; a region drawn with one may not appear
/// here, so a comparison over it would prove nothing.
struct RenderedBitmap: Equatable {
    /// The view's size in points.
    let size: CGSize
    /// Pixels per point.
    let scale: CGFloat
    let width: Int
    let height: Int
    /// `width * height` pixels, four bytes each.
    let bytes: Data

    /// Draws `content` at `scale` pixels per point. A render whose pixels are
    /// all the same fails here: comparing two blank renders proves nothing,
    /// and every view these tests draw puts something on its background.
    @MainActor
    init(
        _ content: some View,
        proposedSize: ProposedViewSize,
        scale: CGFloat = 1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB), sourceLocation: sourceLocation)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = proposedSize
        // Layout rounds to this scale's pixels, as it does for the image.
        renderer.scale = scale
        var drawn: (size: CGSize, width: Int, height: Int, bytes: Data)?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0 else { return }
            var bytes = Data(count: width * height * 4)
            let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.scaleBy(x: scale, y: scale)
                draw(context)
                return true
            }
            if didDraw { drawn = (size, width, height, bytes) }
        }
        let result = try #require(drawn, "ImageRenderer drew nothing", sourceLocation: sourceLocation)
        size = result.size
        self.scale = scale
        width = result.width
        height = result.height
        bytes = result.bytes
        try #require(
            isUniform == false, "Every pixel of the \(width)x\(height) render is the same",
            sourceLocation: sourceLocation)
    }

    /// Whether every pixel matches the first.
    var isUniform: Bool {
        bytes.withUnsafeBytes { buffer in
            let first = buffer.loadUnaligned(as: UInt32.self)
            return stride(from: 4, to: buffer.count, by: 4).allSatisfy {
                buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self) == first
            }
        }
    }

    /// The pixel `x` columns from the left and `y` rows from the top.
    func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    /// Relative luminance of the pixel at `x`, `y`, from 0 to 1.
    func luminance(x: Int, y: Int) -> Double {
        let pixel = pixel(x: x, y: y)
        return (0.2126 * Double(pixel.red) + 0.7152 * Double(pixel.green) + 0.0722 * Double(pixel.blue)) / 255
    }

    /// The bitmap as an image backed by these bytes, for attachments and
    /// files a person reviews.
    func image() throws -> UIImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
