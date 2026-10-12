import Foundation

@testable import Heeler

extension AgentComposerSession {
    /// A session for tests that never stage: every upload fails.
    convenience init(composer: AgentComposerStore) {
        self.init(
            composer: composer,
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled })
    }
}
