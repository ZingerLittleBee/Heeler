import SwiftUI
import Testing

@testable import Heeler

@Suite("Chat text settings")
struct ChatTextSettingsTests {
    @Test func theOffsetStepsFromTheSystemSize() {
        #expect(ChatTextSettings.size(system: .large, offset: 0) == .large)
        #expect(ChatTextSettings.size(system: .large, offset: ChatTextSettings.defaultSizeOffset) < .large)
        #expect(ChatTextSettings.size(system: .large, offset: 2) == .xxLarge)
        #expect(ChatTextSettings.size(system: .accessibility1, offset: -1) == .xxxLarge)
    }

    @Test func theSizeStaysWithinDynamicType() {
        #expect(ChatTextSettings.size(system: .xSmall, offset: -3) == .xSmall)
        #expect(ChatTextSettings.size(system: .accessibility5, offset: 3) == .accessibility5)
        // An offset stored past the range counts as its end.
        #expect(ChatTextSettings.size(system: .large, offset: -10) == .xSmall)
        #expect(ChatTextSettings.size(system: .large, offset: 10) == .xxxLarge)
    }

    @Test func theBodySizeReadsAsPoints() {
        #expect(ChatTextSettings.bodyPointSize(at: .large) == 17)
        #expect(ChatTextSettings.bodyPointSize(at: .small) == 15)
    }
}
