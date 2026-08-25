import GhosttyTerminal
import UIKit

extension UITerminalView {
    /// ghostty parks an `IOSurfaceLayer` sublayer in this view's layer tree,
    /// and nothing on the teardown path (GhosttyTerminal 1.4.0, ghostty
    /// v1.3.1) ever calls `removeFromSuperlayer`. The layer's `display`
    /// override calls back into its renderer through a raw context pointer,
    /// so a layer that outlives its freed surface — any surface rebuild
    /// tears down the old surface while the view stays alive — dangles: the
    /// next Core Animation commit that touches it (any bounds change
    /// schedules display) jumps into freed memory. That was the on-device
    /// PAC trap under `CA::Context::commit_transaction` (#242).
    ///
    /// Call this from `TerminalSurfaceLifecycleDelegate`'s
    /// `terminalDidDetachSurface()`, which fires after the surface is freed
    /// and before a replacement adds its own layer, so every content layer
    /// present at that moment is an orphan.
    func removeOrphanedSurfaceLayers() {
        for sublayer in layer.sublayers ?? []
        where NSStringFromClass(type(of: sublayer)) == "IOSurfaceLayer" {
            sublayer.removeFromSuperlayer()
        }
    }
}
