import Foundation
import Testing

@testable import Heeler

/// The words the parsers and planners match stay the programs' own, in any
/// language the app shows, and the text Heeler writes in their place picks
/// one whole phrase per case instead of joining English pieces.
@Suite("Chat parser localization")
struct ChatParsersLocalizationTests {
    private func observe(_ stem: String) throws -> DialogObservation {
        DialogObservation(
            screen: try ScreenFixture.screen(stem), program: ScreenFixture.program(stem), activity: .blocked)
    }

    private func dialog(_ stem: String) throws -> BlockedDialog {
        let observation = try observe(stem)
        return try #require(observation.result.dialog, "\(stem) parsed as \(observation.result)")
    }

    /// The last page turn waits for the page the parser reads from Claude's
    /// own title, so a translated card title can't stall the submit.
    @Test("Claude's review page is the page the last answer expects")
    func claudeReviewPageMatchesThePlan() throws {
        let review = try dialog("claude-14-c4-review")
        #expect(review.kind == .claudeQuestionReview)
        #expect(review.progress == ClaudeDialogParser.reviewPage)
        #expect(ClaudeDialogParser.reviewPage == "Review your answers")

        let plan = try DialogActionPlanner.plan(.choose(ordinal: 1), for: dialog("claude-12-c4-q2-digit3"))
        let last = try #require(plan.steps.last)
        #expect(last == .expect(.page(ClaudeDialogParser.reviewPage)))
        guard case .expect(let expectation) = last else { return }
        let shown = try observe("claude-14-c4-review")
        let questions = try dialog("claude-08-c4-auq-q1").fingerprint
        #expect(expectation.isMet(by: shown, fingerprint: questions))
    }

    @Test("Oh My Pi's review page is the page the last answer expects")
    func ompReviewPageMatchesThePlan() throws {
        let review = try dialog("omp-28-ask2-c-submit-page")
        #expect(review.kind == .ompQuestionReview)
        #expect(review.progress == OMPDialogParser.reviewTitle)
        #expect(OMPDialogParser.reviewTitle == "Review answers")

        let plan = try DialogActionPlanner.plan(.choose(ordinal: 1), for: dialog("omp-28-ask2-b-after-enter-q1"))
        let last = try #require(plan.steps.last)
        #expect(last == .expect(.page(OMPDialogParser.reviewTitle)))
        guard case .expect(let expectation) = last else { return }
        let shown = try observe("omp-28-ask2-c-submit-page")
        let questions = try dialog("omp-28-ask2-a-dialog").fingerprint
        #expect(expectation.isMet(by: shown, fingerprint: questions))
    }

    /// A status Claude Code's task tools don't document gets the generic
    /// title rather than its raw token next to Heeler's words.
    @Test(
        "A task update's title names the status in words",
        arguments: [
            ("in_progress", "Task #3: in progress"),
            ("pending", "Task #3: pending"),
            ("deleted", "Task #3: deleted"),
            ("blocked_on_review", "Updated task #3"),
        ])
    func taskUpdateTitle(status: String, title: String) {
        let use = ClaudeToolUse(id: "toolu_01", name: "TaskUpdate", input: ClaudeToolInput(taskID: "3", status: status))
        #expect(ClaudeToolSummary(use).title == title)
    }

    @Test("A background task's notice says how it ended, in a whole title")
    func taskNotificationTitle() {
        func title(_ status: String?) -> String {
            ClaudeTaskNotification(status: status).title
        }
        #expect(title(nil) == "Background task finished")
        #expect(title("completed") == "Background task completed")
        #expect(title("failed") == "Background task failed")
        #expect(title("stopped") == "Background task stopped")
        #expect(title("blocked") == "Background task blocked")
        #expect(title("timed_out") == "Background task ended")
        #expect(ClaudeTaskNotification(summary: "Build finished", status: "failed").title == "Build finished")
    }

    /// Oh My Pi's `Approve <tool> for this session` is matched as its own
    /// words; the note names the tool, or says `this tool` as one sentence
    /// when the label isn't that shape.
    @Test("Oh My Pi's session approval note names the tool in one sentence")
    func ompPersistenceNote() {
        func note(_ label: String) -> String {
            DialogOption(ordinal: 2, number: nil, label: label, role: .approvePersistent)
                .persistenceNote(program: .omp)
        }
        #expect(note("Approve bash for this session") == "Oh My Pi won't ask again for bash in this session.")
        #expect(note("Approve for this session") == "Oh My Pi won't ask again for this tool in this session.")
        #expect(note("Always approve") == "Oh My Pi won't ask again for this tool in this session.")
    }
}
