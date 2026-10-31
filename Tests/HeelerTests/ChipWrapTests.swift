import Testing
import SwiftUI
import UIKit

@testable import Heeler

@MainActor
@Suite("Chip wrap")
struct ChipWrapTests {
    @MainActor
    private final class Frames {
        var byIndex: [Int: CGRect] = [:]
    }

    /// Chips given the one-line width they measured stay on that line. These
    /// widths are the host, status, and add chips that ended Row 1 in Agent
    /// List Fields, whose summed width came back a rounding error short of
    /// the sum the wrap checked against, dropping the add chip below the row.
    @Test func chipsStayOnTheLineTheirMeasuredWidthHolds() async throws {
        let frames = Frames()
        let widths: [CGFloat] = [39.33333333333333, 53, 24]
        func chip(_ index: Int) -> some View {
            Color.clear
                .frame(width: widths[index], height: 20)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frames.byIndex[index] = $0 }
        }
        let view = ChipWrap(spacing: 5) {
            chip(0)
            chip(1)
            chip(2)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        let controller = UIHostingController(rootView: view)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 300, height: 200), rootViewController: controller)
        defer { window.isHidden = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while frames.byIndex.count < widths.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(frames.byIndex[0])
        let last = try #require(frames.byIndex[2])
        #expect(abs(last.minY - first.minY) < 0.5, "\(last) wrapped below \(first)")
        #expect(abs(last.maxX - window.bounds.maxX) < 0.5, "\(last) does not end the line")
    }
}
