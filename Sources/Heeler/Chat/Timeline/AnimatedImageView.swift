import ImageIO
import UIKit

/// An image view that plays an animated GIF or PNG from its data, each
/// frame decoded by ImageIO as it comes due, so a long animation plays all
/// of its frames at full size with the memory of one. It plays while it is
/// in a window and Reduce Motion is off, and shows `image` otherwise.
final class AnimatedImageView: UIImageView {
    /// The animation to play; nil for a still picture.
    var animationData: Data? {
        didSet {
            if animationData != oldValue { restart() }
        }
    }

    /// Each start's number: a frame from an earlier start stops its
    /// animation.
    private var generation = 0

    /// Whether the data holds more than one frame.
    nonisolated static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    private func restart() {
        generation += 1
        guard let data = animationData, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let current = generation
        // ImageIO calls the block on the main queue, at each frame's delay.
        CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, frame, stop in
            let playing = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.generation == current else { return false }
                self.image = UIImage(cgImage: frame)
                return true
            }
            if !playing { stop.pointee = true }
        }
    }
}
