import SwiftUI
import Testing
import UIKit

@testable import HerdrMobile

/// The dialog's whole job is to be legible over a live terminal. Its first
/// version was a bare `ContentUnavailableView`, which draws no background at
/// all, so the copy sat directly on top of whatever glyphs happened to be
/// underneath. That is invisible to every kind of test except one that looks
/// at the pixels, so this suite looks at the pixels.
@MainActor
@Suite("Terminal status dialog")
struct TerminalStatusDialogTests {
    @Test func theDialogCoversWhateverTheTerminalWasShowing() throws {
        let image = try Self.render(
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"),
                title: "Session Ended",
                message: "The session ended."
            ) {
                Button("Reattach") {}
                    .buttonStyle(.borderedProminent)
            })

        let behind = try #require(Self.color(in: image, atUnit: CGPoint(x: 0.5, y: 0.5)))
        #expect(behind != Self.backdrop, "the dialog let the terminal through")
    }

    @Test func theDimOnlyAppliesWhereItIsAskedFor() throws {
        // A corner is outside the card but inside the scrim.
        let corner = CGPoint(x: 0.03, y: 0.06)

        let dimmed = try Self.render(
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"), title: "Session Ended"))
        let undimmed = try Self.render(
            TerminalStatusDialog(glyph: .progress, title: "Connecting…", dimsBackground: false))

        #expect(try #require(Self.color(in: dimmed, atUnit: corner)) != Self.backdrop)
        // Transient states leave the terminal alone; dimming on every reconnect
        // would flash the screen.
        #expect(try #require(Self.color(in: undimmed, atUnit: corner)) == Self.backdrop)
    }

    /// Pure red, so anything drawn over it is unmistakable.
    private static let backdrop: UInt32 = 0xFF00_0000 >> 8

    private static func render(_ dialog: some View) throws -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIHostingController(
            rootView: ZStack {
                Color(red: 1, green: 0, blue: 0).ignoresSafeArea()
                dialog
            })
        controller.view.frame = bounds

        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: windowScene)
        window.frame = bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    private static func color(in image: UIImage, atUnit point: CGPoint) -> UInt32? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        let i = (y * width + x) * 4
        return UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
    }
}
