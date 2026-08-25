import GhosttyTerminal
import UIKit

extension UITerminalView {
    /// GhosttyTerminal 1.3.1 frees the surface in `didMoveToWindow(nil)` but
    /// leaves ghostty's `IOSurfaceLayer` sublayer behind. That layer's
    /// `display` override calls back into the freed renderer through a raw
    /// context pointer, so the next Core Animation commit that touches it
    /// (any bounds change schedules display) jumps into freed memory — the
    /// on-device PAC trap under `CA::Context::commit_transaction`. Once the
    /// surface is gone, every content layer under this view is an orphan;
    /// pull them out of the tree so CA can never display them again.
    func removeOrphanedSurfaceLayers() {
        for sublayer in layer.sublayers ?? []
        where NSStringFromClass(type(of: sublayer)) == "IOSurfaceLayer" {
            sublayer.removeFromSuperlayer()
        }
    }
}
