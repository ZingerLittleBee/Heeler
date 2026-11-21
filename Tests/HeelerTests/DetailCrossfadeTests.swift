import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Detail crossfade")
struct DetailCrossfadeTests {
    /// A report with nothing pending is a no-op.
    @Test func aReportWithoutASwapDoesNothing() {
        let crossfade = DetailCrossfade()
        crossfade.contentDidAppear()
        #expect(crossfade.cover == nil)
    }
}
