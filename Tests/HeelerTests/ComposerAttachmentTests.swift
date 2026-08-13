import Testing

@testable import Heeler

@Suite("Composer attachments")
@MainActor
struct ComposerAttachmentTests {
    @Test func linksActionOnlyAppearsWhenLinksExist() {
        #expect(AgentComposerLinkPresentation(count: 0) == nil)

        let oneLink = AgentComposerLinkPresentation(count: 1)
        #expect(oneLink?.count == 1)
        #expect(oneLink?.accessibilityValue == "1 distinct link")

        let multipleLinks = AgentComposerLinkPresentation(count: 3)
        #expect(multipleLinks?.count == 3)
        #expect(multipleLinks?.accessibilityValue == "3 distinct links")
    }
}
